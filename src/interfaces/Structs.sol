// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

// Quorum configuration - i.e. "what are the quorum requirements for a proposal type" 
// can be changed by updating governance factory in future in voting config

struct VotingConfig {
    uint256 quorumPercent;          // Quorum percent for default operations
    uint256 blockingPercent;        // Blocking percent, if applicable
    uint256 highQuorumPercent;      // Quorum percent for operations requiring "unanimous" approve
    uint256 duration;               // Voting duration in seconds
    uint256 qualification;          // Min amount of LP tokens needed to create a proposal
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
    address moduleFactory;
    address governanceFactory;
    address dealTarget;             // childDAC or Vault-based deal address
    address proposer;
    string linkHash;                // Hash of the Deal submission in external document management system
    bool vetoEnabled;               // If enabled, chickens can push a veto on High-quorum proposals through their Default+blocking proposal
    address fundingToken;
    uint256 fundingAmount;
    uint256 rewardsLimit;
    uint256 approveDeadline;
    uint256 dealDeadline;           // The deadline before the first evaluation
    bytes4 evaluatorSelector;       // evaluator selector. Deal factory shall confirm that the evaluator supports the deal
    bytes dealConfig;               // future-proof field for deal-specific init data (like DACConfig)
    bytes evaluatorConfig;          // config for evaluator (e.g. abi.encode(Milestone[]))
}

struct EvaluationResult {
    uint8 action;                   // 0=slash, 1=convert, 2=extend, 3=close
    uint256 percent;                // % to slash/convert
    uint256 newDeadline;            // only for extend
}
