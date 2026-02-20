// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPermit2 {
    struct PermitTransferFrom {
        address token;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

contract VaultTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable vaultDeal;
    IPermit2 public immutable permit2;

    mapping(bytes32 => bytes32) public approvedSpends; // proposal hash => calldataHash

    event SpendExecuted(address token, address destination, uint256 amount);
    event CapitalReturned(address token, uint256 amount);

    constructor(address _vaultDeal, address _permit2) {
        vaultDeal = _vaultDeal;
        permit2 = IPermit2(_permit2);
    }

    // Called by VaultDeal after staked-MP quorum approves
    function approveSpend(bytes32 proposalHash, bytes32 calldataHash) external {
        require(msg.sender == vaultDeal, "Only VaultDeal");
        approvedSpends[proposalHash] = calldataHash;
    }

    function executeWithPermit2(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature,
        bytes32 proposalHash
    ) external nonReentrant {
        require(msg.sender == vaultDeal, "Only VaultDeal");

        bytes32 expectedCalldataHash = approvedSpends[proposalHash];
        require(expectedCalldataHash != bytes32(0), "Spend not approved");

        // Verify the executed permit matches the approved proposal
        bytes32 executedCalldataHash = keccak256(abi.encode(permit, transferDetails));
        require(executedCalldataHash == expectedCalldataHash, "Permit does not match approved proposal");

        // Verify Permit2
        permit2.permitTransferFrom(permit, transferDetails, address(this), signature);

        delete approvedSpends[proposalHash]; // one-time use

        emit SpendExecuted(permit.token, transferDetails.to, transferDetails.requestedAmount);
    }

    // For returning capital to Deal (only original funding token)
    function returnCapitalToDeal(address token, uint256 balance) external {
        require(msg.sender == vaultDeal, "Only VaultDeal");

        IERC20(token).safeTransfer(vaultDeal, balance);
        emit CapitalReturned(token, balance);
    }
}