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

struct GovernanceStrategyConfig {
    uint256 quorumPercent;
    uint256 highQuorumPercent;
    uint256 blockingPercent;
    uint256 duration;
    uint256 qualification;
    uint256 executionValidityDuration;
    uint256 oraclePublishDeadline;
    uint256 fallbackWarmupDuration;
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
