// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Quorum configuration - i.e. "what are the quorum requirements for a proposal type" 
// can be changed by updating governance factory in future in voting config

struct VotingConfig {
    uint256 quorumPercent;          // Quorum percent for default operations
    uint256 blockingPercent;        // Blocking percent, if applicable
    uint256 highQuorumPercent;      // Quorum percent for operations requiring "unanimous" approve
    uint256 duration;               // in seconds
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
    address lpRecipient;
    uint256 lpAmount;
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
    address dealFactory;
    address governanceFactory;
    address dealTarget;             // childDAC or Vault-based deal address
    address proposer;
    string linkHash;                // Hash of the Deal submission in external document management system
    address fundingToken;
    uint256 fundingAmount;
    uint256 lpRewardsLimit;
    uint256 approveDeadline;
    uint256 dealDeadline;
    uint256 managedEquity;          // only for DAC based Deals (investment into child DAC LP)
    uint256 capitalCallId;          // only for DAC based Deals
    address evaluatorFactory;       // trusted factory that creates the evaluator
    bytes evaluatorConfig;          // config for evaluator (e.g. abi.encode(Milestone[]))
    bytes dealConfig;               // future-proof field for deal-specific init data (like DACConfig)
}



struct Milestone {
    bytes32 milestoneType;          // opaque bytes for milestone type, and byte-masked functionality encoding
    address token;                  // token for accounting purposes
    uint256 timestamp;
    uint256 expectedReturnPercent;  // cumulative % or amount of funding expected back
    uint256 rewardPercentage;
    uint256 penalty;                // slash % applied
}

struct EvaluationResult {
    uint8 action;                   // 0=slash, 1=convert, 2=extend, 3=close
    uint256 percent;                // % to slash/convert
    uint256 newDeadline;            // only for extend
}
