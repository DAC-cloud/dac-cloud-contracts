// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig, DealParams} from "../../interfaces/Structs.sol";
import {IDACCellAdapter} from "../../interfaces/IDACCellAdapter.sol";
import {IDeal} from "../../interfaces/IDeal.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IDealManagementProposalFactory} from "../../interfaces/IDealManagementProposalFactory.sol";
import {Tranche, DealState} from "../interfaces/Structs.sol";
import {StakedAgent} from "../tokens/StakedAgent.sol";
import {AbstractDealManagementType} from "../governance/AbstractDealManagementProposals.sol";

interface IDealGovernanceAdapter {
    function closeDeal()
        external;
}

library DealCellGovernance {

    error DeadlineNotPassed();
    error NotStakedAgent();
    error NotEnoughBalance();

    error DealIsNotApproved();

    error InsufficientRewards();

    error TransferFailed();

    event CapitalReturned(address indexed dac, uint256 indexed id, address token, uint256 amount);

    event RewardsAllocated(address indexed dac, uint256 indexed id, uint256 reward);
    event StakesSlashed(address indexed dac, uint256 indexed id, uint256 slashAmount);
    
    event DealManagementProposalCreated(address indexed cell, uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);

    function checkStakedAgentProposal(
        ProposalParams calldata params,
        address dealCell,
        VotingConfig memory votingConfig
    ) public view returns (bool isBase) {
        if (msg.sender != address(this)) {
            require(IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > 0, NotStakedAgent());

            require(
                IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > votingConfig.qualification,
                NotEnoughBalance()
            );
        }

        if (!IDealCell(dealCell).isApproved()) {
            require(
                (
                    params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
                    params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
                    params.typ == AbstractDealManagementType.TOGGLE_WHITELIST
                ),
                DealIsNotApproved()
            );
        }

        isBase =(
            params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
            params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
            params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
            params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
            params.typ == AbstractDealManagementType.ADD_STAKE
        );
    }

    function createStakedAgentProposal(
        uint256 id,
        ProposalParams calldata params,
        address dealCell,
        VotingConfig memory votingConfig,
        address governanceFactory,
        mapping(uint256 => address) storage proposals
    ) public {
        address prop = IDealManagementProposalFactory(governanceFactory).deployProposal(
            id,
            params,
            address(this),
            address(this),
            votingConfig
        );

        proposals[id] = prop;

        emit DealManagementProposalCreated(dealCell, id, params.typ, params.target, params.i, params.data);
    }

    function prepareWithdrawal(
        address dealCell
    ) public {
        address[] memory _fundingTokens = IDealCell(dealCell).fundingTokens();

        for (uint256 i = 0; i < _fundingTokens.length; i++) {
            address _fundingToken = _fundingTokens[i];

            uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
            if (balance == 0) continue;

            IERC20(_fundingToken).approve(dealCell, balance);
        }
    }

    function withdrawCapital(
        uint256 id,
        bool earlyReturns,
        address dacCell,
        uint256 _dealDeadline,
        StakedAgent token,
        IDeal deal,
        address[] storage _fundingTokens,
        mapping(address => uint256) storage returnedCapital
    ) public {
        if (msg.sender == dacCell) {
            require(block.timestamp > _dealDeadline, DeadlineNotPassed());
        }
        else {
            require(token.balanceOf(msg.sender) != 0, NotStakedAgent());
            if (!earlyReturns) {
                require(block.timestamp > _dealDeadline, DeadlineNotPassed());
            }
        }
        
        deal.beforeWithdrawCapital();

        // Iterate through all funding tokens and return every balance
        for (uint256 i = 0; i < _fundingTokens.length; i++) {
            address _fundingToken = _fundingTokens[i];

            uint256 dealAllowance = IERC20(_fundingToken).allowance(address(deal), address(this));
            if (dealAllowance > 0) {
                require(
                    IERC20(_fundingToken).transferFrom(address(deal), address(this), dealAllowance),
                    TransferFailed()
                );
            }

            uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
            if (balance == 0) continue;

            IERC20(_fundingToken).approve(dacCell, balance);

            IDACCellAdapter(dacCell).depositTreasury(_fundingToken, balance);
            returnedCapital[_fundingToken] += balance;
            
            emit CapitalReturned(dacCell, id, _fundingToken, balance);
        }

        deal.afterWithdrawCapital();
    }

    function markAsSuccess(
        uint256 rewardPercent,
        uint256 id,
        address dacCell,
        StakedAgent token,
        IDeal deal,
        uint256 rewardsConverted,
        uint256 _tokenRewardsLimit,
        address[] storage holders,
        mapping(address => uint256) storage claimableRewards,
        address self
    ) public {
        require(rewardsConverted + rewardPercent <= 100, InsufficientRewards());

        deal.onMarkAsSuccess(rewardPercent);

        uint256 reward = (_tokenRewardsLimit * rewardPercent) / 100;

        uint256 transformAmount = reward; // for event

        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderShare = (token.balanceOf(h) * reward) / token.totalSupply();  // pro-rata on original stake
            claimableRewards[h] = holderShare;
        }

        rewardsConverted += rewardPercent;

        // if all rewards were paid out, marking the deal as closed so MP tokens can withdraw stakes
        if (rewardsConverted == 100) {
            IDealGovernanceAdapter(self).closeDeal();
        }

        emit RewardsAllocated(dacCell, id, transformAmount);
    }

    function markAsFailed(
        uint256 slashPercent,
        uint256 id,
        address dacCell,
        StakedAgent token,
        IDeal deal,
        address[] storage holders
    ) public {
        uint256 slashAmount = (token.totalSupply() * slashPercent) / 100;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderSlash = (token.balanceOf(h) * slashPercent) / 100;
            token.burn(h, holderSlash);
        }
        
        emit StakesSlashed(dacCell, id, slashAmount);

        deal.onMarkAsFailed(slashPercent);
    }
}