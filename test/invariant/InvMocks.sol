// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "../../src/lib/IPermit2.sol";
import {IPriceOracle} from "../../src/modules/core/interfaces/IPriceOracle.sol";

/// Plain ERC20 with configurable decimals and open mint (cash tokens of the harness).
contract InvToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Minimal Permit2 with the AllowanceTransfer semantics the treasury relies on:
/// owner -> token -> spender allowance with expiration, consumed by transferFrom.
contract InvPermit2 is IPermit2 {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }

    error AllowanceExpired();
    error InsufficientAllowance();
    error SignaturePathUnsupported();

    mapping(address => mapping(address => mapping(address => Allowance))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        // Real Permit2: expiration 0 means "block.timestamp".
        allowance[msg.sender][token][spender] =
            Allowance({amount: amount, expiration: expiration == 0 ? uint48(block.timestamp) : expiration});
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = allowance[from][token][msg.sender];
        if (block.timestamp > a.expiration) revert AllowanceExpired();
        if (a.amount != type(uint160).max) {
            if (a.amount < amount) revert InsufficientAllowance();
            a.amount -= amount;
        }
        require(IERC20(token).transferFrom(from, to, amount), "transferFrom");
    }

    function permitTransferFrom(PermitTransferFrom memory, SignatureTransferDetails calldata, address, bytes calldata)
        external
        pure
    {
        revert SignaturePathUnsupported();
    }
}

/// Settable price oracle (18-decimals normalized price per token).
contract InvOracle is IPriceOracle {
    mapping(address => uint256) public price;

    function setPrice(address token, uint256 p) external {
        price[token] = p;
    }

    function tokenPrice(address token) external view returns (uint256) {
        return price[token];
    }
}
