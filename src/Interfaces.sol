// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotingFactory {
    function deployVoting(uint256 id, uint256 duration, address owner, address token, uint256 quorum) external returns (address);
}

interface IVoting {
    function vote(bool support) external;
    function isResolved(uint256 propId) external view returns (bool);
    function outcome(uint256 propId) external view returns (bool);
}

struct VotingConfig {
    uint256 quorumPercent;
    uint256 defaultDuration;   // in seconds
}

enum LPManagementType {
    MintMP,
    Dividend,
    CapitalCall,
    AddTrustedEvaluatorFactory,
    RemoveTrustedEvaluatorFactory,
    RevokeMP
}

struct LPMParams {
    LPManagementType typ;
    address target;      // For RevokeMP / Add/RemoveFactory
    uint256 amount;      // For RevokeMP (amount to burn)
    bytes data;          // Future-proof opaque data
}

enum StakedMPManagementType {
    // Common to all Deals
    ToggleEarlyReturns,
    ToggleWhitelist,
    // DACDeal-specific
    CreateChildLPProposal,
    ChildLPProposalVoting,
    ChildDealVoting,
    // VaultDeal-specific
    ApprovePermit2Spend,
    ReturnCapitalToDAC
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
    address dealTarget;        // childDAC or Vault-based deal address
    address proposer;
    string description;
    address fundingToken;
    uint256 fundingAmount;
    uint256 lpRewardsLimit;
    uint256 approveDeadline;
    uint256 dealDeadline;
    uint256 managedEquity;     // only for DAC based Deals (investment into child DAC LP)
    bool isWhitelistOnly;
    address evaluatorFactory;     // trusted factory that creates the evaluator
    bytes evaluatorConfig;        // opaque config for evaluator (e.g. abi.encode(Milestone[]))
    bytes dealConfig;             // future-proof field for deal-specific init data
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
    uint256 expectedReturnPercent; // cumulative % of funding expected back
    uint256 rewardPercentage;
    uint256 penalty; // slash % applied
}

struct EvaluationResult {
    uint8 action;       // 0=slash, 1=convert, 2=extend, 3=close
    uint256 percent;    // % to slash/convert
    uint256 newDeadline; // only for extend
}
