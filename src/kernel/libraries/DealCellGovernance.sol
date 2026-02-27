// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig} from "../../interfaces/Structs.sol";
import {IDACCellAdapter} from "../../interfaces/IDACCellAdapter.sol";
import {IDeal} from "../../interfaces/IDeal.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IDealManagementProposalFactory} from "../../interfaces/IDealManagementProposalFactory.sol";
import {AgentToken} from "../tokens/AgentToken.sol";
import {StakedAgent} from "../tokens/StakedAgent.sol";
import {AbstractDealManagementType} from "../governance/AbstractDealManagementProposals.sol";
import {Tranche} from "../interfaces/Structs.sol";

interface IDealGovernanceAdapter {
    function closeDeal()
        external;
}

library DealCellGovernance {

    event AgentTokensStaked(address indexed dac, uint256 indexed id, address indexed agent, uint256 amount);
    event AgentTokensReleased(address indexed dac, uint256 indexed id, address indexed agent, uint256 amount);

    error NoStake();

    error DeadlineNotPassed();
    error NotStakedAgent();
    error NotEnoughBalance();

    error DealIsNotApproved();
    error DealAlreadyApproved();

    error TrancheNotExists();
    error TrancheAlreadySettled();

    error InsufficientRewards();

    error TransferFailed();

    event CapitalReturned(address indexed dac, uint256 indexed id, address token, uint256 amount);

    event RewardsAllocated(address indexed dac, uint256 indexed id, uint256 reward);
    event StakesSlashed(address indexed dac, uint256 indexed id, uint256 slashAmount);
    
    event DealManagementProposalCreated(address indexed cell, uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);

    function stake(
        address dacCell,
        address staker,
        uint256 amount,
        uint256 id,
        IDeal deal,
        StakedAgent token,
        address[] storage holders
    ) public {
        deal.beforeEveryStake(staker, amount);

        if (token.balanceOf(staker) == 0) {
            holders.push(staker);
        }
        
        token.mint(staker, amount);
        
        emit AgentTokensStaked(dacCell, id, staker, amount);

        deal.afterEveryStake(staker, amount);
    }

    function unstake(
        address dacCell,
        uint256 id,
        IDeal deal,
        address agentTokenAddr,
        StakedAgent token
    ) public {
        address agent = msg.sender;
        require(token.balanceOf(agent) > 0, NoStake());

        uint256 agentStake = token.balanceOf(agent);

        token.burn(agent, agentStake);

        AgentToken(agentTokenAddr).burnFrom(address(this), agentStake); // burn agent tokens on our balance
        AgentToken(agentTokenAddr).mint(agent, agentStake);             // return agent tokens back to agent

        emit AgentTokensReleased(dacCell, id, agent, agentStake);

        deal.onUnstake(agent, agentStake);
    }

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
            params.typ == AbstractDealManagementType.ENABLE_VETO_RIGHT ||
            params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
            params.typ == AbstractDealManagementType.ADD_STAKE
        );
    }

    function createStakedAgentProposal(
        uint256 id,
        ProposalParams calldata params,
        address dacCell,
        address dealCell,
        VotingConfig memory votingConfig,
        address governanceFactory,
        mapping(uint256 => address) storage proposals
    ) public {
        address prop = IDealManagementProposalFactory(governanceFactory).deployProposal(
            id,
            params,
            dacCell,
            dealCell,
            IDealCell(dealCell).stakeToken(),
            IDealCell(dealCell).allowDACVeto(),
            votingConfig
        );

        proposals[id] = prop;

        emit DealManagementProposalCreated(dealCell, id, params.typ, params.target, params.i, params.data);
    }

    function approveFunding(
        uint256 trancheId,
        bool approved,
        uint256 _approveDeadline,
        IDeal deal,
        mapping(uint256 => Tranche) storage _fundingTranches,
        mapping(address => uint256) storage investedCapital
    ) public {
        if (trancheId == 0) {
            require(!approved, DealAlreadyApproved());
            require(block.timestamp > _approveDeadline, DeadlineNotPassed());
        }
        else {
            require(_fundingTranches[trancheId].amount > 0, TrancheNotExists());
            require(!_fundingTranches[trancheId].settled, TrancheAlreadySettled());
        }
        
        if (_fundingTranches[trancheId].amount > 0) {
            require(IERC20(_fundingTranches[trancheId].token).transfer(address(deal), _fundingTranches[trancheId].amount), TransferFailed());

            investedCapital[_fundingTranches[trancheId].token] += _fundingTranches[trancheId].amount;
        }
        _fundingTranches[trancheId].settled = true;
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

    function transferCapital(
        uint256 id,
        address _token,
        uint256 amount,
        address dacCell,
        mapping(address => uint256) storage returnedCapital
    ) public {
        IERC20(_token).approve(dacCell, amount);

        IDACCellAdapter(dacCell).depositTreasury(_token, amount);
        returnedCapital[_token] += amount;
        
        emit CapitalReturned(dacCell, id, _token, amount);
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

            transferCapital(id, _fundingToken, balance, dacCell, returnedCapital);
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