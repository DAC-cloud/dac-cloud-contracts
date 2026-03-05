// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EvaluationResult, DealParams, VotingConfig, LegalWrapper} from "./Structs.sol";

library DACEventsLib {
    // DAC Cell Events
    event DACCreated(address indexed creator, string name);

    event VotingConfigUpdate(uint256 indexed id, VotingConfig config);
    event LegalWrapperMessage(address indexed wrapper, bytes4 messageKind, bytes message);
    event DividendsConfigUpdate(uint256 indexed id, bool enabled);

    // Indexed by proposal id
    event DACProposalExecuted(uint256 indexed id, bytes4 indexed typ);

    event TokenMinted(uint256 indexed id, uint256 amount);
    event TokenBurnt(uint256 indexed id, uint256 amount);

    event AgentTokenMinted(uint256 indexed id, address indexed agent, uint256 amount);
    event AgentTokenRevoked(uint256 indexed id, address indexed agent, uint256 amount);
    
    event LegalWrapperSet(uint256 indexed id, LegalWrapper legalWrapper);
    event OffchainActionApproved(uint256 indexed id, bytes4 action, bytes data);
    event DividendPayout(uint256 payoutId, address indexed token, uint256 totalPayout, bytes32 merkleRoot);
    

    event CapitalCallCreated(uint256 indexed id, address indexed recipient, bytes32 callHash, uint256 amount);
    event CapitalCallFulfilled(address indexed recipient, bytes32 callHash, uint256 amount);
    
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed from);

    event DACProposalCreated(uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);

    event DividendClaimed(uint256 payoutId, address indexed token, uint256 amountPayout);
    
    event DealCreated(
        address indexed dac, 
        uint256 indexed id, 
        uint256 indexed proposalId, 
        address creator, 
        bytes4 kind, 
        address cell, 
        address deal
    );

    event TrancheCreated(uint256 indexed id, uint256 indexed proposalId, uint256 trancheId);
    event FundingApproved(uint256 indexed id, uint256 indexed trancheId, uint256 rewardsLimit);
    
    event EvaluatorAdded(
        address indexed dac,
        uint256 indexed id,
        bytes4 evaluator,
        address evaluatorAddr
    );

    event DealEvaluated(address dac, uint256 indexed id, EvaluationResult[] evaluations);

    event ModuleAdded(address indexed dacCell, address indexed factory);
    event ModuleRemoved(address indexed dacCell, address indexed factory);

    // Proposal event
    event Voted(address indexed voter, bool support, uint256 weight);
    event VetoCasted();

    // Global events, indexed by DAC and deal id
    event DealInitialized(address indexed dac, uint256 indexed id, DealParams params);
    event DealActivated(address indexed dac, uint256 indexed id, uint256 totalAgentTokens);
    event TrancheRequested(address indexed dac, uint256 indexed id, uint256 tranche, address token, uint256 amount);
    
    event CapitalReturned(address indexed dac, uint256 indexed id, address token, uint256 amount);
    event DeadlineExtended(address indexed dac, uint256 indexed id, uint256 newDeadline);
    event DealClosed(address indexed dac, uint256 indexed id, uint256 totalAgentTokens);
    event DealRecovered(address indexed dac, uint256 indexed id, address liquidator);
    
    // Deal specific events, indexed by Deal address, proposal id, or agent
    event MessageReceived(bytes4 messageKind, bytes message);
    event LegalWrapperMessageReceived(address indexed wrapper, bytes4 messageKind, bytes message);
    event Invited(address indexed invitee, bool canInvite);
    
    event EarlyReturnsToggled(uint256 indexed id, bool enabled);
    event VetoRightEnabled(uint256 indexed id);

    event DealManagementProposalExecuted(address indexed cell,uint256 indexed id, bytes4 indexed typ);
    event VotingConfigUpdate(address indexed cell, uint256 indexed id, VotingConfig config);

    // Deal cell events    
    event AgentTokensStaked(address indexed dac, uint256 indexed id, address indexed agent, uint256 amount);
    event AgentTokensReleased(address indexed dac, uint256 indexed id, address indexed agent, uint256 amount);

    event RewardsAllocated(address indexed dac, uint256 indexed id, uint256 reward);
    event StakesSlashed(address indexed dac, uint256 indexed id, uint256 slashAmount);
    
    event RewardsClaimed(address indexed dac, address indexed agent, uint256 amount);

    event DealManagementProposalCreated(address indexed cell, uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);

    event VotesDelegated(address indexed treasuryToken, address delegatee);
}