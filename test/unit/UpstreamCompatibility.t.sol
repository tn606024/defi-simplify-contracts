// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Simple7702Account} from "@account-abstraction/contracts/accounts/Simple7702Account.sol";
import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract UpstreamCompatibilityTest {
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x433709009B8330FDa32311DF1C2AFA402eD8D009);

    function test_Simple7702AccountUsesConfiguredImmutableEntryPoint() external {
        Simple7702Account account = new Simple7702Account(ENTRY_POINT);
        require(address(account.entryPoint()) == address(ENTRY_POINT), "unexpected EntryPoint");
    }

    function test_Simple7702AccountPreservesInheritedInterfacesAndReceivers() external {
        Simple7702Account account = new Simple7702Account(ENTRY_POINT);

        require(account.supportsInterface(type(IERC165).interfaceId), "missing ERC-165");
        require(account.supportsInterface(type(IAccount).interfaceId), "missing ERC-4337 account");
        require(account.supportsInterface(type(IERC1271).interfaceId), "missing ERC-1271");
        require(account.supportsInterface(type(IERC721Receiver).interfaceId), "missing ERC-721 receiver");
        require(account.supportsInterface(type(IERC1155Receiver).interfaceId), "missing ERC-1155 receiver");
    }

    function test_Simple7702AccountReceiverHooksReturnExpectedSelectors() external {
        Simple7702Account account = new Simple7702Account(ENTRY_POINT);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);

        require(
            account.onERC721Received(address(this), address(this), 1, "") == IERC721Receiver.onERC721Received.selector,
            "unexpected ERC-721 receiver result"
        );
        require(
            account.onERC1155Received(address(this), address(this), 1, 1, "")
                == IERC1155Receiver.onERC1155Received.selector,
            "unexpected ERC-1155 receiver result"
        );
        require(
            account.onERC1155BatchReceived(address(this), address(this), ids, values, "")
                == IERC1155Receiver.onERC1155BatchReceived.selector,
            "unexpected ERC-1155 batch receiver result"
        );
    }

    function test_Simple7702AccountAcceptsPlainEthTransfers() external {
        Simple7702Account account = new Simple7702Account(ENTRY_POINT);
        (bool success,) = address(account).call("");
        require(success, "receive rejected");
    }

    function test_Simple7702AccountFallbackAcceptsUnknownCalls() external {
        Simple7702Account account = new Simple7702Account(ENTRY_POINT);
        (bool success,) = address(account).call(hex"deadbeef");
        require(success, "fallback rejected");
    }
}
