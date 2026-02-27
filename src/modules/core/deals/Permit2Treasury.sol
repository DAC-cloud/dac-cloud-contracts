// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "../../../lib/IPermit2.sol";

contract Permit2Treasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable treasuryDeal;
    IPermit2 public immutable permit2;

    mapping(bytes32 => uint256) public approvedAgents; // calldataHash, totalAmount

    event SpendApproved(address token, address destination, uint256 amount);
    event AgentApproved(address indexed agent, address token, address source, uint256 amount);
    event Receipt(address indexed agent, address token, address source, uint256 amount);

    event CapitalReturned(address token, uint256 amount);

    constructor(address _treasuryDeal, address _permit2) {
        treasuryDeal = _treasuryDeal;
        permit2 = IPermit2(_permit2);
    }

    // Called by TreasuryDeal after staked-MP quorum approves a spend
    function approveSpend(
        address token,
        address spender,         // e.g. Uniswap router, another contract
        uint160 amount,
        uint48 expiration        // short expiry (e.g. 1 hour)
    ) external {
        require(msg.sender == treasuryDeal, "Only TreasuryDeal");
        
        // Approving the whole balance to permit2
        IERC20(token).approve(address(permit2), type(uint160).max);

        // On-chain Permit2 approval (no signature needed to spend)
        // to govern single spend transactions by routers / service providers.
        permit2.approve(token, spender, amount, expiration);

        emit SpendApproved(token, spender, amount);
    }

    // Called by TreasuryDeal after staked-MP quorum approves an agent to receive funds
    function approveReceive(
        address agent,
        address source,          // e.g. client of a DAC, other team treasury, etc.
        address token,
        uint160 amount
    ) external {
        require(msg.sender == treasuryDeal, "Only TreasuryDeal");

        bytes32 calldataHash = keccak256(abi.encode(agent, token, source));
        approvedAgents[calldataHash] = amount;

        emit AgentApproved(agent, token, source, amount);
    }

    // Called by an assigned agent after approval
    //  (e.g. our service executes gasless x402 payment receive)
    function executeReceivePermit2(
        address token,
        address source,
        uint256 amount
    ) external nonReentrant {
        bytes32 calldataHash = keccak256(abi.encode(msg.sender, token, source));
        
        require(approvedAgents[calldataHash] >= amount, "Receival not approved");

        approvedAgents[calldataHash] -= amount;

        // Execute transfer to treasury via Permit2 (uses the on-chain approval)
        permit2.transferFrom(source, address(this), amount, token);

        emit Receipt(msg.sender, token, source, amount);
    }

    function executeReceivePermit2Signature(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address source,
        bytes calldata signature
    ) external nonReentrant {
        require(transferDetails.to == address(this), "Invalid transfer");
        
        bytes32 calldataHash = keccak256(abi.encode(msg.sender, permit.token, source));

        require(approvedAgents[calldataHash] >= transferDetails.requestedAmount, "Receival not approved");
        
        approvedAgents[calldataHash] -= transferDetails.requestedAmount;

        permit2.permitTransferFrom(permit, transferDetails, source, signature);

        emit Receipt(msg.sender, permit.token, source, transferDetails.requestedAmount);
    }

    // For returning capital to Deal
    function returnCapitalToDeal(address token, uint256 balance) external {
        require(msg.sender == treasuryDeal, "Only TreasuryDeal");

        IERC20(token).safeTransfer(treasuryDeal, balance);
        emit CapitalReturned(token, balance);
    }
}

library Permit2TreasuryLibrary {
    function deployPermit2Treasury(
        address deal,
        address _permit2
    ) public returns (Permit2Treasury) {
        return new Permit2Treasury(deal, _permit2);
    }
}