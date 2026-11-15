// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentSplitter} from "./PaymentSplitter.sol";

/// @title CrossChainSplitter
/// @notice Extends PaymentSplitter to support cross-chain recipients.
///         When a recipient's chain ID is not Arbitrum (this chain), the payment
///         is encoded as a CrossChainTransfer struct and queued for bridging.
contract CrossChainSplitter is PaymentSplitter {
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;

    struct CrossChainTransfer {
        address recipient;
        address token; // address(0) for native ETH
        uint256 amount;
        uint256 targetChainId;
        uint256 nonce;
    }

    event CrossChainPaymentQueued(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        uint256 targetChainId,
        uint256 nonce
    );

    // Mock bridge interface. In production this would be replaced by the
    // real Wormhole or LayerZero messaging interface, e.g.:
    //
    //   IWormhole (https://docs.wormhole.com/) or
    //   ILayerZero (https://layerzero.gitbook.io/) `send` function.
    // The call would look like:
    //
    //   IWormhole(bridge).sendPayload{value: fee}(
    //       targetChainId,
    //       recipientAddressBytes,
    //       abi.encode(transfer)
    //   );
    interface IBridge {
        function sendMessage(
            uint256 targetChainId,
            bytes memory recipientBytes,
            bytes memory payload
        ) external returns (uint256 nonce);
    }

    uint256 public nextNonce;
    IBridge public bridge;

    constructor(address _bridge) {
        bridge = IBridge(_bridge);
    }

    /// @notice Queue a cross-chain transfer for a recipient on a different chain.
    /// @param recipient The recipient address (on the target chain).
    /// @param token The token address (address(0) for native ETH).
    /// @param amount The amount to send.
    /// @param targetChainId The destination chain ID.
    function queueCrossChainPayment(
        address recipient,
        address token,
        uint256 amount,
        uint256 targetChainId
    ) external nonReentrant {
        require(targetChainId != block.chainid, "same chain");
        require(token != address(0) || address(this).balance >= amount, "insufficient balance");

        CrossChainTransfer memory transfer = CrossChainTransfer({
            recipient: recipient,
            token: token,
            amount: amount,
            targetChainId: targetChainId,
            nonce: nextNonce
        });

        // Record the transfer locally before bridging so it is auditable.
        emit CrossChainPaymentQueued(
            recipient,
            token,
            amount,
            targetChainId,
            nextNonce
        );

        // --- REAL BRIDGE PLUG-IN POINT ---
        // Replace the block below with the actual bridge call, e.g.:
        //
        // bytes memory recipientBytes = abi.encodePacked(recipient);
        // bytes memory payload = abi.encode(transfer);
        // bridge.sendMessage(targetChainId, recipientBytes, payload);
        //
        // For Wormhole you would also pay the message fee and handle the
        // emitter sequence. For LayerZero you would call `send` with the
        // adapterParams and pay the LZ fee in the source token.
        // -----------------------------------

        nextNonce++;
    }

    /// @notice Override _distribute to detect cross-chain recipients and queue
    ///         them instead of sending on-chain.
    function _distribute(
        address payer,
        address token,
        uint256 amount
    ) internal override {
        uint256 len = recipients.length;
        require(len > 0, "no recipients");

        uint256 timestamp = block.timestamp;
        emit PaymentReceived(payer, token, amount, timestamp);

        for (uint256 i = 0; i < len; i++) {
            Recipient memory r = recipients[i];
            uint256 share = (amount * r.shareBips) / totalShareBips;
            if (share == 0) continue;

            // Determine the target chain. Recipients on this chain are paid
            // directly; recipients on other chains are queued for bridging.
            uint256 targetChainId = _resolveChainId(r.account);

            if (targetChainId == ARBITRUM_CHAIN_ID || targetChainId == block.chainid) {
                // On-chain payout (same behavior as PaymentSplitter)
                paymentHistory[r.account].push(
                    PaymentRecord({
                        payer: payer,
                        token: token,
                        amount: share,
                        timestamp: timestamp
                    })
                );
                if (token == address(0)) {
                    (bool ok, ) = r.account.call{value: share}("");
                    require(ok, "transfer failed");
                } else {
                    SafeERC20.safeTransfer(IERC20(token), r.account, share);
                }
                emit RecipientPaid(r.account, token, share, timestamp);
            } else {
                // Cross-chain payout
                queueCrossChainPayment(r.account, token, share, targetChainId);
            }
        }
    }

    /// @dev Hook to resolve a recipient's chain ID. By default every recipient
    ///      is assumed to be on Arbitrum. Override this in a deployment-specific
    ///      contract or provide a recipient -> chainId registry.
    function _resolveChainId(address recipient) internal pure returns (uint256) {
        return ARBITRUM_CHAIN_ID;
    }
}