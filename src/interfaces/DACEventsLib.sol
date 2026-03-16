// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EvaluationResult, DealParams, VotingConfig, LegalWrapper} from "./Structs.sol";

library DACEventsLib {

    // DAC Factory Events

    event DACDeployed(address indexed dac, address mainToken, address agentToken, bool init);

    // DAC Cell Events

    event DACCreated(address indexed creator, string name, string description);
    event DACStarted(address indexed manager, VotingConfig config, bool dividendsEnabled, address coreModule);
    
    event VotingConfigUpdate(uint256 indexed id, VotingConfig config);
    event LegalWrapperMessage(address indexed wrapper, bytes4 messageKind, bytes message);
    event DividendsConfigUpdate(uint256 indexed id, bool enabled);

    event DACProposalCreated(
        uint256 indexed id,
        address indexed prop, 
        bytes4 indexed typ,
        address target, 
        bytes32 data1, 
        bytes data2
    );
    
    event DACProposalExecuted(address indexed prop, uint256 indexed id, bytes4 indexed typ);

    event TokenMinted(uint256 indexed id, uint256 amount);
    event TokenBurnt(uint256 indexed id, uint256 amount);

    event AgentTokenMinted(uint256 indexed id, address indexed agent, uint256 amount);
    event AgentTokenRevoked(uint256 indexed id, address indexed agent, uint256 amount);
    
    event LegalWrapperSet(uint256 indexed id, LegalWrapper legalWrapper);
    event OffchainActionApproved(uint256 indexed id, bytes4 action, bytes data);
    event DividendPayout(uint256 payoutId, address indexed token, uint256 totalPayout, bytes32 merkleRoot);
    event DividendClaimed(uint256 indexed payoutId, address indexed token, address indexed receiver, uint256 amountPayout);
    
    event CapitalCallCreated(
        uint256 indexed id,
        address indexed recipient,
        bytes32 indexed callHash,
        address treasuryToken,
        uint256 tokenAmount,
        uint256 cashAmount,
        uint256 nonce
    );
    event CapitalCallFulfilled(
        address indexed payer,
        address indexed recipient,
        bytes32 indexed callHash,
        address treasuryToken,
        uint256 tokenAmount,
        uint256 cashAmount,
        uint256 nonce
    );
    
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed from);
    event TreasurySyncMissing(address indexed token, uint256 amount);
    
    // Events emited by DealManager contract

    event DealCreated(
        address indexed dac, 
        uint256 indexed id, 
        uint256 indexed proposalId,
        address creator, 
        bytes4 kind, 
        address cell, 
        address deal
    );

    event TrancheCreated(
        address indexed dac, 
        uint256 indexed id, 
        uint256 indexed proposalId, 
        uint256 trancheId
    );

    event FundingApproved(
        address indexed dac, 
        uint256 indexed id, 
        uint256 indexed trancheId, 
        uint256 rewardsLimit
    );
    
    event EvaluatorAdded(
        address indexed dac,
        uint256 indexed id,
        bytes4 evaluator,
        address evaluatorAddr
    );

    event DealEvaluated(
        address indexed dac, 
        uint256 indexed id,
        address evaluator,
        EvaluationResult[] evaluations
    );

    event ModuleAdded(address indexed dacCell, address indexed factory);
    event ModuleRemoved(address indexed dacCell, address indexed factory);

    // Proposal events

    event ProposalCreated(
        address indexed token, 
        uint256 totalPower, 
        uint256 quorum, 
        uint256 blockingQuorum, 
        uint256 snapshotTime,
        uint256 endTime,
        bool vetoRight
    );

    event Voted(address indexed voter, bool support, uint256 weight);
    event VetoCasted();

    event ProposalResolved(uint256 yesVotes, uint256 noVotes, bool passed, bool vetoed);

    // Events emited by abstract Deal contract
    
    event MessageReceived(bytes4 messageKind, bytes message);
    event LegalWrapperMessageReceived(address indexed wrapper, bytes4 messageKind, bytes message);
    event Invited(address indexed invitee, bool canInvite);
    
    event EarlyReturnsToggled(uint256 indexed id, bool enabled);
    event WhitelistToggled(uint256 indexed id, bool enabled);
    event VetoRightEnabled(uint256 indexed id);

    event DealManagementProposalCreated(
        address indexed cell,
        address indexed prop,
        uint256 id,
        bytes4 indexed typ, 
        address target, 
        bytes32 data1, 
        bytes data2
    );

    event DealManagementProposalExecuted(address indexed cell, uint256 indexed id, bytes4 indexed typ);
    event VotingConfigUpdate(address indexed cell, uint256 indexed id, VotingConfig config);

    event VotesDelegated(address indexed treasuryToken, address delegatee);

    // Events emited by DealCell contract (Deal escrow, connecting Deal to DAC)

    event DealInitialized(address indexed dac, uint256 indexed id, address indexed deal, DealParams params);
    event DealRelatedContract(
        address indexed dac,
        uint256 indexed id,
        address indexed relatedContract,
        address deal,
        address dealCell,
        bytes32 role,
        bool controlled,
        bool managed
    );
    event DealActivated(
        address indexed dac, 
        uint256 indexed id, 
        address indexed deal, 
        uint256 totalAgentTokens
    );
    
    event AgentTokensStaked(
        address indexed dac, 
        uint256 indexed id, 
        address indexed deal, 
        address agent, 
        uint256 amount
    );

    event AgentTokensReleased(
        address indexed dac, 
        uint256 indexed id, 
        address indexed deal, 
        address agent, 
        uint256 amount
    );

    event TrancheRequested(
        address indexed dac, 
        uint256 indexed id,
        address indexed deal,
        uint256 tranche, 
        address token, 
        uint256 amount
    );

    event TrancheSettled(
        address indexed dac, 
        uint256 indexed id,
        address indexed deal,
        uint256 tranche, 
        address token, 
        uint256 amount
    );
    
    event CapitalReturned(
        address indexed dac, 
        uint256 indexed id, 
        address indexed deal, 
        address token, 
        uint256 amount
    );
    
    event DeadlineExtended(address indexed dac, uint256 indexed id, address indexed deal, uint256 newDeadline);
    event DealClosed(address indexed dac, uint256 indexed id, address indexed deal, uint256 totalAgentTokens);
    event DealRecovered(address indexed dac, uint256 indexed id, address indexed deal, address liquidator);

    event RewardsAllocated(address indexed dac, uint256 indexed id, address indexed deal, uint256 reward);
    event StakesSlashed(address indexed dac, uint256 indexed id, address indexed deal, uint256 slashAmount);
    
    event RewardsClaimed(address indexed dac, address indexed agent, address indexed deal, uint256 amount);
}
