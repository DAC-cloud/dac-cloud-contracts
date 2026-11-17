// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
import {VotingConfigLib} from "./VotingConfigLib.sol";
import {IVotes} from "../../lib/IVotes.sol";
import {GovernanceLimits} from "../../interfaces/GovernanceStructs.sol";

interface IDealCellGovernanceAdapter {
    function invite(address invitee, bool grantInviteRight) external;
    function sweepFundingToken(address token) external;
}

library DealCellGovernanceLib {
    using SafeERC20 for IERC20;

    // Capital return handles funding tokens one by one. Each token gets at most this much
    // gas, so a token that reverts or burns gas costs itself its turn and nothing else:
    // the others still return, and the call can be repeated for whatever was skipped.
    // A plain ERC-20 uses about a sixth of the stipend; a token that burns all of it at
    // every step costs about 2.4M gas in total, so six such tokens in one deal still
    // leave a capital return inside a 2^24 gas transaction.
    uint256 internal constant FUNDING_TOKEN_GAS = 1_000_000;
    uint256 internal constant FUNDING_TOKEN_PROBE_GAS = 100_000;

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
        address[] storage holders,
        uint256 agentsLimit,
        uint256 minimalStake,
        bool capped
    ) public {
        require(amount > 0, DACErrorsLib.ZeroStake());
        require(minimalStake == 0 || amount >= minimalStake, DACErrorsLib.InsufficientStake());

        deal.beforeEveryStake(staker, amount);

        _admitHolder(staker, token, holders, agentsLimit, capped);
        
        token.mint(staker, amount);
        
        emit DACEventsLib.AgentTokensStaked(dacCell, id, address(deal), staker, amount);

        deal.afterEveryStake(staker, amount);
    }

    // `holders` is historical (never pruned, used for claimable tracking), so the
    // agents limit is enforced against holders with a live stake, not list length.
    function _admitHolder(
        address staker,
        StakedAgent token,
        address[] storage holders,
        uint256 agentsLimit,
        bool capped
    ) internal {
        bool newHolder = true;
        uint256 activeHolders = 0;
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == staker) {
                newHolder = false;
            }
            if (agentsLimit != 0 && token.balanceOf(holders[i]) > 0) {
                activeHolders++;
            }
        }

        // Anyone without a live stake (brand new, or a historical holder coming back)
        // occupies a fresh seat and must fit under the limit.
        if (agentsLimit != 0 && token.balanceOf(staker) == 0) {
            require(activeHolders < agentsLimit, DACErrorsLib.AgentsLimitReached());
        }

        if (newHolder) {
            // The list is walked by every slash and reward allocation, so its length is
            // bounded by the kernel whatever the deal's own `agentsLimit` says. A
            // governance-appointed liquidator is exempt: nothing iterates a closed deal.
            require(!capped || holders.length < GovernanceLimits.MAX_DEAL_HOLDERS, DACErrorsLib.HoldersLimitReached());
            holders.push(staker);
        }
    }

    function addStake(
        address dacCell,
        address staker,
        uint256 amount,
        uint256 id,
        IDeal deal,
        address agentTokenAddr,
        StakedAgent token,
        address[] storage holders,
        uint256 agentsLimit,
        uint256 minimalStake
    ) public {
        require(amount > 0, DACErrorsLib.ZeroStake());
        require(minimalStake == 0 || amount >= minimalStake, DACErrorsLib.InsufficientStake());

        require(
            AgentToken(agentTokenAddr).transferFrom(
                staker, address(this), amount
            ),
            DACErrorsLib.TransferFailed()
        );

        deal.beforeEveryStake(staker, amount);

        _admitHolder(staker, token, holders, agentsLimit, true);
        
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

                // Same past timepoint the proposal will read its weights and base at.
                require(
                    IVotes(IDealCell(dealCell).stakeToken()).getPastVotes(msg.sender, block.timestamp - 1)
                        > MathLib.mul(
                            IVotes(IDealCell(dealCell).stakeToken()).getPastTotalSupply(block.timestamp - 1),
                            votingConfig.qualification
                        ),
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

        if (params.typ == AbstractDealManagementType.REQUEST_TRANCHE) {
            // A closed deal can never unlock rewards, so a tranche approved after close
            // would leak its reward reservation forever.
            require(!IDealCell(dealCell).isClosed(), DACErrorsLib.DealIsClosed());
        }

        if (params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG) {
            VotingConfigLib.validate(abi.decode(params.data, (VotingConfig)));
        }

        isBase =(
            params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
            params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
            params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
            params.typ == AbstractDealManagementType.ENABLE_VETO_RIGHT ||
            params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
            params.typ == AbstractDealManagementType.ADD_STAKE ||
            params.typ == AbstractDealManagementType.PERMIT_UNSTAKE ||
            params.typ == AbstractDealManagementType.STRIKE_OUT_AGENT ||
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
        address dacCell,
        uint256 dealId,
        uint256 trancheId,
        bool approved,
        uint256 _approveDeadline,
        uint256 _tokenRewardsLimit,
        uint256 _rewardsConverted,
        uint256 rewardsLimit,
        IDeal deal,
        mapping(uint256 => Tranche) storage _fundingTranches,
        mapping(address => uint256) storage investedCapital
    ) public returns (uint256 tokenRewardsLimit, uint256 rewardsConverted) {
        Tranche memory tranche = _fundingTranches[trancheId];

        if (trancheId == 0) {
            require(!approved, DACErrorsLib.DealAlreadyApproved());
            require(block.timestamp <= _approveDeadline, DACErrorsLib.DeadlineNotPassed());
        }
        else {
            require(tranche.amount > 0, DACErrorsLib.TrancheNotExists());
            require(!tranche.settled, DACErrorsLib.TrancheAlreadySettled());
        }

        if (tranche.amount > 0) {
            IERC20(tranche.token).safeTransfer(address(deal), tranche.amount);

            investedCapital[tranche.token] += tranche.amount;

            emit DACEventsLib.TrancheSettled(
                dacCell,
                dealId,
                address(deal),
                trancheId,
                tranche.token,
                tranche.amount
            );
        }

        tranche.settled = true;
        _fundingTranches[trancheId].settled = true;

        if (!approved) {
            // This is the initial deal approval, no need to adjust rewards
            tokenRewardsLimit = _tokenRewardsLimit;
            rewardsConverted = _rewardsConverted;
        }

        else {
            // Rescale the converted percent to the new limit, rounding UP: consumers
            // treat `SCALE - rewardsConverted` as what is still convertible, and
            // mul(limit, SCALE - pct) must never exceed limit - alreadyUnlocked. Rounding
            // down would leave a few wei of over-ask that reverts every later conversion.
            // Dust lost to the rounding stays unconvertible, never over-converted.
            tokenRewardsLimit = _tokenRewardsLimit + rewardsLimit;

            if (tokenRewardsLimit == 0) {
                rewardsConverted = 0;
            } else {
                rewardsConverted = MathLib.capAt100(
                    MathLib.mulDivUp(
                        MathLib.mulDiv(_tokenRewardsLimit, _rewardsConverted, MathLib.SCALE),
                        MathLib.SCALE,
                        tokenRewardsLimit
                    )
                );
            }
        }
    }

    function requestTranche(
        address dacCell,
        uint256 dealId,
        address dealAddr,
        DealManagementProposal prop,
        mapping(uint256 => Tranche) storage _fundingTranches,
        mapping(address => uint256) storage _requestedFunding
    ) public {
        address _fundingToken = DealManagementProposal(prop).target();
        
        // Creating tranche state. The token joins `_fundingTokens` only when the DAC
        // settles the tranche (DealCell.approveFunding), never on request.
        _requestedFunding[_fundingToken] += uint256(DealManagementProposal(prop).i());

        _fundingTranches[prop.id()] = Tranche({
            token: _fundingToken,
            amount: uint256(DealManagementProposal(prop).i()),
            rewards: abi.decode(DealManagementProposal(prop).data(), (uint256)),
            settled: false
        });

        emit DACEventsLib.TrancheRequested(
            dacCell,
            dealId,
            dealAddr,
            prop.id(),
            _fundingTranches[prop.id()].token,
            _fundingTranches[prop.id()].amount
        );

        IDealManagerAdapter(IDACCellAdapter(dacCell).getDealManager()).createTrancheProposal(dealId, prop.id());
    }

    function claimMainToken(
        address dacCell,
        uint256 id,
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
        if (msg.sender == address(deal)) {
            emit DACEventsLib.DealRewardClaimed(dacCell, id, address(deal), amount);
        }

        deal.afterClaimMainToken(msg.sender, amount);
    }

    // Runs in the Deal's context: lets the cell pull whatever funding tokens the deal
    // holds. Best effort per token; one that cannot be read or approved is left out.
    function prepareWithdrawal(
        address dealCell
    ) public {
        address[] memory _fundingTokens = IDealCell(dealCell).fundingTokens();

        for (uint256 i = 0; i < _fundingTokens.length; i++) {
            address _fundingToken = _fundingTokens[i];

            // Up to four capped calls per token; their stipends are guaranteed.
            require(gasleft() > 4 * FUNDING_TOKEN_PROBE_GAS * 64 / 63 + 20_000, DACErrorsLib.InsufficientGas());

            (bool ok, bytes memory ret) = _fundingToken.staticcall{gas: FUNDING_TOKEN_PROBE_GAS}(
                abi.encodeCall(IERC20.balanceOf, (address(this)))
            );
            if (!ok || ret.length < 32) continue;

            uint256 balance = uint256(bytes32(ret));
            if (balance == 0) continue;

            if (!_tryApprove(_fundingToken, dealCell, balance)) {
                // Tokens that only accept a new allowance from zero.
                if (_tryApprove(_fundingToken, dealCell, 0)) _tryApprove(_fundingToken, dealCell, balance);
            }
        }
    }

    function _tryApprove(address token, address spender, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call{gas: FUNDING_TOKEN_PROBE_GAS}(
            abi.encodeCall(IERC20.approve, (spender, amount))
        );
        return ok && (ret.length == 0 || (ret.length >= 32 && uint256(bytes32(ret)) == 1));
    }

    function transferCapital(
        uint256 id,
        address deal,
        address _token,
        uint256 amount,
        address dacCell,
        mapping(address => uint256) storage returnedCapital
    ) public {
        IERC20(_token).forceApprove(IDACCellAdapter(dacCell).getAssetController(), amount);

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
        IERC20(_token).safeTransferFrom(deal, address(this), amount);

        transferCapital(id, deal, _token, amount, dacCell, returnedCapital);
    }

    function withdrawCapital(
        uint256 id,
        bool earlyReturns,
        address dacCell,
        uint256 _dealDeadline,
        StakedAgent token,
        IDeal deal,
        IDealCell self,
        address[] storage _fundingTokens
    ) public {
        if (msg.sender == IDACCellAdapter(dacCell).getDealManager()) {
            if (block.timestamp < _dealDeadline) {
                require(
                    self.isApproved() && self.isClosed() && token.totalSupply() == 0, 
                    DACErrorsLib.DeadlineNotPassed()
                );
            }
        }
        else {
            require(token.balanceOf(msg.sender) != 0, DACErrorsLib.NotStakedAgent());
            if (!earlyReturns) {
                require(block.timestamp > _dealDeadline, DACErrorsLib.DeadlineNotPassed());
            }
        }
        
        deal.beforeWithdrawCapital();

        // Return every funding token, each in its own isolated call. A token that cannot
        // move right now (frozen, paused, hostile) is reported and skipped; the rest still
        // go home, and the whole call can be repeated later.
        for (uint256 i = 0; i < _fundingTokens.length; i++) {
            address _fundingToken = _fundingTokens[i];

            // The stipend is guaranteed, so only the token itself can make its turn fail.
            require(gasleft() > FUNDING_TOKEN_GAS * 64 / 63 + 20_000, DACErrorsLib.InsufficientGas());
            try IDealCellGovernanceAdapter(address(this)).sweepFundingToken{gas: FUNDING_TOKEN_GAS}(_fundingToken) {}
            catch {
                emit DACEventsLib.CapitalReturnFailed(dacCell, id, address(deal), _fundingToken);
            }
        }

        deal.afterWithdrawCapital();
    }

    // One funding token: pull what the deal approved, then send the cell's whole balance
    // of it to the DAC treasury. Reverts on any failure; the caller isolates it.
    function sweepFundingToken(
        uint256 id,
        address deal,
        address _fundingToken,
        address dacCell,
        mapping(address => uint256) storage returnedCapital
    ) public {
        uint256 dealAllowance = IERC20(_fundingToken).allowance(deal, address(this));
        if (dealAllowance > 0) {
            IERC20(_fundingToken).safeTransferFrom(deal, address(this), dealAllowance);
        }

        uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
        if (balance == 0) return;

        transferCapital(id, deal, _fundingToken, balance, dacCell, returnedCapital);
    }

    function markAsSuccess(
        uint256 rewardPercent,
        uint256 id,
        address dacCell,
        StakedAgent token,
        IDeal deal,
        uint256 rewardsConverted,
        uint256 _tokenRewardsLimit,
        uint256 dealRewardPoolPercent,
        address[] storage holders,
        mapping(address => uint256) storage claimableRewards
    ) public returns (uint256 rewardsConvertedPct, uint256 rewardAmount) {
        rewardsConvertedPct = rewardsConverted;
        
        require(rewardsConvertedPct + rewardPercent <= MathLib.SCALE, DACErrorsLib.InsufficientRewards());

        deal.onMarkAsSuccess(rewardPercent);

        uint256 rewardBase = MathLib.mul(_tokenRewardsLimit, rewardPercent);
        uint256 dealRewardAmount = MathLib.mul(rewardBase, dealRewardPoolPercent);
        uint256 stakerRewardBase = rewardBase - dealRewardAmount;

        if (dealRewardAmount > 0) {
            claimableRewards[address(deal)] += dealRewardAmount;
            rewardAmount += dealRewardAmount;

            emit DACEventsLib.DealRewardPoolAllocated(dacCell, id, address(deal), dealRewardAmount);
            deal.onDealRewardAllocated(dealRewardAmount);
        }

        rewardAmount += _allocateStakerRewards(token, holders, claimableRewards, stakerRewardBase);

        rewardsConvertedPct += rewardPercent;

        emit DACEventsLib.RewardsAllocated(dacCell, id, address(deal), rewardAmount);
    }

    function markAsFailed(
        uint256 slashPercent,
        uint256 id,
        address dacCell,
        StakedAgent token,
        IDeal deal,
        address[] storage holders
    ) public returns (uint256 slashAmount) {
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderSlash = MathLib.mul(token.balanceOf(h), slashPercent);
            if (holderSlash == 0) continue;
            token.burn(h, holderSlash);

            slashAmount += holderSlash;
        }
        
        emit DACEventsLib.StakesSlashed(dacCell, id, address(deal), slashAmount);

        deal.onMarkAsFailed(slashPercent);
    }

    function _allocateStakerRewards(
        StakedAgent token,
        address[] storage holders,
        mapping(address => uint256) storage claimableRewards,
        uint256 stakerRewardBase
    ) internal returns (uint256 rewardAmount) {
        uint256 totalStake = token.totalSupply();

        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderShare = MathLib.mulDiv(token.balanceOf(h), stakerRewardBase, totalStake); // pro-rata on the stake held at this evaluation
            if (holderShare == 0) continue;
            claimableRewards[h] += holderShare;
            rewardAmount += holderShare;
        }
    }
}
