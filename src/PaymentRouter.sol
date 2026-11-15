// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainSplitter} from "./CrossChainSplitter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PaymentRouter
/// @notice Accepts payment in USDC, USDT, or ETH, normalises the value to USDC
///         using a mock price feed, then forwards the USDC-equivalent amount
///         to the underlying CrossChainSplitter for distribution.
contract PaymentRouter is CrossChainSplitter {
    address public constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public constant USDT = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    struct PriceFeed {
        uint256 price; // USDC per 1e18 token units
        uint256 lastUpdated;
    }

    mapping(address => PriceFeed) private priceFeeds;

    event PriceFeedUpdated(address indexed token, uint256 price);
    event PaymentRouted(address indexed token, uint256 inputAmount, uint256 usdcAmount);

    constructor(address _bridge) CrossChainSplitter(_bridge) {}

    function setPriceFeed(address token, uint256 price) external onlyOwner {
        require(token != address(0), "zero token");
        priceFeeds[token] = PriceFeed(price, block.timestamp);
        emit PriceFeedUpdated(token, price);
    }

    function getPriceFeed(address token) external view returns (uint256 price, uint256 lastUpdated) {
        PriceFeed memory feed = priceFeeds[token];
        return (feed.price, feed.lastUpdated);
    }

    function payInUSDC(uint256 amount) external nonReentrant {
        _route(USDC, amount);
    }

    function payInUSDT(uint256 amount) external nonReentrant {
        uint256 usdcAmount = _normalizeToUSDC(USDT, amount);
        _route(USDT, amount);
        emit PaymentRouted(USDT, amount, usdcAmount);
    }

    function payInETH() external payable nonReentrant {
        uint256 usdcAmount = _normalizeToUSDC(address(0), msg.value);
        _route(address(0), msg.value);
        emit PaymentRouted(address(0), msg.value, usdcAmount);
    }

    function _normalizeToUSDC(address token, uint256 amount) internal view returns (uint256) {
        (uint256 price, ) = priceFeeds[token];
        require(price > 0, "no price feed");

        uint256 scaled = (amount * 1e18) / 10 ** _tokenDecimals(token);
        uint256 usdc18 = (scaled * price) / 1e18;
        return (usdc18 * 1e6) / 1e18;
    }

    function _tokenDecimals(address token) internal pure returns (uint256) {
        if (token == address(0)) return 18;
        try IERC20(token).decimals() returns (uint256 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _route(address token, uint256 amount) internal nonReentrant {
        if (token == address(0)) {
            _distribute(msg.sender, address(0), amount);
        } else {
            SafeERC20.safeTransferFrom(token, msg.sender, address(this), amount);
            _distribute(msg.sender, token, amount);
        }
    }
}