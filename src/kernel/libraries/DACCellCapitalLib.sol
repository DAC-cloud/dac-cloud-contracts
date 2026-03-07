// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CapitalCall, Tranche, VotingConfig} from "../../interfaces/Structs.sol";
import {CapitalCallState} from "../interfaces/Structs.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {MainToken} from "../tokens/MainToken.sol";
import {DACManagementProposal} from "../governance/DACManagementProposal.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

library DACCellCapitalLib {
    
    function fulfillCapitalCall(
        CapitalCall memory call,
        MainToken mainToken,
        mapping(bytes32 => CapitalCallState) storage capitalCalls,
        mapping(address => uint256) storage treasuryBalances
    ) public returns (bool) {
        bytes32 callHash = keccak256(abi.encode(call));
        require(!capitalCalls[callHash].fulfilled, DACErrorsLib.AlreadyFulfilled());
        
        CapitalCall memory capitalCall = capitalCalls[callHash].call;
        require(capitalCall.tokenAmount > 0, DACErrorsLib.InvalidCapitalCall());

        require(
            IERC20(call.treasuryToken).transferFrom(msg.sender, address(this), call.cashAmount), 
            DACErrorsLib.TransferFailed()
        );

        treasuryBalances[call.treasuryToken] += call.cashAmount;

        mainToken.mint(call.tokenRecipient, call.tokenAmount);

        capitalCalls[callHash].fulfilled = true;

        emit DACEventsLib.CapitalCallFulfilled(call.tokenRecipient, callHash, call.tokenAmount);
        
        return true;
    }

    function depositTreasury(
        address token, 
        uint256 amount,
        address dealManager,
        mapping(address => uint256) storage treasuryBalances
    ) public {
        require(
            IDealManagerAdapter(dealManager).state(msg.sender).deal != address(0),
            DACErrorsLib.NotAuthorized()
        );

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), DACErrorsLib.TransferFailed());
        treasuryBalances[token] += amount;
        emit DACEventsLib.TreasuryDeposit(token, amount, msg.sender);
    }

    function recoverTreasury(
        address token,
        VotingConfig storage votingConfig,
        MainToken mainToken,
        mapping(address => uint256) storage treasuryBalances
    ) public {
        require(
            mainToken.balanceOf(msg.sender) > votingConfig.qualification,
            DACErrorsLib.InsufficientBalance()
        );

        if (IERC20(token).balanceOf(address(this)) > treasuryBalances[token]) {
            emit DACEventsLib.TreasuryDeposit(token, IERC20(token).balanceOf(address(this)) - treasuryBalances[token], msg.sender);
            treasuryBalances[token] = IERC20(token).balanceOf(address(this));
        }
    }

    function createCapitalCall(
        uint256 id,
        address treasuryToken,
        address recipient,
        uint256 amount,
        uint256 cashAmount,
        mapping(bytes32 => CapitalCallState) storage capitalCalls
    ) public returns (bytes32 callHash) {
        CapitalCall memory call = CapitalCall({
            treasuryToken: treasuryToken,
            nonce: id,
            tokenRecipient: recipient,
            tokenAmount: amount,
            cashAmount: cashAmount
        });

        callHash = keccak256(abi.encode(call));

        capitalCalls[callHash] = CapitalCallState({
            call: call,
            fulfilled: false
        });
    }

    function executeCapitalCall(
        uint256 id,
        DACManagementProposal prop,
        mapping(bytes32 => CapitalCallState) storage capitalCalls
    ) public {
        (address treasuryToken, uint256 cashAmount) = abi.decode(
            prop.data(), 
            (address, uint256)
        );

        emit DACEventsLib.CapitalCallCreated(
            id, 
            prop.target(), 
            createCapitalCall(
                id,
                treasuryToken,
                prop.target(),
                uint256(prop.i()),
                cashAmount,
                capitalCalls
            ), 
            uint256(prop.i())
        );
    }

    function claimDividend(
        uint256 proposalId,
        uint256 index,
        address receiver,
        uint256 amount,
        bytes32[] memory proof,
        mapping(uint256 => address) storage proposals,
        mapping(uint256 => bytes32) storage dividendMerkleRoots,
        mapping(bytes32 => bool) storage dividendClaimed
    ) public {
        bytes32 root = dividendMerkleRoots[proposalId];
        require(root != bytes32(0), DACErrorsLib.NotFound());

        bytes32 leaf = keccak256(abi.encodePacked(index, receiver, amount));

        bytes32 claimedKey = keccak256(abi.encodePacked(root, leaf));
        require(!dividendClaimed[claimedKey], DACErrorsLib.DividendAlreadyClaimed(proposalId, receiver));

        require(MerkleProof.verify(proof, root, leaf), DACErrorsLib.InvalidMerkleProof());

        dividendClaimed[claimedKey] = true;

        (address token) = abi.decode(
            DACManagementProposal(proposals[proposalId]).data(), 
            (address)
        );
        
        require(IERC20(token).transfer(receiver, amount), DACErrorsLib.TransferFailed());

        emit DACEventsLib.DividendClaimed(proposalId, receiver, amount);
    }
}
