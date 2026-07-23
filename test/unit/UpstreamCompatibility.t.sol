// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

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
    uint256 private constant WRONG_ENTRY_POINT_DEFI_SIMPLIFY_KEY = 0xB0B;

    UpstreamCompatibilityFixture private compatibilityFixture;
    StaticCompatibilityTarget private upstreamTarget;
    StaticCompatibilityTarget private defiSimplifyTarget;

    receive() external payable {}

    function setUp() external {
        compatibilityFixture = _deployUpstreamCompatibilityFixture(IEntryPoint(address(this)));
        upstreamTarget = new StaticCompatibilityTarget();
        defiSimplifyTarget = new StaticCompatibilityTarget();
        vm.deal(address(this), 100 ether);
    }

    function test_DelegatedFixtureUsesEoaContextAndConfiguredEntryPoint() external {
        assertEq(
            _delegationTarget(compatibilityFixture.upstream.delegatedEoa),
            address(compatibilityFixture.upstream.implementation),
            "upstream delegation target"
        );
        assertEq(
            _delegationTarget(compatibilityFixture.defiSimplify.delegatedEoa),
            address(compatibilityFixture.defiSimplify.implementation),
            "DeFi Simplify delegation target"
        );
        assertEq(address(_upstreamAccountView(compatibilityFixture).entryPoint()), address(this), "upstream EntryPoint");
        assertEq(
            address(_defiSimplifyAccountView(compatibilityFixture).entryPoint()),
            address(this),
            "DeFi Simplify EntryPoint"
        );

        bytes memory upstreamData = abi.encodeCall(StaticCompatibilityTarget.record, (11, bytes("delegated-self-call")));
        bytes memory defiSimplifyData =
            abi.encodeCall(StaticCompatibilityTarget.record, (11, bytes("delegated-self-call")));

        vm.prank(compatibilityFixture.upstream.delegatedEoa);
        _upstreamAccountView(compatibilityFixture).execute(address(upstreamTarget), 0, upstreamData);
        vm.prank(compatibilityFixture.defiSimplify.delegatedEoa);
        _defiSimplifyAccountView(compatibilityFixture).execute(address(defiSimplifyTarget), 0, defiSimplifyData);

        _assertEquivalentTargetState();
        assertEq(upstreamTarget.lastCaller(), compatibilityFixture.upstream.delegatedEoa, "upstream target caller");
        assertEq(
            defiSimplifyTarget.lastCaller(),
            compatibilityFixture.defiSimplify.delegatedEoa,
            "DeFi Simplify target caller"
        );
    }

    function test_DifferentialExecutePreservesValueAndFinalState() external {
        vm.deal(compatibilityFixture.upstream.delegatedEoa, 2 ether);
        vm.deal(compatibilityFixture.defiSimplify.delegatedEoa, 2 ether);
        bytes memory upstreamData = abi.encodeCall(StaticCompatibilityTarget.record, (21, bytes("single")));
        bytes memory defiSimplifyData = abi.encodeCall(StaticCompatibilityTarget.record, (21, bytes("single")));

        _upstreamAccountView(compatibilityFixture).execute(address(upstreamTarget), 0.4 ether, upstreamData);
        _defiSimplifyAccountView(compatibilityFixture).execute(address(defiSimplifyTarget), 0.4 ether, defiSimplifyData);

        _assertEquivalentTargetState();
        assertEq(upstreamTarget.lastCaller(), compatibilityFixture.upstream.delegatedEoa, "upstream execute caller");
        assertEq(
            defiSimplifyTarget.lastCaller(),
            compatibilityFixture.defiSimplify.delegatedEoa,
            "DeFi Simplify execute caller"
        );
        assertEq(
            compatibilityFixture.upstream.delegatedEoa.balance,
            compatibilityFixture.defiSimplify.delegatedEoa.balance,
            "account balances"
        );
        assertEq(address(upstreamTarget).balance, address(defiSimplifyTarget).balance, "target balances");
    }

    function test_DifferentialExecuteBatchOneAndManyCalls() external {
        vm.deal(compatibilityFixture.upstream.delegatedEoa, 2 ether);
        vm.deal(compatibilityFixture.defiSimplify.delegatedEoa, 2 ether);

        BaseAccount.Call[] memory upstreamOne = new BaseAccount.Call[](1);
        BaseAccount.Call[] memory defiSimplifyOne = new BaseAccount.Call[](1);
        upstreamOne[0] = _buildRecordingCall(address(upstreamTarget), 1, 0, "one");
        defiSimplifyOne[0] = _buildRecordingCall(address(defiSimplifyTarget), 1, 0, "one");
        _upstreamAccountView(compatibilityFixture).executeBatch(upstreamOne);
        _defiSimplifyAccountView(compatibilityFixture).executeBatch(defiSimplifyOne);

        BaseAccount.Call[] memory upstreamMany = new BaseAccount.Call[](2);
        BaseAccount.Call[] memory defiSimplifyMany = new BaseAccount.Call[](2);
        upstreamMany[0] = _buildRecordingCall(address(upstreamTarget), 2, 0, "many-a");
        upstreamMany[1] = _buildRecordingCall(address(upstreamTarget), 3, 0.25 ether, "many-b");
        defiSimplifyMany[0] = _buildRecordingCall(address(defiSimplifyTarget), 2, 0, "many-a");
        defiSimplifyMany[1] = _buildRecordingCall(address(defiSimplifyTarget), 3, 0.25 ether, "many-b");
        _upstreamAccountView(compatibilityFixture).executeBatch(upstreamMany);
        _defiSimplifyAccountView(compatibilityFixture).executeBatch(defiSimplifyMany);

        _assertEquivalentTargetState();
        assertEq(upstreamTarget.lastCaller(), compatibilityFixture.upstream.delegatedEoa, "upstream batch caller");
        assertEq(
            defiSimplifyTarget.lastCaller(),
            compatibilityFixture.defiSimplify.delegatedEoa,
            "DeFi Simplify batch caller"
        );
        assertEq(
            compatibilityFixture.upstream.delegatedEoa.balance,
            compatibilityFixture.defiSimplify.delegatedEoa.balance,
            "batch account balances"
        );
        assertEq(address(upstreamTarget).balance, address(defiSimplifyTarget).balance, "batch target balances");
    }

    function test_DifferentialFailureReturndataAndAttribution() external {
        bytes memory targetFailure =
            abi.encodeWithSelector(StaticCompatibilityTarget.TargetFailure.selector, 77, bytes("nested"));
        bytes memory upstreamFailCall = abi.encodeCall(StaticCompatibilityTarget.fail, (77, bytes("nested")));
        bytes memory defiSimplifyFailCall = abi.encodeCall(StaticCompatibilityTarget.fail, (77, bytes("nested")));

        (bool upstreamSuccess, bytes memory upstreamReason) = _invokeExecuteAndCaptureResult(
            compatibilityFixture.upstream.delegatedEoa, address(upstreamTarget), 0, upstreamFailCall
        );
        (bool defiSimplifySuccess, bytes memory defiSimplifyReason) = _invokeExecuteAndCaptureResult(
            compatibilityFixture.defiSimplify.delegatedEoa, address(defiSimplifyTarget), 0, defiSimplifyFailCall
        );
        assertFalse(upstreamSuccess, "upstream execute should fail");
        assertFalse(defiSimplifySuccess, "DeFi Simplify execute should fail");
        assertEq(upstreamReason, targetFailure, "upstream execute reason");
        assertEq(defiSimplifyReason, targetFailure, "DeFi Simplify execute reason");

        BaseAccount.Call[] memory upstreamOne = new BaseAccount.Call[](1);
        BaseAccount.Call[] memory defiSimplifyOne = new BaseAccount.Call[](1);
        upstreamOne[0] = BaseAccount.Call({target: address(upstreamTarget), value: 0, data: upstreamFailCall});
        defiSimplifyOne[0] =
            BaseAccount.Call({target: address(defiSimplifyTarget), value: 0, data: defiSimplifyFailCall});
        (upstreamSuccess, upstreamReason) =
            _invokeExecuteBatchAndCaptureResult(compatibilityFixture.upstream.delegatedEoa, upstreamOne);
        (defiSimplifySuccess, defiSimplifyReason) =
            _invokeExecuteBatchAndCaptureResult(compatibilityFixture.defiSimplify.delegatedEoa, defiSimplifyOne);
        assertFalse(upstreamSuccess, "upstream one-call batch should fail");
        assertFalse(defiSimplifySuccess, "DeFi Simplify one-call batch should fail");
        assertEq(upstreamReason, targetFailure, "upstream one-call batch reason");
        assertEq(defiSimplifyReason, targetFailure, "DeFi Simplify one-call batch reason");

        BaseAccount.Call[] memory upstreamMany = new BaseAccount.Call[](2);
        BaseAccount.Call[] memory defiSimplifyMany = new BaseAccount.Call[](2);
        upstreamMany[0] = _buildRecordingCall(address(upstreamTarget), 1, 0, "rolled-back");
        upstreamMany[1] = BaseAccount.Call({target: address(upstreamTarget), value: 0, data: upstreamFailCall});
        defiSimplifyMany[0] = _buildRecordingCall(address(defiSimplifyTarget), 1, 0, "rolled-back");
        defiSimplifyMany[1] =
            BaseAccount.Call({target: address(defiSimplifyTarget), value: 0, data: defiSimplifyFailCall});
        bytes memory wrappedFailure = abi.encodeWithSelector(BaseAccount.ExecuteError.selector, 1, targetFailure);
        (upstreamSuccess, upstreamReason) =
            _invokeExecuteBatchAndCaptureResult(compatibilityFixture.upstream.delegatedEoa, upstreamMany);
        (defiSimplifySuccess, defiSimplifyReason) =
            _invokeExecuteBatchAndCaptureResult(compatibilityFixture.defiSimplify.delegatedEoa, defiSimplifyMany);
        assertFalse(upstreamSuccess, "upstream many-call batch should fail");
        assertFalse(defiSimplifySuccess, "DeFi Simplify many-call batch should fail");
        assertEq(upstreamReason, wrappedFailure, "upstream wrapped reason");
        assertEq(defiSimplifyReason, wrappedFailure, "DeFi Simplify wrapped reason");
        assertEq(upstreamTarget.count(), 0, "upstream state should roll back");
        assertEq(defiSimplifyTarget.count(), 0, "DeFi Simplify state should roll back");
    }

    function test_DifferentialValidateUserOpAndPrefund() external {
        bytes32 userOpHash = keccak256("static-compatible-user-operation");
        vm.deal(compatibilityFixture.upstream.delegatedEoa, 1 ether);
        vm.deal(compatibilityFixture.defiSimplify.delegatedEoa, 1 ether);
        uint256 entryPointBalanceBefore = address(this).balance;

        PackedUserOperation memory upstreamOp = _buildUserOperation(
            compatibilityFixture.upstream.delegatedEoa, _signature(UPSTREAM_AUTHORITY_KEY, userOpHash)
        );
        PackedUserOperation memory defiSimplifyOp = _buildUserOperation(
            compatibilityFixture.defiSimplify.delegatedEoa, _signature(DEFI_SIMPLIFY_AUTHORITY_KEY, userOpHash)
        );
        uint256 upstreamValidation =
            IAccount(compatibilityFixture.upstream.delegatedEoa).validateUserOp(upstreamOp, userOpHash, 0.2 ether);
        uint256 defiSimplifyValidation = IAccount(compatibilityFixture.defiSimplify.delegatedEoa)
            .validateUserOp(defiSimplifyOp, userOpHash, 0.2 ether);

        assertEq(upstreamValidation, 0, "upstream valid signature");
        assertEq(defiSimplifyValidation, 0, "DeFi Simplify valid signature");
        assertEq(
            compatibilityFixture.upstream.delegatedEoa.balance,
            compatibilityFixture.defiSimplify.delegatedEoa.balance,
            "prefund account balances"
        );
        assertEq(address(this).balance, entryPointBalanceBefore + 0.4 ether, "EntryPoint prefund balance");

        bytes memory wrongSignature = _signature(WRONG_SIGNER_KEY, userOpHash);
        upstreamOp.signature = wrongSignature;
        defiSimplifyOp.signature = wrongSignature;
        upstreamValidation =
            IAccount(compatibilityFixture.upstream.delegatedEoa).validateUserOp(upstreamOp, userOpHash, 0);
        defiSimplifyValidation =
            IAccount(compatibilityFixture.defiSimplify.delegatedEoa).validateUserOp(defiSimplifyOp, userOpHash, 0);
        assertEq(upstreamValidation, 1, "upstream invalid signature");
        assertEq(defiSimplifyValidation, 1, "DeFi Simplify invalid signature");
    }

    function test_DifferentialERC1271ValidAndInvalidSignatures() external view {
        bytes32 digest = keccak256("erc-1271-static-compatibility");
        bytes4 upstreamValid = IERC1271(compatibilityFixture.upstream.delegatedEoa)
            .isValidSignature(digest, _signature(UPSTREAM_AUTHORITY_KEY, digest));
        bytes4 defiSimplifyValid = IERC1271(compatibilityFixture.defiSimplify.delegatedEoa)
            .isValidSignature(digest, _signature(DEFI_SIMPLIFY_AUTHORITY_KEY, digest));
        bytes memory wrongSignature = _signature(WRONG_SIGNER_KEY, digest);
        bytes4 upstreamInvalid =
            IERC1271(compatibilityFixture.upstream.delegatedEoa).isValidSignature(digest, wrongSignature);
        bytes4 defiSimplifyInvalid =
            IERC1271(compatibilityFixture.defiSimplify.delegatedEoa).isValidSignature(digest, wrongSignature);

        assertEq(bytes32(upstreamValid), bytes32(IERC1271.isValidSignature.selector), "upstream ERC-1271 valid result");
        assertEq(
            bytes32(defiSimplifyValid),
            bytes32(IERC1271.isValidSignature.selector),
            "DeFi Simplify ERC-1271 valid result"
        );
        assertEq(bytes32(upstreamInvalid), bytes32(bytes4(0xffffffff)), "upstream ERC-1271 invalid result");
        assertEq(bytes32(defiSimplifyInvalid), bytes32(bytes4(0xffffffff)), "DeFi Simplify ERC-1271 invalid result");
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
            bool upstreamSupported = IERC165(compatibilityFixture.upstream.delegatedEoa).supportsInterface(ids[i]);
            bool defiSimplifySupported =
                IERC165(compatibilityFixture.defiSimplify.delegatedEoa).supportsInterface(ids[i]);
            assertEq(upstreamSupported, defiSimplifySupported, "ERC-165 differential result");
            assertEq(upstreamSupported, i < 5, "ERC-165 expected result");
        }

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        uint256[] memory tokenValues = new uint256[](2);
        tokenValues[0] = 3;
        tokenValues[1] = 4;

        assertEq(
            bytes32(
                IERC721Receiver(compatibilityFixture.upstream.delegatedEoa)
                    .onERC721Received(address(this), address(1), 2, "receiver")
            ),
            bytes32(
                IERC721Receiver(compatibilityFixture.defiSimplify.delegatedEoa)
                    .onERC721Received(address(this), address(1), 2, "receiver")
            ),
            "ERC-721 receiver result"
        );
        assertEq(
            bytes32(
                IERC1155Receiver(compatibilityFixture.upstream.delegatedEoa)
                    .onERC1155Received(address(this), address(1), 2, 3, "receiver")
            ),
            bytes32(
                IERC1155Receiver(compatibilityFixture.defiSimplify.delegatedEoa)
                    .onERC1155Received(address(this), address(1), 2, 3, "receiver")
            ),
            "ERC-1155 receiver result"
        );
        assertEq(
            bytes32(
                IERC1155Receiver(compatibilityFixture.upstream.delegatedEoa)
                    .onERC1155BatchReceived(address(this), address(1), tokenIds, tokenValues, "receiver")
            ),
            bytes32(
                IERC1155Receiver(compatibilityFixture.defiSimplify.delegatedEoa)
                    .onERC1155BatchReceived(address(this), address(1), tokenIds, tokenValues, "receiver")
            ),
            "ERC-1155 batch receiver result"
        );
    }

    function test_DifferentialFallbackAndReceiveBehavior() external {
        (bool upstreamSuccess, bytes memory upstreamData) =
            compatibilityFixture.upstream.delegatedEoa.call{value: 0.1 ether}("");
        (bool defiSimplifySuccess, bytes memory defiSimplifyData) =
            compatibilityFixture.defiSimplify.delegatedEoa.call{value: 0.1 ether}("");
        assertEq(upstreamSuccess, defiSimplifySuccess, "receive success");
        assertTrue(upstreamSuccess, "receive should succeed");
        assertEq(upstreamData, defiSimplifyData, "receive returndata");

        (upstreamSuccess, upstreamData) =
            compatibilityFixture.upstream.delegatedEoa.call{value: 0.2 ether}(hex"deadbeef0102");
        (defiSimplifySuccess, defiSimplifyData) =
            compatibilityFixture.defiSimplify.delegatedEoa.call{value: 0.2 ether}(hex"deadbeef0102");
        assertEq(upstreamSuccess, defiSimplifySuccess, "fallback success");
        assertTrue(upstreamSuccess, "fallback should succeed");
        assertEq(upstreamData, defiSimplifyData, "fallback returndata");
        assertEq(
            compatibilityFixture.upstream.delegatedEoa.balance,
            compatibilityFixture.defiSimplify.delegatedEoa.balance,
            "fallback and receive balances"
        );
    }

    function test_RandomCallerRejectedForCorrectReason() external {
        address randomCaller = address(0xCA11E2);
        bytes memory executeData = abi.encodeWithSelector(BaseAccount.execute.selector, address(upstreamTarget), 0, "");

        vm.prank(randomCaller);
        (bool upstreamSuccess, bytes memory upstreamReason) =
            compatibilityFixture.upstream.delegatedEoa.call(executeData);
        executeData = abi.encodeWithSelector(BaseAccount.execute.selector, address(defiSimplifyTarget), 0, "");
        vm.prank(randomCaller);
        (bool defiSimplifySuccess, bytes memory defiSimplifyReason) =
            compatibilityFixture.defiSimplify.delegatedEoa.call(executeData);

        assertFalse(upstreamSuccess, "random upstream caller should fail");
        assertFalse(defiSimplifySuccess, "random DeFi Simplify caller should fail");
        assertEq(
            upstreamReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector,
                randomCaller,
                compatibilityFixture.upstream.delegatedEoa,
                address(this)
            ),
            "upstream random caller reason"
        );
        assertEq(
            defiSimplifyReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector,
                randomCaller,
                compatibilityFixture.defiSimplify.delegatedEoa,
                address(this)
            ),
            "DeFi Simplify random caller reason"
        );
    }

    function test_MaliciousCallbackCallerRejectedForCorrectReason() external {
        StaticCompatibilityTarget maliciousTarget = new StaticCompatibilityTarget();
        bytes memory upstreamAttack =
            abi.encodeCall(StaticCompatibilityTarget.callAccountExecute, (compatibilityFixture.upstream.delegatedEoa));
        bytes memory defiSimplifyAttack = abi.encodeCall(
            StaticCompatibilityTarget.callAccountExecute, (compatibilityFixture.defiSimplify.delegatedEoa)
        );

        (bool upstreamSuccess, bytes memory upstreamReason) = _invokeExecuteAndCaptureResult(
            compatibilityFixture.upstream.delegatedEoa, address(maliciousTarget), 0, upstreamAttack
        );
        (bool defiSimplifySuccess, bytes memory defiSimplifyReason) = _invokeExecuteAndCaptureResult(
            compatibilityFixture.defiSimplify.delegatedEoa, address(maliciousTarget), 0, defiSimplifyAttack
        );
        assertFalse(upstreamSuccess, "malicious upstream callback should fail");
        assertFalse(defiSimplifySuccess, "malicious DeFi Simplify callback should fail");
        assertEq(
            upstreamReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector,
                address(maliciousTarget),
                compatibilityFixture.upstream.delegatedEoa,
                address(this)
            ),
            "upstream callback reason"
        );
        assertEq(
            defiSimplifyReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector,
                address(maliciousTarget),
                compatibilityFixture.defiSimplify.delegatedEoa,
                address(this)
            ),
            "DeFi Simplify callback reason"
        );
    }

    function test_WrongEntryPointRejectedByValidationPath() external {
        address wrongEntryPoint = address(0xBEEF);
        UpstreamCompatibilityFixture memory wrongEntryPointFixture = _deployUpstreamCompatibilityFixture(
            IEntryPoint(wrongEntryPoint), WRONG_ENTRY_POINT_UPSTREAM_KEY, WRONG_ENTRY_POINT_DEFI_SIMPLIFY_KEY
        );
        bytes32 userOpHash = keccak256("wrong-entrypoint");
        PackedUserOperation memory upstreamOp = _buildUserOperation(wrongEntryPointFixture.upstream.delegatedEoa, "");
        PackedUserOperation memory defiSimplifyOp =
            _buildUserOperation(wrongEntryPointFixture.defiSimplify.delegatedEoa, "");
        bytes memory upstreamCall = abi.encodeCall(IAccount.validateUserOp, (upstreamOp, userOpHash, 0));
        bytes memory defiSimplifyCall = abi.encodeCall(IAccount.validateUserOp, (defiSimplifyOp, userOpHash, 0));

        (bool upstreamSuccess, bytes memory upstreamReason) =
            wrongEntryPointFixture.upstream.delegatedEoa.call(upstreamCall);
        (bool defiSimplifySuccess, bytes memory defiSimplifyReason) =
            wrongEntryPointFixture.defiSimplify.delegatedEoa.call(defiSimplifyCall);
        assertFalse(upstreamSuccess, "wrong upstream EntryPoint should fail");
        assertFalse(defiSimplifySuccess, "wrong DeFi Simplify EntryPoint should fail");
        assertEq(
            upstreamReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector,
                address(this),
                wrongEntryPointFixture.upstream.delegatedEoa,
                wrongEntryPoint
            ),
            "wrong upstream EntryPoint reason"
        );
        assertEq(
            defiSimplifyReason,
            abi.encodeWithSelector(
                BaseAccount.NotFromEntryPoint.selector,
                address(this),
                wrongEntryPointFixture.defiSimplify.delegatedEoa,
                wrongEntryPoint
            ),
            "wrong DeFi Simplify EntryPoint reason"
        );
    }

    function test_DifferentialStaticEventSurfaceContainsOnlyTargetEvent() external {
        bytes memory upstreamData = abi.encodeCall(StaticCompatibilityTarget.record, (91, bytes("event")));
        bytes memory defiSimplifyData = abi.encodeCall(StaticCompatibilityTarget.record, (91, bytes("event")));

        vm.recordLogs();
        _upstreamAccountView(compatibilityFixture).execute(address(upstreamTarget), 0, upstreamData);
        Vm.Log[] memory upstreamLogs = vm.getRecordedLogs();
        vm.recordLogs();
        _defiSimplifyAccountView(compatibilityFixture).execute(address(defiSimplifyTarget), 0, defiSimplifyData);
        Vm.Log[] memory defiSimplifyLogs = vm.getRecordedLogs();

        assertEq(upstreamLogs.length, 1, "upstream log count");
        assertEq(defiSimplifyLogs.length, 1, "DeFi Simplify log count");
        assertEq(upstreamLogs[0].emitter, address(upstreamTarget), "upstream log emitter");
        assertEq(defiSimplifyLogs[0].emitter, address(defiSimplifyTarget), "DeFi Simplify log emitter");
        assertEq(abi.encode(upstreamLogs[0].topics), abi.encode(defiSimplifyLogs[0].topics), "log topics");
        assertEq(upstreamLogs[0].data, defiSimplifyLogs[0].data, "log data");
    }

    function _buildRecordingCall(address callTarget, uint256 amount, uint256 callValue, bytes memory payload)
        private
        pure
        returns (BaseAccount.Call memory)
    {
        return BaseAccount.Call({
            target: callTarget,
            value: callValue,
            data: abi.encodeCall(StaticCompatibilityTarget.record, (amount, payload))
        });
    }

    function _invokeExecuteAndCaptureResult(
        address delegatedEoa,
        address callTarget,
        uint256 callValue,
        bytes memory callData
    ) private returns (bool success, bytes memory result) {
        return delegatedEoa.call(abi.encodeWithSelector(BaseAccount.execute.selector, callTarget, callValue, callData));
    }

    function _invokeExecuteBatchAndCaptureResult(address delegatedEoa, BaseAccount.Call[] memory calls)
        private
        returns (bool success, bytes memory result)
    {
        return delegatedEoa.call(abi.encodeWithSelector(BaseAccount.executeBatch.selector, calls));
    }

    function _buildUserOperation(address sender, bytes memory signature)
        private
        pure
        returns (PackedUserOperation memory operation)
    {
        operation.sender = sender;
        operation.signature = signature;
    }

    function _assertEquivalentTargetState() private view {
        assertEq(upstreamTarget.count(), defiSimplifyTarget.count(), "target count");
        assertEq(upstreamTarget.total(), defiSimplifyTarget.total(), "target total");
        assertEq(upstreamTarget.totalCallValue(), defiSimplifyTarget.totalCallValue(), "target call value");
        assertEq(upstreamTarget.lastPayloadHash(), defiSimplifyTarget.lastPayloadHash(), "target payload hash");
    }
}
