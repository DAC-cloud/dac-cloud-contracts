// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotingFactory {
    function deployVoting(
        uint256 id, 
        uint256 duration, 
        address token, 
        uint256 quorum,
        uint256 blocking
    ) external returns (address);
}

interface IVoting {
    function vote(bool support) external;
    function isResolved() external view returns (bool);
    function outcome() external view returns (bool);
}

struct VotingConfig {
    uint256 quorumPercent;          // Quorum percent for default operations
    uint256 blockingPercent;        // Blocking percent, if applicable
    uint256 highQuorumPercent;      // Quorum percent for operations requiring "unanimous" approve
    uint256 defaultDuration;        // in seconds
}

enum LPManagementType {
    UpdateVotingConfig,             // High quorum
    MintMP,                         // Default quorum, blocking not allowed
    RevokeMP,                       // Default quorum, blocking allowed
    Dividend,                       // High quorum
    CapitalCall,                    // Default quorum, blocking allowed
    AddTrustedEvaluatorFactory,     // High quorum
    RemoveTrustedEvaluatorFactory,  // High quorum
    ApproveDeal,                    // Default quorum, blocking allowed
    ApproveTranche                  // Default quorum, blocking allowed
}

struct LPMParams {
    LPManagementType typ;
    address target;      // For RevokeMP / Add/RemoveFactory
    uint256 amount;      // For RevokeMP (amount to burn)
    bytes data;          // Future-proof opaque data
}

enum StakedMPManagementType {
    // Common to all Deals
    UpdateVotingConfig,             // High quorum
    RequestTranche,                 // High quorum
    AddStake,                       // High quorum
    ToggleEarlyReturns,             // High quorum
    ToggleWhitelist,                // High quorum
    // DACDeal-specific
    CreateChildLPProposal,          // Default quorum
    ChildLPProposalVoting,          // Default quorum, blocking
    // VaultDeal-specific
    ApprovePermit2Spend,            // Default quorum, blocking
    ReturnCapitalToDAC,             // Default quorum
    AssignClaimer                   // Default quorum
}

struct StakedMPParams {
    StakedMPManagementType typ;
    address target;      // For ApprovePermit2Spend (treasury token), etc.
    uint256 id;          // For governance ops
    bytes data;          // Opaque type-specific data (calldataHash, etc.)
}

struct DealParams {
    bytes4 dealKind;
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
    bool isWhitelistOnly;
    address evaluatorFactory;       // trusted factory that creates the evaluator
    bytes evaluatorConfig;          // opaque config for evaluator (e.g. abi.encode(Milestone[]))
    bytes dealConfig;               // future-proof field for deal-specific init data
}

struct CapitalCall {
    address treasuryToken;
    uint256 nonce;
    address lpRecipient;
    uint256 lpAmount;
    uint256 cashAmount;
}

struct Milestone {
    uint256 timestamp;
    uint256 expectedReturnPercent;  // cumulative % of funding expected back
    uint256 rewardPercentage;
    uint256 penalty;                // slash % applied
}

struct EvaluationResult {
    uint8 action;                   // 0=slash, 1=convert, 2=extend, 3=close
    uint256 percent;                // % to slash/convert
    uint256 newDeadline;            // only for extend
}
