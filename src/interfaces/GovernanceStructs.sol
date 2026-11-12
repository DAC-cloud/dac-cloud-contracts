// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum DACMode {
    NATIVE,
    EXISTING_TOKEN
}

enum ProposalPhase {
    AwaitingOracleSnapshot,
    PrimaryVoting,
    FallbackWarmup,
    FallbackVoting,
    Resolved
}

enum AssetCapability {
    MINT,
    BURN,
    CAPITAL_CALL,
    WRAP,
    UNWRAP,
    RESERVE_BACKED_CLAIMS
}

enum CommitmentKind {
    DEAL_REWARDS,
    DIVIDENDS,
    OTHER
}

enum AgentTokenMintAction {
    DIRECT_AGENT,
    DISTRIBUTOR_INVENTORY,
    DISTRIBUTOR_DISABLE
}

/// Upper bounds for time config fields. Every duration in the protocol is in
/// seconds; consumers add them to block.timestamp with checked arithmetic, so an
/// unbounded value (or one absurdly large) would make every later proposal
/// creation or activation revert, bricking governance with no proposal left to
/// fix it.
library GovernanceLimits {
    uint256 internal constant MAX_DURATION = 365 days;
    // A CAST_VETO_DEAL challenge holds a deal proposal for a whole DAC vote and
    // occupies its single challenge slot, so opening one needs at least a normal
    // active holder's stake even when the DAC's own `qualification` is zero.
    // Scaled percent of votable supply: 1e15 = 0.1%.
    uint256 internal constant MIN_VETO_QUALIFICATION = 1e15;
}

struct GovernanceStrategyConfig {
    uint256 quorumPercent;
    uint256 highQuorumPercent;
    uint256 blockingPercent;
    uint256 duration;
    uint256 qualification;          // Qualification percent (0 to SCALE) of voting supply
    uint256 executionValidityDuration;
    uint256 oraclePublishDeadline;
    uint256 fallbackWarmupDuration;  // Warmup length in seconds; the fallback snapshot is the warmup's last second
    uint256 fallbackDuration;
    bool blockingOnAllProposals;
    bool blockingOnHighQuorum;
    bool oraclePrimaryEnabled;
}

struct DealCreationConfig {
    uint256 minAgentBalance;
    uint256 minInitialAgentStake;
}

struct AssetControllerConfig {
    DACMode mode;
    address mainAsset;
    bool reserveBackedClaims;
}

struct ExistingTokenConfig {
    address underlyingToken;
    address governanceOracle;
    string wrappedName;
    string wrappedSymbol;
}

/// `snapshotTime` is a timestamp: the Merkle tree reflects the underlying token
/// balances as of the last block whose timestamp is <= snapshotTime.
struct OracleSnapshot {
    uint256 snapshotTime;
    bytes32 merkleRoot;
    uint256 totalUnderlyingVotingPower;
    uint256 publishedAt;
}
