// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig, DealParams, CapitalCall, EvaluationResult} from "../../interfaces/Structs.sol";
import {IDealAdmin} from "../../interfaces/IDealAdmin.sol";
import {IEvaluator} from "../../interfaces/IEvaluator.sol";
import {IDACManagementFactory} from "../../interfaces/IDACManagementFactory.sol";
import {IModuleFactory} from "../../interfaces/IModuleFactory.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {DealState, CapitalCallState} from "../interfaces/Structs.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {MainToken} from "../tokens/MainToken.sol";
import {AgentToken} from "../tokens/AgentToken.sol";
import {DACManagementProposal} from "../governance/DACManagementProposal.sol";
import {DACManagementProposalType} from "../governance/DACManagementProposals.sol";

interface IDACGovernanceAdapter {
    function createManagementProposal(ProposalParams calldata params)
        external
        returns (uint256 id);
}

library DACCellGovernance {
    
    // Errors

    error NotFound();
    error NotAuthorized();

    error InsufficientBalance();

    error InvalidDeal(address deal);
    error InvalidDealId(uint256 deal);
    
    error InvalidTranche();
    error InsufficientTreasury();
    error InsufficientRewards();

    error MintBlockedByEvaluator();

    error InvalidVotingConfig();

    error InvalidCapitalCall();
    error AlreadyFulfilled();

    error DividendsNotEnabled();
    error DividendAlreadyClaimed(uint256 id, address claimer);
    error InvalidMerkleProof();
    error TransferFailed();

    error DealNotRecoverable();

    error ModuleNotApproved();
    error ModuleDisabled();

    // Events

    event CapitalCallCreated(uint256 indexed id, address indexed recipient, bytes32 callHash, uint256 amount);
    event CapitalCallFulfilled(address indexed recipient, bytes32 callHash, uint256 amount);
    
    event DACProposalCreated(uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);

    event DividendClaimed(uint256 payoutId, address indexed token, uint256 amountPayout);
    
    event DealCreated(uint256 indexed id, uint256 indexed proposalId, address indexed creator, bytes4 kind, address cell, address deal);
    event TrancheCreated(uint256 indexed id, uint256 indexed proposalId, uint256 trancheId);
    event FundingApproved(uint256 indexed id, uint256 indexed trancheId, uint256 rewardsLimit);
    
    event DealEvaluated(uint256 indexed id, EvaluationResult[] evaluations);

    // Methods implementation

    function fulfillCapitalCall(
        CapitalCall calldata call,
        MainToken mainToken,
        mapping(bytes32 => CapitalCallState) storage capitalCalls,
        mapping(address => uint256) storage treasuryBalances
    ) public returns (bool) {
        bytes32 callHash = keccak256(abi.encode(call));
        require(!capitalCalls[callHash].fulfilled, AlreadyFulfilled());
        
        CapitalCall memory capitalCall = capitalCalls[callHash].call;
        require(capitalCall.tokenAmount > 0, InvalidCapitalCall());

        require(
            IERC20(call.treasuryToken).transferFrom(msg.sender, address(this), call.cashAmount), 
            TransferFailed()
        );

        treasuryBalances[call.treasuryToken] += call.cashAmount;

        mainToken.mint(call.tokenRecipient, call.tokenAmount);

        capitalCalls[callHash].fulfilled = true;

        emit CapitalCallFulfilled(call.tokenRecipient, callHash, call.tokenAmount);
        
        return true;
    }

    function createDealProposal(
        address dacCell,
        uint256 nextId,
        DealParams calldata params,
        MainToken mainToken,
        AgentToken agentToken,
        VotingConfig memory votingConfig,
        mapping(address => bool) storage moduleFactories,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealRegistry
    ) internal returns (uint256 id, address dealCell, address dealAddr, address evaluatorAddr) {
        require(moduleFactories[params.moduleFactory], ModuleNotApproved());

        require(params.proposer == msg.sender, NotAuthorized());

        require(IModuleFactory(params.moduleFactory).isActive(), ModuleDisabled());

        id = nextId + 1; // proposal id = nextId, deal id = proposal id + 1

        (dealCell, dealAddr, evaluatorAddr) = IModuleFactory(params.moduleFactory).deployDeal(
            id,
            params,
            address(this),
            address(agentToken),
            address(mainToken),
            votingConfig
        );

        deals[id] = dealCell;
        dealRegistry[dealCell] = DealState({
            id: id,
            deal: dealAddr,
            module: IModuleFactory(params.moduleFactory),
            evaluator: evaluatorAddr,
            rewardsLimit: 0
        });
        
        ProposalParams memory dealProposal = ProposalParams({
            typ: DACManagementProposalType.APPROVE_DEAL,
            target: params.fundingToken,
            i: bytes32(params.fundingAmount),
            data: abi.encode(id, 0, params.rewardsLimit) // tranche id 0, rewards limit from config
        });

        emit DealCreated(
            id, 
            IDACGovernanceAdapter(dacCell).createManagementProposal(dealProposal), 
            msg.sender, 
            params.dealKind, 
            dealCell,
            dealAddr
        );
    }

    function createTrancheProposal(
        address dacCell,
        uint256 dealId,
        uint256 trancheId,
        mapping(uint256 => address) storage deals
    ) internal {
        address dealCell = deals[dealId];
        require(msg.sender == dealCell, InvalidDealId(dealId));

        address fundingToken = IDealCell(dealCell).fundingToken(trancheId);
        uint256 fundingAmount = IDealCell(dealCell).fundingAmount(trancheId);
        require(fundingAmount > 0, InvalidTranche());

        ProposalParams memory trancheProposal = ProposalParams({
            typ: DACManagementProposalType.APPROVE_TRANCHE,
            target: fundingToken,
            i: bytes32(fundingAmount),
            data: abi.encode(dealId, trancheId, uint256(0))
        });

        uint256 votingId = IDACGovernanceAdapter(dacCell).createManagementProposal(trancheProposal);

        emit TrancheCreated(dealId, trancheId, votingId);
    }

    function executeTrancheApprove(
        uint256 dealId,
        uint256 trancheId,
        uint256 rewardsLimit,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealState
    ) public {
        address dealCell = deals[dealId];

        uint256 amount = IDealCell(dealCell).fundingAmount(trancheId);
        address token = IDealCell(dealCell).fundingToken(trancheId);

        if (amount > 0) {
            require(IERC20(token).transfer(dealCell, amount), TransferFailed());
        }
        
        if (trancheId == 0) {
            dealState[dealCell].rewardsLimit = rewardsLimit;
        }

        IDealAdmin(dealCell).approveFunding(trancheId);
        
        emit FundingApproved(dealId, trancheId, rewardsLimit);
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
        require(dealCell != address(0), InvalidDealId(dealId));

        uint256 amount = IDealCell(dealCell).fundingAmount(trancheId);
        address token = IDealCell(dealCell).fundingToken(trancheId);

        require(treasuryBalances[token] >= amount, InsufficientTreasury());

        if (amount > 0) {
            require(IERC20(token).transfer(address(dealManager), amount), TransferFailed());
            treasuryBalances[token] -= amount;
        }
        else {
            require(trancheId == 0, InvalidTranche());
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

        require(proposal != address(0), NotFound());

        IVoting(proposal).castVeto();
    }

    function createManagementProposal(
        uint256 nextId,
        ProposalParams calldata params,
        VotingConfig storage votingConfig,
        address proposalFactory,
        MainToken mainToken,
        bool dividendsEnabled,
        uint256 unreleasedMainTokens,
        IDealManager dealManager,
        mapping(uint256 => address) storage proposals
    ) public returns (uint256 id) {
        if (msg.sender == address(this)) {
            require(
                (
                    params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE
                ),
                NotAuthorized()
            );
        }
        else {
            require(
                !(
                    params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE
                ),
                NotAuthorized()
            );

            require(
                mainToken.balanceOf(msg.sender) > votingConfig.qualification,
                InsufficientBalance()
            );

            if (params.typ == DACManagementProposalType.RECOVER_DEAL) {
                (uint256 dealId) = abi.decode(params.data, (uint256));

                require(dealManager.isRecoverable(dealId), DealNotRecoverable());
            }

            if (params.typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
                require(dividendsEnabled, DividendsNotEnabled());
            }

            if (params.typ == DACManagementProposalType.UPDATE_VOTING_CONFIG) {
                VotingConfig memory _votingConfig = abi.decode(params.data, (VotingConfig));
                
                require(_votingConfig.quorumPercent > 0, InvalidVotingConfig());
                require(_votingConfig.highQuorumPercent > 0, InvalidVotingConfig());
                require(_votingConfig.blockingPercent >= 0, InvalidVotingConfig());
                require(_votingConfig.duration > 0, InvalidVotingConfig());
            }
        }

        id = nextId;

        address prop = IDACManagementFactory(proposalFactory).deployProposal(
            id,
            params,
            address(this),
            address(mainToken),
            unreleasedMainTokens,
            votingConfig
        );

        proposals[id] = prop;

        emit DACProposalCreated(id, params.typ, params.target, params.i, params.data);

        return id;
    }

    function mintMain(
        address dealCell, 
        address to, 
        uint256 amount,
        MainToken mainToken,
        mapping(address => DealState) storage dealState
    ) public {
        require(msg.sender == dealCell, InvalidDeal(msg.sender));
        require(dealState[dealCell].rewardsLimit > amount, InsufficientRewards());

        require(
            IEvaluator(dealState[dealCell].evaluator).permitMint(dealCell, to, amount),
            MintBlockedByEvaluator()
        );

        // Here we enforce a cap on mint per deal, so rewards are capped by what was agreed 
        // by LP holders, even when both the deal and evaluator are compromised

        dealState[dealCell].rewardsLimit -= amount;

        mainToken.mint(to, amount);
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

        CapitalCall memory call = CapitalCall({
            treasuryToken: treasuryToken,
            nonce: id,
            tokenRecipient: prop.target(),
            tokenAmount: uint256(prop.i()),
            cashAmount: cashAmount
        });

        bytes32 hash = keccak256(abi.encode(call));
        capitalCalls[hash] = CapitalCallState({
            call: call,
            fulfilled: false
        });

        emit CapitalCallCreated(id, prop.target(), hash, uint256(prop.i()));
    }

    function _performTransformation(
        uint256 id, 
        uint256 transformationPercent,
        mapping(uint256 => address) storage deals
    ) internal {
        address dealCell = deals[id];
        IDealAdmin(dealCell).markAsSuccess(transformationPercent);
    }

    function _performSlash(
        uint256 id, 
        uint256 slashPercent,
        AgentToken agentToken,
        mapping(uint256 => address) storage deals
    ) internal {
        address dealCell = deals[id];
        uint256 totalTokens = IDealCell(dealCell).getStakedAgentTotal();
        AgentToken(agentToken).burnFrom(dealCell, totalTokens);
        IDealAdmin(dealCell).markAsFailed(slashPercent);
    }

    function evaluateDeal(
        uint256 id,
        AgentToken agentToken,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealState
    ) public {
        address dealCell = deals[id];
        require(dealCell != address(0), InvalidDeal(dealCell));

        address evaluatorAddr = dealState[dealCell].evaluator;
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
                _performTransformation(id, evaluations[i].percent, deals);
            } else if (evaluations[i].action == 2) {    // extend
                IDealAdmin(dealCell).extendDeadline(evaluations[i].newDeadline);
            } else if (evaluations[i].action == 3) {    // close
                IDealAdmin(dealCell).closeDeal();
            }
        }
        
        emit DealEvaluated(id, evaluations);
    }

    function claimDividend(
        uint256 proposalId,
        uint256 index,
        address receiver,
        uint256 amount,
        bytes32[] calldata proof,
        mapping(uint256 => address) storage proposals,
        mapping(uint256 => bytes32) storage dividendMerkleRoots,
        mapping(bytes32 => bool) storage dividendClaimed
    ) public {
        bytes32 root = dividendMerkleRoots[proposalId];
        require(root != bytes32(0), NotFound());

        bytes32 leaf = keccak256(abi.encodePacked(index, receiver, amount));

        bytes32 claimedKey = keccak256(abi.encodePacked(root, leaf));
        require(!dividendClaimed[claimedKey], DividendAlreadyClaimed(proposalId, receiver));

        require(MerkleProof.verify(proof, root, leaf), InvalidMerkleProof());

        dividendClaimed[claimedKey] = true;

        (address token) = abi.decode(
            DACManagementProposal(proposals[proposalId]).data(), 
            (address)
        );
        
        require(IERC20(token).transfer(receiver, amount), TransferFailed());

        emit DividendClaimed(proposalId, receiver, amount);
    }
}
