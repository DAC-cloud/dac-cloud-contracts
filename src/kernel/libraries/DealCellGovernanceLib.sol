// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig, Tranche} from "../../interfaces/Structs.sol";
import {IDACCellAdapter} from "../interfaces/IDACCellAdapter.sol";
import {IDeal} from "../../interfaces/IDeal.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {IDealManagementProposalFactory} from "../interfaces/IDealManagementProposalFactory.sol";
import {DealManagementProposal} from "../governance/DealManagementProposal.sol";
import {AgentToken} from "../tokens/AgentToken.sol";
import {StakedAgent} from "../tokens/StakedAgent.sol";
import {AbstractDealManagementType} from "../governance/AbstractDealManagementProposals.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";
import {MathLib} from "./MathLib.sol";

interface IDealCellGovernanceAdapter {
    function closeDeal() external;
    function invite(address invitee, bool grantInviteRight) external;
}

library DealCellGovernanceLib {

    function whitelistHolders(
        address[] storage holders
    ) public {
        // Inviting all existing manager with invite capability
        for (uint256 i = 0; i < holders.length; i++) {
            address agent = holders[i];
            IDealCellGovernanceAdapter(address(this)).invite(agent, true);
        }
    }

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
        
        emit DACEventsLib.AgentTokensStaked(dacCell, id, address(deal), staker, amount);

        deal.afterEveryStake(staker, amount);
    }

    function addStake(
        address dacCell,
        address staker,
        uint256 amount,
        uint256 id,
        IDeal deal,
        StakedAgent token,
        address[] storage holders
    ) public {
        require(
            token.transferFrom(
                staker, address(this), amount
            ),
            DACErrorsLib.TransferFailed()
        );

        deal.beforeEveryStake(staker, amount);

        if (token.balanceOf(staker) == 0) {
            holders.push(staker);
        }
        
        token.mint(staker, amount);
        
        emit DACEventsLib.AgentTokensStaked(dacCell, id, address(deal), staker, amount);

        deal.afterEveryStake(staker, amount);
    }

    function unstake(
        address dacCell,
        uint256 id,
        IDeal deal,
        address agent,
        address agentTokenAddr,
        StakedAgent token
    ) public {
        require(token.balanceOf(agent) > 0, DACErrorsLib.NoStake());

        uint256 agentStake = token.balanceOf(agent);

        token.burn(agent, agentStake);

        require(AgentToken(agentTokenAddr).transfer(agent, agentStake), DACErrorsLib.TransferFailed());

        emit DACEventsLib.AgentTokensReleased(dacCell, id, address(deal), agent, agentStake);

        deal.onUnstake(agent, agentStake);
    }

    function unstakeAgent(
        address dacCell,
        uint256 id,
        IDeal deal,
        bool closed,
        bool approved,
        bool recovery,
        uint256 approveDeadline,
        address agentTokenAddr,
        StakedAgent token
    ) public {
        // allow to unstake if the deal is closed
        if (!closed) {
            if (!approved) {
                // if deadline passed, allowing to unstake
                require(block.timestamp > approveDeadline, DACErrorsLib.DeadlineNotPassed());
            }
            else {
                require(token.balanceOf(msg.sender) > 0, DACErrorsLib.NoStake());

                require(token.totalSupply() > token.balanceOf(msg.sender), DACErrorsLib.NotAllowed());

                // Deal is approved, creating a proposal so agents can agree on allowing
                // agent to leave the deal

                deal.createStakedAgentProposal(ProposalParams({
                    typ: AbstractDealManagementType.PERMIT_UNSTAKE,
                    target: msg.sender,
                    i: bytes32(token.balanceOf(msg.sender)),
                    data: abi.encode(0)
                }));

                return;
            }
        }
        else {
            // if the recovery is on, no more unstakes
            require(!recovery, DACErrorsLib.DealInLiquidation());
        }
        
        unstake(
            dacCell,
            id,
            deal,
            msg.sender,
            agentTokenAddr,
            token
        );
    }

    function checkStakedAgentProposal(
        ProposalParams memory params,
        address dealCell,
        VotingConfig memory votingConfig
    ) public view returns (bool isBase) {
        if (msg.sender != address(this)) {
            if (msg.sender == dealCell) {
                // Deal cell is only allowed to propose PERMIT_UNSTAKE
                require(
                    (
                        params.typ == AbstractDealManagementType.PERMIT_UNSTAKE
                    ),
                    DACErrorsLib.ProposalNotSupported()
                );
            }

            else if(msg.sender == IDealCell(dealCell).manager()) {
                // Deal manager is only allowed to propose PERMIT_EVALUATOR_ADD
                require(
                    (
                        params.typ == AbstractDealManagementType.PERMIT_EVALUATOR_ADD
                    ),
                    DACErrorsLib.ProposalNotSupported()
                );
            }

            else {
                // Checking that agents do not propose special proposals
                require(
                    !(
                        params.typ == AbstractDealManagementType.PERMIT_UNSTAKE ||
                        params.typ == AbstractDealManagementType.PERMIT_EVALUATOR_ADD
                    ),
                    DACErrorsLib.ProposalNotSupported()
                );

                require(
                    IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > 0, 
                    DACErrorsLib.NotStakedAgent()
                );

                require(
                    IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > votingConfig.qualification,
                    DACErrorsLib.NotEnoughBalance()
                );
            }
        }

        if (!IDealCell(dealCell).isApproved()) {
            require(
                (
                    params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
                    params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
                    params.typ == AbstractDealManagementType.TOGGLE_WHITELIST
                ),
                DACErrorsLib.DealIsNotApproved()
            );
        }

        isBase =(
            params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
            params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
            params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
            params.typ == AbstractDealManagementType.ENABLE_VETO_RIGHT ||
            params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
            params.typ == AbstractDealManagementType.ADD_STAKE ||
            params.typ == AbstractDealManagementType.PERMIT_UNSTAKE ||
            params.typ == AbstractDealManagementType.PERMIT_EVALUATOR_ADD
        );
    }

    function createStakedAgentProposal(
        uint256 id,
        ProposalParams memory params,
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

        emit DACEventsLib.DealManagementProposalCreated(
            dealCell, prop, id, params.typ, params.target, params.i, params.data
        );
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
            require(!approved, DACErrorsLib.DealAlreadyApproved());
            require(block.timestamp > _approveDeadline, DACErrorsLib.DeadlineNotPassed());
        }
        else {
            require(_fundingTranches[trancheId].amount > 0, DACErrorsLib.TrancheNotExists());
            require(!_fundingTranches[trancheId].settled, DACErrorsLib.TrancheAlreadySettled());
        }
        
        if (_fundingTranches[trancheId].amount > 0) {
            require(
                IERC20(
                    _fundingTranches[trancheId].token
                ).transfer(
                    address(deal), 
                    _fundingTranches[trancheId].amount
                ), 
                DACErrorsLib.TransferFailed()
            );

            investedCapital[_fundingTranches[trancheId].token] += _fundingTranches[trancheId].amount;
        }
        _fundingTranches[trancheId].settled = true;
    }

    function requestTranche(
        uint256 dealId,
        address dacCell,
        DealManagementProposal prop,
        mapping(uint256 => Tranche) storage _fundingTranches,
        address[] storage _fundingTokens,
        mapping(address => uint256) storage _requestedFunding
    ) public {
        address _fundingToken = DealManagementProposal(prop).target();
        
        // Creating tranche state
        if (_requestedFunding[_fundingToken] == 0) {
            _fundingTokens.push(_fundingToken);
        }
        _requestedFunding[_fundingToken] += uint256(DealManagementProposal(prop).i());
        
        _fundingTranches[prop.id()] = Tranche({
            token: _fundingToken,
            amount: uint256(DealManagementProposal(prop).i()),
            settled: false
        });

        IDealManagerAdapter(IDACCellAdapter(dacCell).getDealManager()).createTrancheProposal(dealId, prop.id());
    }

    function claimMainToken(
        address dacCell,
        IDeal deal,
        uint256 evaluatorId,
        mapping(address => uint256) storage claimableRewards
    ) public {
        uint256 amount = claimableRewards[msg.sender];
        require(amount > 0, DACErrorsLib.NoClaimableRewards());
        
        deal.beforeClaimMainToken(msg.sender, amount);

        claimableRewards[msg.sender] = 0;
        IDealManagerAdapter(
            IDACCellAdapter(dacCell).getDealManager()
        ).mintMain(address(this), evaluatorId, msg.sender, amount);
        
        emit DACEventsLib.RewardsClaimed(dacCell, msg.sender, address(deal), amount);

        deal.afterClaimMainToken(msg.sender, amount);
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
        address deal,
        address _token,
        uint256 amount,
        address dacCell,
        mapping(address => uint256) storage returnedCapital
    ) public {
        IERC20(_token).approve(dacCell, amount);

        IDACCellAdapter(dacCell).depositTreasury(_token, amount);
        returnedCapital[_token] += amount;
        
        emit DACEventsLib.CapitalReturned(dacCell, id, address(deal), _token, amount);
    }

    function transferCapitalFromDeal(
        uint256 id,
        address deal,
        address _token,
        uint256 amount,
        address dacCell,
        mapping(address => uint256) storage returnedCapital
    ) public {
        require(
            IERC20(_token).transferFrom(deal, address(this), amount), 
            DACErrorsLib.TransferFailed()
        );

        transferCapital(id, deal, _token, amount, dacCell, returnedCapital);
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
            require(block.timestamp > _dealDeadline, DACErrorsLib.DeadlineNotPassed());
        }
        else {
            require(token.balanceOf(msg.sender) != 0, DACErrorsLib.NotStakedAgent());
            if (!earlyReturns) {
                require(block.timestamp > _dealDeadline, DACErrorsLib.DeadlineNotPassed());
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
                    DACErrorsLib.TransferFailed()
                );
            }

            uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
            if (balance == 0) continue;

            transferCapital(id, address(deal), _fundingToken, balance, dacCell, returnedCapital);
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
    ) public returns (uint256 rewardsConvertedPct, uint256 reward) {
        rewardsConvertedPct = rewardsConverted;
        
        require(rewardsConvertedPct + rewardPercent <= MathLib.SCALE, DACErrorsLib.InsufficientRewards());

        deal.onMarkAsSuccess(rewardPercent);

        reward = MathLib.mul(_tokenRewardsLimit, rewardPercent);

        uint256 transformAmount = reward; // for event

        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderShare = MathLib.mulDiv(token.balanceOf(h), reward, token.totalSupply());  // pro-rata on original stake
            claimableRewards[h] = holderShare;
        }

        rewardsConvertedPct += rewardPercent;

        // if all rewards were paid out, marking the deal as closed so MP tokens can withdraw stakes
        if (rewardsConvertedPct == MathLib.SCALE) {
            IDealCellGovernanceAdapter(self).closeDeal();
        }

        emit DACEventsLib.RewardsAllocated(dacCell, id, address(deal), transformAmount);
    }

    function markAsFailed(
        uint256 slashPercent,
        uint256 id,
        address dacCell,
        StakedAgent token,
        IDeal deal,
        address[] storage holders
    ) public {
        uint256 slashAmount = MathLib.mul(token.totalSupply(), slashPercent);
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderSlash = MathLib.mul(token.balanceOf(h), slashPercent);
            token.burn(h, holderSlash);
        }
        
        emit DACEventsLib.StakesSlashed(dacCell, id, address(deal), slashAmount);

        deal.onMarkAsFailed(slashPercent);
    }
}