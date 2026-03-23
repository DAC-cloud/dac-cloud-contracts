// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig, DealParams, EvaluationResult, Tranche} from "../../interfaces/Structs.sol";
import {IDealCellAdapter} from "../interfaces/IDealCellAdapter.sol";
import {IEvaluator} from "../../interfaces/IEvaluator.sol";
import {IDACManagementFactory} from "../interfaces/IDACManagementFactory.sol";
import {IModuleFactory} from "../../interfaces/IModuleFactory.sol";
import {IModuleRegistry} from "../../interfaces/IModuleRegistry.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {DealState} from "../interfaces/Structs.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {MainToken} from "../tokens/MainToken.sol";
import {AgentToken} from "../tokens/AgentToken.sol";
import {DACManagementProposal} from "../governance/DACManagementProposal.sol";
import {DACManagementProposalType} from "../governance/DACManagementProposals.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";
import {MathLib} from "./MathLib.sol";

interface IDACGovernanceAdapter {
    function createManagementProposal(ProposalParams calldata params)
        external
        returns (uint256 id);
}

library DACCellGovernanceLib {

    function createDealProposal(
        address dacCell,
        uint256 nextId,
        DealParams memory params,
        VotingConfig memory votingConfig,
        IModuleRegistry moduleRegistry,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealRegistry
    ) public returns (uint256 id, address dealCell, address dealAddr, address evaluatorAddr) {
        require(moduleRegistry.isModuleApproved(params.moduleFactory), DACErrorsLib.ModuleNotApproved());

        require(params.proposer == msg.sender, DACErrorsLib.NotAuthorized());

        require(IModuleFactory(params.moduleFactory).isActive(), DACErrorsLib.ModuleDisabled());

        id = nextId;

        (dealCell, dealAddr, evaluatorAddr) = IModuleFactory(params.moduleFactory).deployDeal(
            id,
            params,
            dacCell,
            address(this),
            votingConfig
        );

        deals[id] = dealCell;

        address[] memory evaluators = new address[](1);
        evaluators[0] = evaluatorAddr;

        dealRegistry[dealCell] = DealState({
            id: id,
            deal: dealAddr,
            module: IModuleFactory(params.moduleFactory),
            active: false,
            liquidated: false,
            evaluators: evaluators,
            rewardsLimit: 0, // rewards will be added to state once approved by DAC cell
            rewardsUnlocked: 0,
            rewardsPaid: 0,
            initParams: abi.encode(params)
        });
        
        ProposalParams memory dealProposal = ProposalParams({
            typ: DACManagementProposalType.APPROVE_DEAL,
            target: params.fundingToken,
            i: bytes32(params.fundingAmount),
            data: abi.encode(id, 0, params.rewardsLimit) // tranche id 0, rewards limit from config
        });

        emit DACEventsLib.DealCreated(
            dacCell,
            id,
            IDACGovernanceAdapter(dacCell).createManagementProposal(dealProposal), 
            params.proposer, 
            params.dealKind, 
            dealCell,
            dealAddr
        );

        emit DACEventsLib.EvaluatorAdded(
            dacCell,
            id,
            params.evaluatorSelector,
            evaluatorAddr
        );
    }

    function createTrancheProposal(
        address dacCell,
        uint256 dealId,
        uint256 trancheId,
        mapping(uint256 => address) storage deals
    ) public {
        address dealCell = deals[dealId];
        require(msg.sender == dealCell, DACErrorsLib.InvalidDealId(dealId));

        Tranche memory fundingTranche = IDealCell(dealCell).fundingTranche(trancheId);

        require(!fundingTranche.settled, DACErrorsLib.InvalidTranche());
        require(fundingTranche.amount > 0, DACErrorsLib.InvalidTranche());

        ProposalParams memory trancheProposal = ProposalParams({
            typ: DACManagementProposalType.APPROVE_TRANCHE,
            target: fundingTranche.token,
            i: bytes32(fundingTranche.amount),
            data: abi.encode(dealId, trancheId, fundingTranche.rewards)
        });

        uint256 votingId = IDACGovernanceAdapter(dacCell).createManagementProposal(trancheProposal);

        emit DACEventsLib.TrancheCreated(dacCell, dealId, votingId, trancheId);
    }

    function executeTrancheApprove(
        address dacCell,
        uint256 dealId,
        uint256 trancheId,
        uint256 rewardsLimit,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealState
    ) public {
        address dealCell = deals[dealId];

        Tranche memory fundingTranche = IDealCell(dealCell).fundingTranche(trancheId);

        if (fundingTranche.amount > 0) {
            require(IERC20(fundingTranche.token).transfer(dealCell, fundingTranche.amount), DACErrorsLib.TransferFailed());
        }
        
        if (trancheId == 0) {
            dealState[dealCell].active = true;
        }

        dealState[dealCell].rewardsLimit += rewardsLimit;

        emit DACEventsLib.FundingApproved(dacCell, dealId, trancheId, rewardsLimit);

        IDealCellAdapter(dealCell).approveFunding(trancheId, rewardsLimit);
    }

    function approveFunding(
        DACManagementProposal prop,
        mapping(address => uint256) storage treasuryBalances,
        IDealManager dealManager
    ) public {
        (uint256 dealId, uint256 trancheId, uint256 rewardsLimit) = abi.decode(
            prop.data(),
            (uint256, uint256, uint256)
        );

        address dealCell = dealManager.deals(dealId);
        require(dealCell != address(0), DACErrorsLib.InvalidDealId(dealId));

        require(
            IERC20(IDealCell(dealCell).stakeToken()).totalSupply() > 0, 
            DACErrorsLib.NoStake()
        );

        Tranche memory fundingTranche = IDealCell(dealCell).fundingTranche(trancheId);

        require(treasuryBalances[fundingTranche.token] >= fundingTranche.amount, DACErrorsLib.InsufficientTreasury());

        if (fundingTranche.amount > 0) {
            require(
                IERC20(fundingTranche.token).transfer(address(dealManager), fundingTranche.amount), 
                DACErrorsLib.TransferFailed()
            );
            treasuryBalances[fundingTranche.token] -= fundingTranche.amount;
        }
        else {
            require(trancheId == 0, DACErrorsLib.InvalidTranche());
        }

        IDealManagerAdapter(address(dealManager)).approveFunding(
            dealId, trancheId, rewardsLimit
        );
    }

    function castVeto(
        DACManagementProposal prop,
        IDealManager dealManager
    ) public {
        (uint256 dealId, uint256 proposalId) = abi.decode(
            DACManagementProposal(prop).data(), 
            (uint256, uint256)
        );
        
        address proposal = IDealCell(dealManager.deals(dealId)).deal().getProposal(proposalId);

        require(proposal != address(0), DACErrorsLib.NotFound());

        IVoting(proposal).castVeto();
    }

    function createManagementProposal(
        uint256 nextId,
        ProposalParams memory params,
        VotingConfig storage votingConfig,
        address proposalFactory,
        MainToken mainToken,
        bool dividendsEnabled,
        uint256 totalVotingSupply,
        IDealManager dealManager,
        mapping(uint256 => address) storage proposals
    ) public returns (uint256 id) {
        if (msg.sender == address(dealManager)) {
            require(
                (
                    params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE
                ),
                DACErrorsLib.NotAuthorized()
            );
        }
        else {
            require(
                !(
                    params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE
                ),
                DACErrorsLib.NotAuthorized()
            );

            require(
                mainToken.balanceOf(msg.sender) > votingConfig.qualification,
                DACErrorsLib.InsufficientBalance()
            );

            if (params.typ == DACManagementProposalType.ADD_EVALUATOR) {
                (uint256 dealId,) = abi.decode(params.data, (uint256, bytes));

                address dealCell = dealManager.deals(dealId);
                require(dealCell != address(0), DACErrorsLib.NotFound());

                DealState memory state = IDealManagerAdapter(address(dealManager)).state(dealCell);
                require(state.active, DACErrorsLib.InvalidDealState(state.deal));
            }

            if (params.typ == DACManagementProposalType.RECOVER_DEAL) {
                (uint256 dealId) = abi.decode(params.data, (uint256));

                require(dealManager.isRecoverable(dealId), DACErrorsLib.DealNotRecoverable());
            }

            if (params.typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
                require(dividendsEnabled, DACErrorsLib.DividendsNotEnabled());
            }

            if (params.typ == DACManagementProposalType.UPDATE_VOTING_CONFIG) {
                VotingConfig memory _votingConfig = abi.decode(params.data, (VotingConfig));
                
                require(_votingConfig.quorumPercent > 0, DACErrorsLib.InvalidVotingConfig());
                require(_votingConfig.highQuorumPercent > 0, DACErrorsLib.InvalidVotingConfig());
                require(_votingConfig.blockingPercent >= 0, DACErrorsLib.InvalidVotingConfig());
                require(_votingConfig.duration > 0, DACErrorsLib.InvalidVotingConfig());
                require(_votingConfig.quorumPercent <= MathLib.SCALE, DACErrorsLib.InvalidVotingConfig());
                require(_votingConfig.blockingPercent <= MathLib.SCALE, DACErrorsLib.InvalidVotingConfig());
                require(_votingConfig.highQuorumPercent <= MathLib.SCALE, DACErrorsLib.InvalidVotingConfig());
                require(
                    _votingConfig.qualification < IDealManager(address(dealManager)).totalReleasedVotable() / 2, 
                    DACErrorsLib.InvalidVotingConfig()
                );
            }
        }

        id = nextId;

        address prop = IDACManagementFactory(proposalFactory).deployProposal(
            id,
            params,
            address(this),
            address(mainToken),
            totalVotingSupply,
            votingConfig
        );

        proposals[id] = prop;

        emit DACEventsLib.DACProposalCreated(id, prop, params.typ, params.target, params.i, params.data);

        return id;
    }

    function mintMain(
        address dealCell,
        uint256 evaluatorId,
        address to, 
        uint256 amount,
        MainToken mainToken,
        mapping(address => DealState) storage dealState
    ) public {
        require(msg.sender == dealCell, DACErrorsLib.InvalidDeal(msg.sender));
        require(dealState[dealCell].rewardsUnlocked >= amount, DACErrorsLib.InsufficientRewards());

        address evaluatorAddr = dealState[dealCell].evaluators[evaluatorId];

        require(evaluatorAddr != address(0), DACErrorsLib.NotFound());

        require(
            IEvaluator(evaluatorAddr).permitMint(dealCell, to, amount),
            DACErrorsLib.MintBlockedByEvaluator()
        );

        // Here we enforce a cap on mint per deal, so rewards are capped by what was agreed 
        // by LP holders, even when both the deal and evaluator are compromised

        require(
            dealState[dealCell].rewardsPaid + amount <= dealState[dealCell].rewardsUnlocked,
            DACErrorsLib.InsufficientRewards()
        );

        dealState[dealCell].rewardsPaid += amount;

        mainToken.mint(to, amount);
    }

    function _performTransformation(
        uint256 id, 
        uint256 transformationPercent,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealState
    ) internal {
        address dealCell = deals[id];
        
        uint256 unlockedAmount = IDealCellAdapter(dealCell).markAsSuccess(transformationPercent);

        require(
            dealState[dealCell].rewardsUnlocked + unlockedAmount <= dealState[dealCell].rewardsLimit,
            DACErrorsLib.InsufficientRewards()
        );

        dealState[dealCell].rewardsUnlocked += unlockedAmount;

        if (IDealCell(dealCell).rewardsConvertedPct() == MathLib.SCALE) {
            IDealCellAdapter(dealCell).closeDeal();
        }
    }

    function _performSlash(
        uint256 id, 
        uint256 slashPercent,
        AgentToken agentToken,
        mapping(uint256 => address) storage deals
    ) internal {
        address dealCell = deals[id];
        
        uint256 slashedTokens = IDealCellAdapter(dealCell).markAsFailed(slashPercent);

        AgentToken(agentToken).burnFrom(dealCell, slashedTokens);

        if (IERC20(IDealCell(dealCell).stakeToken()).totalSupply() == 0) {
            IDealCellAdapter(dealCell).closeDeal();
        }
    }

    function evaluateDeal(
        address dacCell,
        uint256 id,
        uint256 evaluatorId,
        AgentToken agentToken,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealState
    ) public {
        address dealCell = deals[id];
        require(dealCell != address(0), DACErrorsLib.InvalidDeal(dealCell));

        require(dealState[dealCell].active, DACErrorsLib.DealIsNotApproved());

        if (agentToken.balanceOf(msg.sender) == 0) {
            require(
                IDealCell(dealCell).dealDeadline() < block.timestamp, 
                DACErrorsLib.NotAllowed()
            );
        }

        address evaluatorAddr = dealState[dealCell].evaluators[evaluatorId];

        require(evaluatorAddr != address(0), DACErrorsLib.NotFound());

        EvaluationResult[] memory evaluations = IEvaluator(evaluatorAddr).evaluateDeal(
            id, 
            dealCell,
            dealState[dealCell].deal, 
            address(this)
        );

        for (uint256 i = 0; i < evaluations.length; i++) {
            if (evaluations[i].action == 0) {           // slash
                _performSlash(id, evaluations[i].percent, agentToken, deals);
            } else if (evaluations[i].action == 1) {    // convert
                _performTransformation(id, evaluations[i].percent, deals, dealState);
            } else if (evaluations[i].action == 2) {    // extend
                IDealCellAdapter(dealCell).extendDeadline(evaluations[i].extendTo);
            } else if (evaluations[i].action == 3) {    // close
                IDealCellAdapter(dealCell).closeDeal();
            }
        }
        
        emit DACEventsLib.DealEvaluated(dacCell, id, evaluatorAddr, evaluations);
    }

    function permitEvaluatorAdd(
        uint256 dealId, 
        bytes memory evaluatorHandle,
        address dacCell,
        address dealCell,
        mapping(bytes32 => bool) storage evaluatorWhitelist,
        mapping(address => DealState) storage dealState
    ) public {
        require(msg.sender == dealCell, DACErrorsLib.NotAuthorized());

        (uint256 nonce, bytes memory evaluatorConfig) = abi.decode(evaluatorHandle, (uint256, bytes));

        require(
            evaluatorWhitelist[keccak256(
                abi.encode(
                    dealCell,
                    keccak256(evaluatorConfig),
                    nonce
                )
            )], 
            DACErrorsLib.NotAllowed()
        );

        (bytes4 evaluatorSelector, bytes memory evaluatorParams) = abi.decode(
            evaluatorConfig,
            (bytes4, bytes)
        );

        DealState memory state = dealState[dealCell];

        address evaluator = IModuleFactory(state.module).deployEvaluator(
            dacCell,
            dealId,
            dealCell,
            abi.decode(state.initParams, (DealParams)),
            evaluatorSelector,
            evaluatorParams
        );

        dealState[dealCell].evaluators.push(evaluator);

        emit DACEventsLib.EvaluatorAdded(
            dacCell,
            dealId,
            evaluatorSelector,
            evaluator
        );
    }

}
