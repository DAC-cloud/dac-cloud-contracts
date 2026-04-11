// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernanceStrategyConfig} from "./GovernanceStructs.sol";

struct DACConfig {
    string symbol;
    string name;
    string description;
    uint256 mainTokenMaxSupply;
    uint256 defaultQuorum;
    address founder;
    uint256 founderAllocation;
    address treasuryToken;
    uint256 founderCommitment;
    bool dividendsEnabled;
}

struct ExistingDACConfig {
    string symbol;
    string name;
    string description;
    address underlyingToken;
    uint256 treasurySeedAmount;
    address governanceOracle;       // Optional, address(0) = no oracle (oraclePrimaryEnabled must be false)
    bool dividendsEnabled;
    GovernanceStrategyConfig governanceStrategy;
}

// Quorum configuration - i.e. "what are the quorum requirements for a proposal type" 
// can be changed by updating governance factory in future in voting config

struct VotingConfig {
    uint256 quorumPercent;          // Quorum percent for default operations
    uint256 blockingPercent;        // Blocking percent, if applicable
    uint256 highQuorumPercent;      // Quorum percent for operations requiring "unanimous" approve
    uint256 duration;               // Voting duration in seconds
    uint256 qualification;          // Qualification percent (0 to SCALE) of voting supply needed to create a proposal
    uint256 executionValidityDuration; // Time window after becoming executable when execution remains valid
}

struct LegalWrapper {
    address wrapperAddr; 
    string operatingAgreementIPFS;
    string registeredAgent;
    bytes data;
}

struct CapitalCall {
    address treasuryToken;
    uint256 nonce;
    address tokenRecipient;
    uint256 tokenAmount;
    uint256 cashAmount;
}

struct ProposalParams {
    bytes4 typ;
    address target;
    bytes32 i;
    bytes data;
}

struct DealParams {
    bytes4 dealKind;
    string name;
    string description;
    string linkHash;                // For hash of the document submission in external document management system
    address moduleFactory;
    address governanceFactory;
    address dealTarget;             // childDAC or Vault-based deal address
    address proposer;
    bool vetoEnabled;               // If enabled, chickens can push a veto on High-quorum proposals through their Default+blocking proposal
    address fundingToken;
    uint256 fundingAmount;
    uint256 rewardsLimit;
    uint256 dealRewardPoolPercent; // portion of unlocked rewards allocated to the deal itself
    uint256 approveDeadline;
    uint256 evaluationDeadline;     // The deadline before the first evaluation
    uint256 dealDeadline;           // The date where withdraw capital becomes possible
    bytes dealConfig;               // future-proof field for deal-specific init data (like DACConfig)
    bytes4 evaluatorSelector;       // evaluator selector. Deal factory shall confirm that the evaluator supports the deal
    bytes evaluatorConfig;          // config for evaluator (e.g. abi.encode(Milestone[]))
    address evaluatorModuleFactory;  // Module for evaluator deployment (address(0) = use deal's moduleFactory)
    uint256 agentsLimit;            // Maximum number of stakers (0 = no limit)
    uint256 minimalStake;           // Minimum stake amount per agent (0 = no minimum)
}

struct EvaluationResult {
    uint8 action;                   // 0=slash, 1=convert, 2=extend, 3=close
    uint256 percent;                // % to slash/convert
    uint256 extendTo;               // only for extend
}

struct Tranche {
    address token;
    uint256 amount;
    uint256 rewards;
    bool settled;
}
