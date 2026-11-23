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
    // Sanity floor for quorum, high quorum and a non-zero blocking percent (1e15 = 0.1%).
    // Percents are scaled by 1e18; anything below this floor can only be a unit mistake.
    uint256 internal constant MIN_PERCENT = 1e15;
    // Hard cap on the holder list of one deal (every address that ever staked into it).
    // Slashing and reward allocation walk that list inside a single evaluation, and a
    // transaction is capped at 2^24 gas on Base: at 100 holders an evaluation carrying up
    // to ten slash/convert results still fits (five when it also closes the deal, since
    // the close hook's stipend must stay available). See audit.md for the envelope.
    uint256 internal constant MAX_DEAL_HOLDERS = 100;
    // A dividend payout can be claimed for this long. After that anyone can release what
    // was not claimed back to the free treasury.
    uint256 internal constant DIVIDEND_CLAIM_WINDOW = 365 days;
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
    // Wrapped votes only. Share (0 to SCALE) of a vote's snapshot weight that must still be
    // delegated to the voter when it votes, and that then stays locked (no unwrap, transfer
    // or re-delegation below it) for `voteLockDuration` seconds. Zero share: no requirement.
    // The longer the lock, the longer voting capital stays exposed to the outcome it voted for.
    uint256 voteRetentionPercent;
    uint256 voteLockDuration;
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
