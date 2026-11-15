// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

/// @title PaymentSplitter
/// @notice Splits ETH or ERC-20 payments among up to 10 registered recipients by percentage.
contract PaymentSplitter is Ownable, ReentrancyGuard {
    uint256 public constant MAX_RECIPIENTS = 10;

    constructor() Ownable(msg.sender) {}

    struct Recipient {
        address payable account;
        uint256 shareBips; // basis points (1/100th of a percent)
    }

    struct PaymentRecord {
        address payer;
        address token; // address(0) for native ETH
        uint256 amount;
        uint256 timestamp;
    }

    event RecipientRegistered(address indexed recipient, uint256 shareBips);
    event PaymentReceived(
        address indexed payer,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );
    event RecipientPaid(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    Recipient[] internal recipients;
    uint256 internal totalShareBips;

    // recipient index -> payment history
    mapping(address => PaymentRecord[]) internal paymentHistory;

    modifier onlyRegistered() {
        require(_isRecipient(msg.sender), "not a registered recipient");
        _;
    }

    function _isRecipient(address account) internal view returns (bool) {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].account == account) return true;
        }
        return false;
    }

    function registerRecipients(
        Recipient[] memory newRecipients
    ) external onlyOwner {
        require(newRecipients.length > 0, "no recipients");
        require(
            newRecipients.length <= MAX_RECIPIENTS,
            "too many recipients"
        );

        uint256 sum;
        for (uint256 i = 0; i < newRecipients.length; i++) {
            require(
                newRecipients[i].account != address(0),
                "zero address"
            );
            require(
                newRecipients[i].shareBips > 0,
                "zero share"
            );
            sum += newRecipients[i].shareBips;
        }
        require(sum == 10000, "shares must sum to 100%");

        // Storage arrays of structs cannot be assigned directly from memory,
        // so we push each element individually.
        for (uint256 i = 0; i < newRecipients.length; i++) {
            recipients.push(newRecipients[i]);
        }
        totalShareBips = sum;

        for (uint256 i = 0; i < newRecipients.length; i++) {
            emit RecipientRegistered(
                newRecipients[i].account,
                newRecipients[i].shareBips
            );
        }
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function getRecipient(
        uint256 index
    ) external view returns (address payable, uint256) {
        return (recipients[index].account, recipients[index].shareBips);
    }

    function getPaymentHistory(
        address recipient
    ) external view returns (PaymentRecord[] memory) {
        return paymentHistory[recipient];
    }

    function payInETH() external payable virtual nonReentrant {
        _distribute(msg.sender, address(0), msg.value);
    }

    function payInERC20(
        address token,
        uint256 amount
    ) external virtual nonReentrant {
        require(token != address(0), "zero token");
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        _distribute(msg.sender, token, amount);
    }

    function _distribute(
        address payer,
        address token,
        uint256 amount
    ) internal virtual {
        uint256 len = recipients.length;
        require(len > 0, "no recipients");

        uint256 timestamp = block.timestamp;
        emit PaymentReceived(payer, token, amount, timestamp);

        for (uint256 i = 0; i < len; i++) {
            Recipient memory r = recipients[i];
            uint256 share = (amount * r.shareBips) / totalShareBips;
            if (share == 0) continue;

            // record history
            paymentHistory[r.account].push(
                PaymentRecord({
                    payer: payer,
                    token: token,
                    amount: share,
                    timestamp: timestamp
                })
            );

            // send funds
            if (token == address(0)) {
                (bool ok, ) = r.account.call{value: share}("");
                require(ok, "transfer failed");
            } else {
                SafeERC20.safeTransfer(IERC20(token), r.account, share);
            }

            emit RecipientPaid(r.account, token, share, timestamp);
        }
    }

    receive() external payable {
        // disallow plain sends; payments must go through payInETH
        revert("use payInETH");
    }
}