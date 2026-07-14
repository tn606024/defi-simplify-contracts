// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefiSimplify7702Account} from "../../src/DefiSimplify7702Account.sol";
import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {BaseAccount} from "@account-abstraction/contracts/core/BaseAccount.sol";
import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Vm} from "forge-std/Vm.sol";
import {StaticCompatibilityTarget} from "../mocks/StaticCompatibilityTarget.sol";
import {DelegatedAccountFixture} from "../utils/DelegatedAccountFixture.sol";

contract UpstreamCompatibilityTest is DelegatedAccountFixture {
    uint256 private constant WRONG_SIGNER_KEY = 0xBAD;
    uint256 private constant WRONG_ENTRY_POINT_UPSTREAM_KEY = 0xA11CE;
    uint256 private constant WRONG_ENTRY_POINT_CUSTOM_KEY = 0xB0B;

    DelegatedPair private pair;
    StaticCompatibilityTarget private upstreamTarget;
    StaticCompatibilityTarget private customTarget;

    receive() external payable {}

    function setUp() external {
        pair = _deployDelegatedPair(IEntryPoint(address(this)));
        upstreamTarget = new StaticCompatibilityTarget();
        customTarget = new StaticCompatibilityTarget();
        vm.deal(address(this), 100 ether);
    }

    function test_DelegatedFixtureUsesEoaContextAndConfiguredEntryPoint() external {
        _assertEq(
            _delegationTarget(pair.upstreamAccount), address(pair.upstreamImplementation), "upstream delegation target"
        );
        _assertEq(_delegationTarget(pair.customAccount), address(pair.customImplementation), "custom delegation target");
        _assertEq(address(_upstream().entryPoint()), address(this), "upstream EntryPoint");
        _assertEq(address(_custom().entryPoint()), address(this), "custom EntryPoint");

        bytes memory upstreamData = abi.encodeCall(StaticCompatibilityTarget.record, (11, bytes("delegated-self-call")));
        bytes memory customData = abi.encodeCall(StaticCompatibilityTarget.record, (11, bytes("delegated-self-call")));

        vm.prank(pair.upstreamAccount);
        _upstream().execute(address(upstreamTarget), 0, upstreamData);
        vm.prank(pair.customAccount);
        _custom().execute(address(customTarget), 0, customData);

        _assertEquivalentTargetState();
        _assertEq(upstreamTarget.lastCaller(), pair.upstreamAccount, "upstream target caller");
        _assertEq(customTarget.lastCaller(), pair.customAccount, "custom target caller");
    }

    function test_DifferentialExecutePreservesValueAndFinalState() external {
        vm.deal(pair.upstreamAccount, 2 ether);
        vm.deal(pair.customAccount, 2 ether);
        bytes memory upstreamData = abi.encodeCall(StaticCompatibilityTarget.record, (21, bytes("single")));
        bytes memory customData = abi.encodeCall(StaticCompatibilityTarget.record, (21, bytes("single")));

        _upstream().execute(address(upstreamTarget), 0.4 ether, upstreamData);
        _custom().execute(address(customTarget), 0.4 ether, customData);

        _assertEquivalentTargetState();
        _assertEq(upstreamTarget.lastCaller(), pair.upstreamAccount, "upstream execute caller");
        _assertEq(customTarget.lastCaller(), pair.customAccount, "custom execute caller");
        _assertEq(pair.upstreamAccount.balance, pair.customAccount.balance, "account balances");
        _assertEq(address(upstreamTarget).balance, address(customTarget).balance, "target balances");
    }

    function test_DifferentialExecuteBatchOneAndManyCalls() external {
        vm.deal(pair.upstreamAccount, 2 ether);
        vm.deal(pair.customAccount, 2 ether);

        BaseAccount.Call[] memory upstreamOne = new BaseAccount.Call[](1);
        BaseAccount.Call[] memory customOne = new BaseAccount.Call[](1);
        upstreamOne[0] = _recordCall(address(upstreamTarget), 1, 0, "one");
        customOne[0] = _recordCall(address(customTarget), 1, 0, "one");
        _upstream().executeBatch(upstreamOne);
        _custom().executeBatch(customOne);

        BaseAccount.Call[] memory upstreamMany = new BaseAccount.Call[](2);
        BaseAccount.Call[] memory customMany = new BaseAccount.Call[](2);
        upstreamMany[0] = _recordCall(address(upstreamTarget), 2, 0, "many-a");
        upstreamMany[1] = _recordCall(address(upstreamTarget), 3, 0.25 ether, "many-b");
        customMany[0] = _recordCall(address(customTarget), 2, 0, "many-a");
        customMany[1] = _recordCall(address(customTarget), 3, 0.25 ether, "many-b");
        _upstream().executeBatch(upstreamMany);
        _custom().executeBatch(customMany);

        _assertEquivalentTargetState();
        _assertEq(upstreamTarget.lastCaller(), pair.upstreamAccount, "upstream batch caller");
        _assertEq(customTarget.lastCaller(), pair.customAccount, "custom batch caller");
        _assertEq(pair.upstreamAccount.balance, pair.customAccount.balance, "batch account balances");
        _assertEq(address(upstreamTarget).balance, address(customTarget).balance, "batch target balances");
    }

    function test_DifferentialFailureReturndataAndAttribution() external {
        bytes memory targetFailure =
            abi.encodeWithSelector(StaticCompatibilityTarget.TargetFailure.selector, 77, bytes("nested"));
        bytes memory upstreamFailCall = abi.encodeCall(StaticCompatibilityTarget.fail, (77, bytes("nested")));
        bytes memory customFailCall = abi.encodeCall(StaticCompatibilityTarget.fail, (77, bytes("nested")));

        (bool upstreamSuccess, bytes memory upstreamReason) =
            _callExecute(pair.upstreamAccount, address(upstreamTarget), 0, upstreamFailCall);
        (bool customSuccess, bytes memory customReason) =
            _callExecute(pair.customAccount, address(customTarget), 0, customFailCall);
        _assertFalse(upstreamSuccess, "upstream execute should fail");
        _assertFalse(customSuccess, "custom execute should fail");
        _assertEqBytes(upstreamReason, targetFailure, "upstream execute reason");
        _assertEqBytes(customReason, targetFailure, "custom execute reason");

        BaseAccount.Call[] memory upstreamOne = new BaseAccount.Call[](1);
        BaseAccount.Call[] memory customOne = new BaseAccount.Call[](1);
        upstreamOne[0] = BaseAccount.Call({target: address(upstreamTarget), value: 0, data: upstreamFailCall});
        customOne[0] = BaseAccount.Call({target: address(customTarget), value: 0, data: customFailCall});
        (upstreamSuccess, upstreamReason) = _callBatch(pair.upstreamAccount, upstreamOne);
        (customSuccess, customReason) = _callBatch(pair.customAccount, customOne);
        _assertFalse(upstreamSuccess, "upstream one-call batch should fail");
        _assertFalse(customSuccess, "custom one-call batch should fail");
        _assertEqBytes(upstreamReason, targetFailure, "upstream one-call batch reason");
        _assertEqBytes(customReason, targetFailure, "custom one-call batch reason");

        BaseAccount.Call[] memory upstreamMany = new BaseAccount.Call[](2);
        BaseAccount.Call[] memory customMany = new BaseAccount.Call[](2);
        upstreamMany[0] = _recordCall(address(upstreamTarget), 1, 0, "rolled-back");
        upstreamMany[1] = BaseAccount.Call({target: address(upstreamTarget), value: 0, data: upstreamFailCall});
        customMany[0] = _recordCall(address(customTarget), 1, 0, "rolled-back");
        customMany[1] = BaseAccount.Call({target: address(customTarget), value: 0, data: customFailCall});
        bytes memory wrappedFailure = abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 1, targetFailure);
        (upstreamSuccess, upstreamReason) = _callBatch(pair.upstreamAccount, upstreamMany);
        (customSuccess, customReason) = _callBatch(pair.customAccount, customMany);
        _assertFalse(upstreamSuccess, "upstream many-call batch should fail");
        _assertFalse(customSuccess, "custom many-call batch should fail");
        _assertEqBytes(upstreamReason, wrappedFailure, "upstream wrapped reason");
        _assertEqBytes(customReason, wrappedFailure, "custom wrapped reason");
        _assertEq(upstreamTarget.count(), 0, "upstream state should roll back");
        _assertEq(customTarget.count(), 0, "custom state should roll back");
    }

    function test_DifferentialValidateUserOpAndPrefund() external {
        bytes32 userOpHash = keccak256("static-compatible-user-operation");
        vm.deal(pair.upstreamAccount, 1 ether);
        vm.deal(pair.customAccount, 1 ether);
        uint256 entryPointBalanceBefore = address(this).balance;

        PackedUserOperation memory upstreamOp =
            _userOperation(pair.upstreamAccount, _signature(UPSTREAM_AUTHORITY_KEY, userOpHash));
        PackedUserOperation memory customOp =
            _userOperation(pair.customAccount, _signature(CUSTOM_AUTHORITY_KEY, userOpHash));
        uint256 upstreamValidation = IAccount(pair.upstreamAccount).validateUserOp(upstreamOp, userOpHash, 0.2 ether);
        uint256 customValidation = IAccount(pair.customAccount).validateUserOp(customOp, userOpHash, 0.2 ether);

        _assertEq(upstreamValidation, 0, "upstream valid signature");
        _assertEq(customValidation, 0, "custom valid signature");
        _assertEq(pair.upstreamAccount.balance, pair.customAccount.balance, "prefund account balances");
        _assertEq(address(this).balance, entryPointBalanceBefore + 0.4 ether, "EntryPoint prefund balance");

        bytes memory wrongSignature = _signature(WRONG_SIGNER_KEY, userOpHash);
        upstreamOp.signature = wrongSignature;
        customOp.signature = wrongSignature;
        upstreamValidation = IAccount(pair.upstreamAccount).validateUserOp(upstreamOp, userOpHash, 0);
        customValidation = IAccount(pair.customAccount).validateUserOp(customOp, userOpHash, 0);
        _assertEq(upstreamValidation, 1, "upstream invalid signature");
        _assertEq(customValidation, 1, "custom invalid signature");
    }

    function test_DifferentialERC1271ValidAndInvalidSignatures() external view {
        bytes32 digest = keccak256("erc-1271-static-compatibility");
        bytes4 upstreamValid =
            IERC1271(pair.upstreamAccount).isValidSignature(digest, _signature(UPSTREAM_AUTHORITY_KEY, digest));
        bytes4 customValid =
            IERC1271(pair.customAccount).isValidSignature(digest, _signature(CUSTOM_AUTHORITY_KEY, digest));
        bytes memory wrongSignature = _signature(WRONG_SIGNER_KEY, digest);
        bytes4 upstreamInvalid = IERC1271(pair.upstreamAccount).isValidSignature(digest, wrongSignature);
        bytes4 customInvalid = IERC1271(pair.customAccount).isValidSignature(digest, wrongSignature);

        _assertEqBytes4(upstreamValid, IERC1271.isValidSignature.selector, "upstream ERC-1271 valid result");
        _assertEqBytes4(customValid, IERC1271.isValidSignature.selector, "custom ERC-1271 valid result");
        _assertEqBytes4(upstreamInvalid, bytes4(0xffffffff), "upstream ERC-1271 invalid result");
        _assertEqBytes4(customInvalid, bytes4(0xffffffff), "custom ERC-1271 invalid result");
    }

    function test_DifferentialERC165AndReceiverBehavior() external {
        bytes4[] memory ids = new bytes4[](6);
        ids[0] = type(IERC165).interfaceId;
        ids[1] = type(IAccount).interfaceId;
        ids[2] = type(IERC1271).interfaceId;
        ids[3] = type(IERC721Receiver).interfaceId;
        ids[4] = type(IERC1155Receiver).interfaceId;
        ids[5] = 0xffffffff;

        for (uint256 i = 0; i < ids.length; i++) {
            bool upstreamSupported = IERC165(pair.upstreamAccount).supportsInterface(ids[i]);
            bool customSupported = IERC165(pair.customAccount).supportsInterface(ids[i]);
            _assertEq(upstreamSupported, customSupported, "ERC-165 differential result");
            _assertEq(upstreamSupported, i < 5, "ERC-165 expected result");
        }

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        uint256[] memory tokenValues = new uint256[](2);
        tokenValues[0] = 3;
        tokenValues[1] = 4;

        _assertEqBytes4(
            IERC721Receiver(pair.upstreamAccount).onERC721Received(address(this), address(1), 2, "receiver"),
            IERC721Receiver(pair.customAccount).onERC721Received(address(this), address(1), 2, "receiver"),
            "ERC-721 receiver result"
        );
        _assertEqBytes4(
            IERC1155Receiver(pair.upstreamAccount).onERC1155Received(address(this), address(1), 2, 3, "receiver"),
            IERC1155Receiver(pair.customAccount).onERC1155Received(address(this), address(1), 2, 3, "receiver"),
            "ERC-1155 receiver result"
        );
        _assertEqBytes4(
            IERC1155Receiver(pair.upstreamAccount)
                .onERC1155BatchReceived(address(this), address(1), tokenIds, tokenValues, "receiver"),
            IERC1155Receiver(pair.customAccount)
                .onERC1155BatchReceived(address(this), address(1), tokenIds, tokenValues, "receiver"),
            "ERC-1155 batch receiver result"
        );
    }

    function test_DifferentialFallbackAndReceiveBehavior() external {
        (bool upstreamSuccess, bytes memory upstreamData) = pair.upstreamAccount.call{value: 0.1 ether}("");
        (bool customSuccess, bytes memory customData) = pair.customAccount.call{value: 0.1 ether}("");
        _assertEq(upstreamSuccess, customSuccess, "receive success");
        _assertTrue(upstreamSuccess, "receive should succeed");
        _assertEqBytes(upstreamData, customData, "receive returndata");

        (upstreamSuccess, upstreamData) = pair.upstreamAccount.call{value: 0.2 ether}(hex"deadbeef0102");
        (customSuccess, customData) = pair.customAccount.call{value: 0.2 ether}(hex"deadbeef0102");
        _assertEq(upstreamSuccess, customSuccess, "fallback success");
        _assertTrue(upstreamSuccess, "fallback should succeed");
        _assertEqBytes(upstreamData, customData, "fallback returndata");
        _assertEq(pair.upstreamAccount.balance, pair.customAccount.balance, "fallback and receive balances");
    }

    function test_RandomCallerRejectedForCorrectReason() external {
        address randomCaller = address(0xCA11E2);
        bytes memory executeData = abi.encodeWithSelector(BaseAccount.execute.selector, address(upstreamTarget), 0, "");

        vm.prank(randomCaller);
        (bool upstreamSuccess, bytes memory upstreamReason) = pair.upstreamAccount.call(executeData);
        executeData = abi.encodeWithSelector(BaseAccount.execute.selector, address(customTarget), 0, "");
        vm.prank(randomCaller);
        (bool customSuccess, bytes memory customReason) = pair.customAccount.call(executeData);

        _assertFalse(upstreamSuccess, "random upstream caller should fail");
        _assertFalse(customSuccess, "random custom caller should fail");
        _assertEqBytes(
            upstreamReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, randomCaller, pair.upstreamAccount, address(this)
            ),
            "upstream random caller reason"
        );
        _assertEqBytes(
            customReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, randomCaller, pair.customAccount, address(this)
            ),
            "custom random caller reason"
        );
    }

    function test_MaliciousCallbackCallerRejectedForCorrectReason() external {
        StaticCompatibilityTarget maliciousTarget = new StaticCompatibilityTarget();
        bytes memory upstreamAttack =
            abi.encodeCall(StaticCompatibilityTarget.callAccountExecute, (pair.upstreamAccount));
        bytes memory customAttack = abi.encodeCall(StaticCompatibilityTarget.callAccountExecute, (pair.customAccount));

        (bool upstreamSuccess, bytes memory upstreamReason) =
            _callExecute(pair.upstreamAccount, address(maliciousTarget), 0, upstreamAttack);
        (bool customSuccess, bytes memory customReason) =
            _callExecute(pair.customAccount, address(maliciousTarget), 0, customAttack);
        _assertFalse(upstreamSuccess, "malicious upstream callback should fail");
        _assertFalse(customSuccess, "malicious custom callback should fail");
        _assertEqBytes(
            upstreamReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, address(maliciousTarget), pair.upstreamAccount, address(this)
            ),
            "upstream callback reason"
        );
        _assertEqBytes(
            customReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, address(maliciousTarget), pair.customAccount, address(this)
            ),
            "custom callback reason"
        );
    }

    function test_WrongEntryPointRejectedByValidationPath() external {
        address wrongEntryPoint = address(0xBEEF);
        DelegatedPair memory wrongPair = _deployDelegatedPair(
            IEntryPoint(wrongEntryPoint), WRONG_ENTRY_POINT_UPSTREAM_KEY, WRONG_ENTRY_POINT_CUSTOM_KEY
        );
        bytes32 userOpHash = keccak256("wrong-entrypoint");
        PackedUserOperation memory upstreamOp = _userOperation(wrongPair.upstreamAccount, "");
        PackedUserOperation memory customOp = _userOperation(wrongPair.customAccount, "");
        bytes memory upstreamCall = abi.encodeCall(IAccount.validateUserOp, (upstreamOp, userOpHash, 0));
        bytes memory customCall = abi.encodeCall(IAccount.validateUserOp, (customOp, userOpHash, 0));

        (bool upstreamSuccess, bytes memory upstreamReason) = wrongPair.upstreamAccount.call(upstreamCall);
        (bool customSuccess, bytes memory customReason) = wrongPair.customAccount.call(customCall);
        _assertFalse(upstreamSuccess, "wrong upstream EntryPoint should fail");
        _assertFalse(customSuccess, "wrong custom EntryPoint should fail");
        _assertEqBytes(
            upstreamReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, address(this), wrongPair.upstreamAccount, wrongEntryPoint
            ),
            "wrong upstream EntryPoint reason"
        );
        _assertEqBytes(
            customReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector, address(this), wrongPair.customAccount, wrongEntryPoint
            ),
            "wrong custom EntryPoint reason"
        );
    }

    function test_DifferentialStaticEventSurfaceContainsOnlyTargetEvent() external {
        bytes memory upstreamData = abi.encodeCall(StaticCompatibilityTarget.record, (91, bytes("event")));
        bytes memory customData = abi.encodeCall(StaticCompatibilityTarget.record, (91, bytes("event")));

        vm.recordLogs();
        _upstream().execute(address(upstreamTarget), 0, upstreamData);
        Vm.Log[] memory upstreamLogs = vm.getRecordedLogs();
        vm.recordLogs();
        _custom().execute(address(customTarget), 0, customData);
        Vm.Log[] memory customLogs = vm.getRecordedLogs();

        _assertEq(upstreamLogs.length, 1, "upstream log count");
        _assertEq(customLogs.length, 1, "custom log count");
        _assertEq(upstreamLogs[0].emitter, address(upstreamTarget), "upstream log emitter");
        _assertEq(customLogs[0].emitter, address(customTarget), "custom log emitter");
        _assertEqBytes(abi.encode(upstreamLogs[0].topics), abi.encode(customLogs[0].topics), "log topics");
        _assertEqBytes(upstreamLogs[0].data, customLogs[0].data, "log data");
    }

    function _upstream() private view returns (Simple7702Account) {
        return Simple7702Account(pair.upstreamAccount);
    }

    function _custom() private view returns (DefiSimplify7702Account) {
        return DefiSimplify7702Account(pair.customAccount);
    }

    function _recordCall(address target, uint256 amount, uint256 callValue, bytes memory payload)
        private
        pure
        returns (BaseAccount.Call memory)
    {
        return BaseAccount.Call({
            target: target, value: callValue, data: abi.encodeCall(StaticCompatibilityTarget.record, (amount, payload))
        });
    }

    function _callExecute(address account, address target, uint256 value, bytes memory data)
        private
        returns (bool success, bytes memory result)
    {
        return account.call(abi.encodeWithSelector(BaseAccount.execute.selector, target, value, data));
    }

    function _callBatch(address account, BaseAccount.Call[] memory calls)
        private
        returns (bool success, bytes memory result)
    {
        return account.call(abi.encodeWithSelector(BaseAccount.executeBatch.selector, calls));
    }

    function _userOperation(address sender, bytes memory signature)
        private
        pure
        returns (PackedUserOperation memory operation)
    {
        operation.sender = sender;
        operation.signature = signature;
    }

    function _assertEquivalentTargetState() private view {
        _assertEq(upstreamTarget.count(), customTarget.count(), "target count");
        _assertEq(upstreamTarget.total(), customTarget.total(), "target total");
        _assertEq(upstreamTarget.totalCallValue(), customTarget.totalCallValue(), "target call value");
        _assertEqBytes32(upstreamTarget.lastPayloadHash(), customTarget.lastPayloadHash(), "target payload hash");
    }

    function _assertTrue(bool condition, string memory reason) private pure {
        require(condition, reason);
    }

    function _assertFalse(bool condition, string memory reason) private pure {
        require(!condition, reason);
    }

    function _assertEq(bool left, bool right, string memory reason) private pure {
        require(left == right, reason);
    }

    function _assertEq(address left, address right, string memory reason) private pure {
        require(left == right, reason);
    }

    function _assertEq(uint256 left, uint256 right, string memory reason) private pure {
        require(left == right, reason);
    }

    function _assertEqBytes4(bytes4 left, bytes4 right, string memory reason) private pure {
        require(left == right, reason);
    }

    function _assertEqBytes32(bytes32 left, bytes32 right, string memory reason) private pure {
        require(left == right, reason);
    }

    function _assertEqBytes(bytes memory left, bytes memory right, string memory reason) private pure {
        require(keccak256(left) == keccak256(right), reason);
    }
}
