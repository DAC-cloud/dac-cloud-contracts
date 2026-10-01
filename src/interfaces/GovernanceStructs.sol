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

/// Upper bounds for time/block config fields. Consumers add these to
/// block.timestamp / block.number with checked arithmetic, so an unbounded value
/// (or one absurdly large) would make every later proposal creation or
/// activation revert, bricking governance with no proposal left to fix it.
library GovernanceLimits {
    uint256 internal constant MAX_DURATION = 365 days;
    uint256 internal constant MAX_WARMUP_BLOCKS = 5_000_000;
}

struct GovernanceStrategyConfig {
    uint256 quorumPercent;
    uint256 highQuorumPercent;
    uint256 blockingPercent;
    uint256 duration;
    uint256 qualification;          // Qualification percent (0 to SCALE) of voting supply
    uint256 executionValidityDuration;
    uint256 oraclePublishDeadline;
    uint256 fallbackWarmupBlocks;    // Warmup length in blocks; the fallback snapshot is the warmup's last block
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

struct OracleSnapshot {
    uint256 snapshotBlock;
    bytes32 merkleRoot;
    uint256 totalUnderlyingVotingPower;
    uint256 publishedAt;
}
