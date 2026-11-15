// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridge} from "./CrossChainSplitter.sol";

/// @notice Minimal mock bridge used only for local/anvil deployments.
///         Replace the address passed to CrossChainSplitter / PaymentRouter
///         with a real bridge (Wormhole / LayerZero) in production.
contract MockBridge is IBridge {
    uint256 public nonce;
    bytes public lastPayload;

    function sendMessage(
        uint256 targetChainId,
        bytes memory recipientBytes,
        bytes memory payload
    ) external returns (uint256 n) {
        n = nonce;
        lastPayload = payload;
        nonce++;
    }
}