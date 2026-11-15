// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentSplitter} from "../src/PaymentSplitter.sol";
import {CrossChainSplitter, IBridge} from "../src/CrossChainSplitter.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 private _decimals = 18;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        _mint(msg.sender, 1000000 ether);
    }

    function totalSupply() external view returns (uint256) { return 1000000 ether; }
    function balanceOf(address account) external view returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
    function allowance(address owner, address spender) external view returns (uint256) { return _allowances[owner][spender]; }
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "exceeds allowance");
        _allowances[from][msg.sender] = allowed - amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
    function _mint(address to, uint256 amount) internal { _balances[to] += amount; }
}

contract MockBridge is IBridge {
    uint256 public nonce;
    bytes public lastPayload;
    function sendMessage(uint256 targetChainId, bytes memory recipientBytes, bytes memory payload) external returns (uint256 n) {
        n = nonce;
        lastPayload = payload;
        nonce++;
    }
}

contract PaymentSplitterTest is Test {
    PaymentSplitter public splitter;
    CrossChainSplitter public ccSplitter;
    PaymentRouter public router;
    MockERC20 public token;
    MockBridge public bridge;

    address payable recipient1 = payable(address(uint160(0x1111)));
    address payable recipient2 = payable(address(uint160(0x2222)));
    address payable recipient3 = payable(address(uint160(0x3333)));
    address payer = address(uint160(0xAAAA));

    function setUp() public {
        splitter = new PaymentSplitter();
        token = new MockERC20("TestToken", "TT");
        token.transfer(payer, 100000 ether);
        bridge = new MockBridge();
        ccSplitter = new CrossChainSplitter(address(bridge));
        router = new PaymentRouter(address(bridge));

        PaymentSplitter.Recipient[] memory recips = new PaymentSplitter.Recipient[](2);
        recips[0] = PaymentSplitter.Recipient({account: recipient1, shareBips: 6000});
        recips[1] = PaymentSplitter.Recipient({account: recipient2, shareBips: 4000});
        splitter.registerRecipients(recips);
    }

    function test_RegisterRecipients() public {
        assertEq(splitter.recipientCount(), 2);
        (address r1, uint256 s1) = splitter.getRecipient(0);
        assertEq(r1, recipient1);
        assertEq(s1, 6000);
    }

    function test_RevertWhenSharesDoNotSumTo100() public {
        vm.expectRevert("shares must sum to 100%");
        PaymentSplitter.Recipient[] memory recips = new PaymentSplitter.Recipient[](2);
        recips[0] = PaymentSplitter.Recipient({account: recipient1, shareBips: 5000});
        recips[1] = PaymentSplitter.Recipient({account: recipient2, shareBips: 4000});
        splitter.registerRecipients(recips);
    }

    function test_RevertWhenTooManyRecipients() public {
        vm.expectRevert("too many recipients");
        PaymentSplitter.Recipient[] memory recips = new PaymentSplitter.Recipient[](11);
        for (uint256 i = 0; i < 11; i++) {
            recips[i] = PaymentSplitter.Recipient({account: payable(address(uint160(i + 1))), shareBips: 909});
        }
        splitter.registerRecipients(recips);
    }

    function test_PayInETHSplitsCorrectly() public {
        vm.deal(payer, 100 ether);
        vm.prank(payer);
        splitter.payInETH{value: 100 ether}();
        assertEq(recipient1.balance, 60 ether);
        assertEq(recipient2.balance, 40 ether);
    }

    function test_PayInERC20SplitsCorrectly() public {
        uint256 amount = 1000 ether;
        token.transfer(payer, amount);
        vm.prank(payer);
        token.approve(address(splitter), amount);
        vm.prank(payer);
        splitter.payInERC20(address(token), amount);
        assertEq(token.balanceOf(recipient1), 600 ether);
        assertEq(token.balanceOf(recipient2), 400 ether);
    }

    function test_CrossChainPaymentQueued() public {
        CrossChainSplitterWithChain cc = new CrossChainSplitterWithChain(address(bridge));
        PaymentSplitter.Recipient[] memory recips = new PaymentSplitter.Recipient[](1);
        recips[0] = PaymentSplitter.Recipient({account: recipient1, shareBips: 10000});
        cc.registerRecipients(recips);
        vm.deal(payer, 100 ether);
        vm.deal(address(cc), 100 ether);

        vm.prank(payer);
        cc.payInETH{value: 100 ether}();

        assertEq(cc.nextNonce(), 1);
    }

    function testFuzz_PayInETH(uint256 amount) public {
        amount = bound(amount, 0, type(uint256).max / 10000);
        vm.deal(payer, amount);
        vm.prank(payer);
        splitter.payInETH{value: amount}();
        assertEq(recipient1.balance, (amount * 6000) / 10000);
        assertEq(recipient2.balance, (amount * 4000) / 10000);
    }

    function testFuzz_PayInERC20(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.approve(address(splitter), amount);
        splitter.payInERC20(address(token), amount);
        assertEq(token.balanceOf(recipient1), (amount * 6000) / 10000);
        assertEq(token.balanceOf(recipient2), (amount * 4000) / 10000);
    }
}

contract CrossChainSplitterWithChain is CrossChainSplitter {
    constructor(address _bridge) CrossChainSplitter(_bridge) {}
    function _resolveChainId(address) internal pure override returns (uint256) { return 1; }
}