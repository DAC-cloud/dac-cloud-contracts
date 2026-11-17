// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {IExecutableProposal} from "../../interfaces/IExecutableProposal.sol";
import {IGovernanceOracle} from "../../interfaces/IGovernanceOracle.sol";
import {ProposalParams} from "../../interfaces/Structs.sol";
import {GovernanceStrategyConfig, OracleSnapshot, ProposalPhase} from "../../interfaces/GovernanceStructs.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IVotes} from "../../lib/IVotes.sol";

/// The schema that owns a hybrid proposal relays its vote locks to the wrapped token.
interface IVoteLockRelay {
    function lockVotes(address account, uint256 amount, uint256 until) external;
}

contract HybridDACManagementProposal is IVoting, IExecutableProposal, ReentrancyGuard, Initializable {
    // Gas each read of the governance oracle is guaranteed and limited to. An oracle that
    // reverts, burns its gas or answers with malformed data reads as "no snapshot" and
    // "not active": it can send a proposal to fallback, never freeze it.
    uint256 internal constant ORACLE_READ_GAS = 300_000;

    uint256 public id;
    address public dacCell;
    address public wrappedToken;
    address public governanceOracle;
    address public assetController;

    // Only this address may call `consumeExecution`. Set at init to the schema
    // that owns this proposal's lifecycle. Without this gate any unrelated
    // address could mark a passed proposal as executed before the schema's
    // legitimate consume-and-act flow, permanently DoS-ing the action.
    address public executor;

    ProposalParams public proposal;
    GovernanceStrategyConfig private strategy;

    ProposalPhase public phase;

    // Every time below is a timestamp, and every one of them follows from the creation
    // time, the strategy durations and, for the primary path, the oracle's publication
    // time. Phase transitions are applied lazily by whichever transaction touches the
    // proposal next, but the times they stamp do not depend on that transaction. The one
    // exception is a fallback forced by an oracle that is switched off: it starts when it
    // is triggered.

    // The primary snapshot is the second before creation, already in the past for
    // ERC-5805 lookups.
    uint256 public primarySnapshotTime;
    // Last second of fallback warmup. Fixed when fallback begins, and public from then
    // on, so holders can wrap and delegate in response to the proposal. Zero until then.
    uint256 public fallbackSnapshotTime;
    uint256 public phaseStartTime;
    uint256 public phaseEndTime;
    uint256 public oracleSnapshotDeadline;

    uint256 public totalVotingPower;
    uint256 public quorum;
    uint256 public blockingQuorum;
    uint256 public yesVotes;
    uint256 public noVotes;

    bool public highQuorum;
    bool public blockingEnabled;

    bool private proposalResolved;
    bool private resolvedOutcome;
    uint256 public resolutionTime;
    bool private proposalExecuted;

    bytes32 public oracleMerkleRoot;
    uint256 public totalUnderlyingVotingPower;

    mapping(address => bool) public primaryWrappedVoted;
    mapping(address => bool) public fallbackWrappedVoted;
    mapping(bytes32 => bool) public primaryMerkleVoted;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 _id,
        address _dacCell,
        address _executor,
        address _wrappedToken,
        address _governanceOracle,
        address _assetController,
        ProposalParams memory _proposal,
        GovernanceStrategyConfig memory _strategy,
        bool _highQuorum,
        bool _blockingEnabled
    ) external initializer {
        require(block.timestamp > 0, DACErrorsLib.NotAllowed());
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_executor != address(0), DACErrorsLib.NotAllowed());
        require(_wrappedToken != address(0), DACErrorsLib.NotAllowed());
        require(_assetController != address(0), DACErrorsLib.NotAllowed());
        // Oracle is only required when oracle-primary mode is enabled
        require(!_strategy.oraclePrimaryEnabled || _governanceOracle != address(0), DACErrorsLib.NotAllowed());
        require(_strategy.duration > 0, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.executionValidityDuration > 0, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.oraclePublishDeadline > 0 || !_strategy.oraclePrimaryEnabled, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.fallbackWarmupDuration > 0, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.fallbackDuration > 0, DACErrorsLib.InvalidVotingConfig());

        id = _id;
        dacCell = _dacCell;
        executor = _executor;
        wrappedToken = _wrappedToken;
        governanceOracle = _governanceOracle;
        assetController = _assetController;
        proposal = _proposal;
        strategy = _strategy;
        highQuorum = _highQuorum;
        blockingEnabled = _blockingEnabled;
        primarySnapshotTime = block.timestamp - 1;
        if (_strategy.oraclePrimaryEnabled) {
            oracleSnapshotDeadline = block.timestamp + _strategy.oraclePublishDeadline;
            phase = ProposalPhase.AwaitingOracleSnapshot;

            emit DACEventsLib.ProposalCreated(wrappedToken, 0, 0, 0, primarySnapshotTime, oracleSnapshotDeadline, false);
            emit DACEventsLib.ProposalPhaseTransition(
                id, uint8(phase), primarySnapshotTime, block.timestamp, oracleSnapshotDeadline, 0, 0, 0
            );
        } else {
            oracleSnapshotDeadline = 0;
            _beginFallbackWarmup(block.timestamp);

            emit DACEventsLib.ProposalCreated(wrappedToken, 0, 0, 0, fallbackSnapshotTime, 0, false);
        }
    }

    /// Enters primary voting once the oracle has published this proposal's snapshot in time.
    /// Optional: any vote or state read does the same.
    function activatePrimaryVoting() external {
        require(phase == ProposalPhase.AwaitingOracleSnapshot, DACErrorsLib.NotAllowed());
        require(_tryActivatePrimary(), DACErrorsLib.NotAllowed());
    }

    /// Starts fallback warmup for a proposal the oracle has not published a timely
    /// snapshot for: once its deadline has passed, or earlier when the oracle is switched
    /// off. Optional after the deadline: any vote or state read does the same, with the
    /// same times.
    function beginFallbackWarmup() external {
        require(phase == ProposalPhase.AwaitingOracleSnapshot, DACErrorsLib.NotAllowed());
        // A snapshot published in time means primary voting, whatever happened to the
        // oracle since. Leaving primary then takes `triggerEmergencyFallback`.
        require(!_hasTimelySnapshot(), DACErrorsLib.NotAllowed());

        bool deadlinePassed = block.timestamp > oracleSnapshotDeadline;
        require(deadlinePassed || !_oracleActive(), DACErrorsLib.NotAllowed());

        // A missed deadline starts warmup at the deadline, whenever it is noticed. An oracle
        // switched off before its deadline starts it now.
        _beginFallbackWarmup(deadlinePassed ? oracleSnapshotDeadline : block.timestamp);
    }

    function triggerEmergencyFallback() external {
        require(strategy.oraclePrimaryEnabled, DACErrorsLib.NotAllowed());
        // Apply any pending transition and finalize a primary vote that already ended by
        // time before wiping it.
        _checkAndEmitResolution();
        require(!proposalResolved, DACErrorsLib.NotAllowed());
        require(
            phase == ProposalPhase.AwaitingOracleSnapshot || phase == ProposalPhase.PrimaryVoting,
            DACErrorsLib.NotAllowed()
        );
        require(!_oracleActive(), DACErrorsLib.NotAllowed());

        yesVotes = 0;
        noVotes = 0;
        totalVotingPower = 0;
        quorum = 0;
        blockingQuorum = 0;
        oracleMerkleRoot = bytes32(0);
        totalUnderlyingVotingPower = 0;

        _beginFallbackWarmup(block.timestamp);
    }

    /// Optional: any vote or state read after the fallback snapshot does the same.
    function activateFallbackVoting() external {
        require(phase == ProposalPhase.FallbackWarmup, DACErrorsLib.NotAllowed());
        require(block.timestamp > fallbackSnapshotTime, DACErrorsLib.NotAllowed());

        _activateFallback();
    }

    function vote(bool support) external override nonReentrant {
        _voteWrapped(msg.sender, support);
    }

    function voteWrapped(bool support) external nonReentrant {
        _voteWrapped(msg.sender, support);
    }

    function voteMerkle(bool support, uint256 index, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _syncPhase();

        require(phase == ProposalPhase.PrimaryVoting, DACErrorsLib.NotAllowed());
        require(block.timestamp <= phaseEndTime, DACErrorsLib.VotingEnded());

        bytes32 leaf = keccak256(abi.encodePacked(index, msg.sender, amount));
        require(!primaryMerkleVoted[leaf], DACErrorsLib.AlreadyVoted());
        require(MerkleProof.verify(proof, oracleMerkleRoot, leaf), DACErrorsLib.InvalidMerkleProof());

        primaryMerkleVoted[leaf] = true;
        _countVote(support, amount);

        emit DACEventsLib.MerkleVoted(id, msg.sender, support, amount, index);

        _checkAndEmitResolution();
    }

    function isResolved() external returns (bool resolved) {
        _checkAndEmitResolution();
        resolved = proposalResolved;
    }

    function outcome() external returns (bool) {
        _checkAndEmitResolution();

        if (proposalResolved) {
            return resolvedOutcome;
        }

        return _outcome();
    }

    function consumeExecution(bool requiredOutcome) external nonReentrant {
        // Only the bound executor (the GovernanceSchema that deployed this
        // proposal) may consume execution. Without this gate any address could
        // mark the proposal executed and DoS the schema's consume-and-act flow.
        require(msg.sender == executor, DACErrorsLib.NotAuthorized());

        _checkAndEmitResolution();

        require(proposalResolved && resolvedOutcome == requiredOutcome, DACErrorsLib.VoteNotPassed());
        require(!proposalExecuted, DACErrorsLib.ProposalAlreadyExecuted());
        require(_isExecutableNow(), DACErrorsLib.ProposalNotExecutable());

        proposalExecuted = true;
    }

    function isExecutableNow() external returns (bool executable) {
        _checkAndEmitResolution();
        executable = _isExecutableNow();
    }

    function isExecutionExpired() external returns (bool expired) {
        _checkAndEmitResolution();
        uint256 deadline = _executionDeadline();
        expired = deadline != 0 && block.timestamp > deadline;
    }

    function isExecuted() external view returns (bool executed) {
        executed = proposalExecuted;
    }

    function executionDeadline() external returns (uint256 deadline) {
        _checkAndEmitResolution();
        deadline = _executionDeadline();
    }

    function getStrategy() external view returns (GovernanceStrategyConfig memory config) {
        return strategy;
    }

    function typ() external view returns (bytes4) {
        return proposal.typ;
    }

    function target() external view returns (address) {
        return proposal.target;
    }

    function i() external view returns (bytes32) {
        return proposal.i;
    }

    function data() external view returns (bytes memory) {
        return proposal.data;
    }

    function _activateVotingPhase(
        ProposalPhase nextPhase,
        uint256 snapshotTime,
        uint256 phaseTotalVotingPower,
        uint256 startTime,
        uint256 endTime
    ) internal {
        // A phase with no votable supply at its snapshot would resolve vacuously
        // (0 >= quorum 0). Callers reject such a phase instead of activating it.
        require(phaseTotalVotingPower > 0, DACErrorsLib.NoVotingPower());

        phase = nextPhase;
        phaseStartTime = startTime;
        phaseEndTime = endTime;
        totalVotingPower = phaseTotalVotingPower;
        // Round up: a quorum that rounds to zero would let a dust-level supply pass a
        // proposal with no votes at all.
        quorum = MathLib.mulRoundUp(
            phaseTotalVotingPower,
            highQuorum ? strategy.highQuorumPercent : strategy.quorumPercent
        );
        blockingQuorum = blockingEnabled ? MathLib.mulRoundUp(phaseTotalVotingPower, strategy.blockingPercent) : 0;

        emit DACEventsLib.ProposalPhaseTransition(
            id,
            uint8(phase),
            snapshotTime,
            phaseStartTime,
            phaseEndTime,
            totalVotingPower,
            quorum,
            blockingQuorum
        );
    }

    function _voteWrapped(address voter, bool support) internal {
        // Keeps vote() usable by lightweight clients that never call the explicit
        // transition functions.
        _syncPhase();

        require(
            phase == ProposalPhase.PrimaryVoting || phase == ProposalPhase.FallbackVoting,
            DACErrorsLib.NotAllowed()
        );

        uint256 snapshotTime = phase == ProposalPhase.PrimaryVoting ? primarySnapshotTime : fallbackSnapshotTime;
        require(block.timestamp <= phaseEndTime, DACErrorsLib.VotingEnded());

        if (phase == ProposalPhase.PrimaryVoting) {
            require(!primaryWrappedVoted[voter], DACErrorsLib.AlreadyVoted());
            primaryWrappedVoted[voter] = true;
        } else {
            require(!fallbackWrappedVoted[voter], DACErrorsLib.AlreadyVoted());
            fallbackWrappedVoted[voter] = true;
        }

        uint256 weight = IVotes(wrappedToken).getPastVotes(voter, snapshotTime);
        require(weight > 0, DACErrorsLib.NoVotingPower());

        // Voting capital stays exposed to the outcome: the configured share of this vote's
        // weight must still be delegated to the voter now (the lock reverts otherwise) and
        // cannot be unwrapped, moved or re-delegated until the lock period ends.
        uint256 retained = MathLib.mulRoundUp(weight, strategy.voteRetentionPercent);
        if (retained > 0) {
            IVoteLockRelay(executor).lockVotes(voter, retained, block.timestamp + strategy.voteLockDuration);
        }

        _countVote(support, weight);

        emit DACEventsLib.Voted(voter, support, weight);

        _checkAndEmitResolution();
    }

    // Applies every transition that is due. The times it stamps come from the schedule,
    // never from the transaction that happens to apply them.
    function _syncPhase() internal {
        if (phase == ProposalPhase.AwaitingOracleSnapshot) {
            if (!_tryActivatePrimary() && block.timestamp > oracleSnapshotDeadline) {
                _beginFallbackWarmup(oracleSnapshotDeadline);
            }
        }
        if (phase == ProposalPhase.FallbackWarmup && block.timestamp > fallbackSnapshotTime) {
            _activateFallback();
        }
    }

    // True when the oracle has published this proposal's snapshot, for the right snapshot
    // time, no later than the deadline. Publication time decides, not the moment someone
    // first looks, and not whether the oracle is still active: a snapshot published in time
    // stays binding until someone takes the proposal out of primary through the emergency
    // fallback, which starts a fresh, public warmup.
    function _hasTimelySnapshot() internal view returns (bool timely) {
        (timely,) = _timelySnapshot();
    }

    function _timelySnapshot() internal view returns (bool timely, OracleSnapshot memory snapshot) {
        if (!strategy.oraclePrimaryEnabled) return (false, snapshot);

        (bool ok, bytes memory ret) = _readOracle(abi.encodeCall(IGovernanceOracle.getSnapshot, (dacCell, id)));
        if (!ok || ret.length != 128) return (false, snapshot);

        snapshot = abi.decode(ret, (OracleSnapshot));
        timely = snapshot.merkleRoot != bytes32(0)
            && snapshot.snapshotTime == primarySnapshotTime
            && snapshot.publishedAt <= oracleSnapshotDeadline;
    }

    function _oracleActive() internal view returns (bool) {
        (bool ok, bytes memory ret) = _readOracle(abi.encodeCall(IGovernanceOracle.isActive, (dacCell)));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    // One isolated, gas-capped read. The stipend is guaranteed, so a read can fail only
    // because of the oracle, never because the caller sent too little gas.
    function _readOracle(bytes memory callData) internal view returns (bool ok, bytes memory ret) {
        require(gasleft() > ORACLE_READ_GAS * 64 / 63 + 20_000, DACErrorsLib.InsufficientGas());
        (ok, ret) = governanceOracle.staticcall{gas: ORACLE_READ_GAS}(callData);
    }

    function _tryActivatePrimary() internal returns (bool activated) {
        (bool timely, OracleSnapshot memory snapshot) = _timelySnapshot();
        if (!timely) return false;

        oracleMerkleRoot = snapshot.merkleRoot;
        totalUnderlyingVotingPower = snapshot.totalUnderlyingVotingPower;

        uint256 wrappedVotable = IVotes(wrappedToken).getPastTotalSupply(primarySnapshotTime)
            - IAssetController(assetController).getPastControlledBalance(primarySnapshotTime);

        if (totalUnderlyingVotingPower + wrappedVotable == 0) {
            _resolveWithoutElectorate(primarySnapshotTime, snapshot.publishedAt);
            return true;
        }

        // Primary voting runs for `duration` from the oracle's publication.
        _activateVotingPhase(
            ProposalPhase.PrimaryVoting,
            primarySnapshotTime,
            totalUnderlyingVotingPower + wrappedVotable,
            snapshot.publishedAt,
            snapshot.publishedAt + strategy.duration
        );
        return true;
    }

    // Warmup is measured in seconds and its last second is the fallback snapshot. The
    // snapshot is fixed and public from `startTime` on, so holders can wrap and delegate in
    // response to the proposal, and nobody can pick the snapshot time at their discretion.
    function _beginFallbackWarmup(uint256 startTime) internal {
        phase = ProposalPhase.FallbackWarmup;
        phaseStartTime = startTime;
        phaseEndTime = 0; // warmup ends at the snapshot, see fallbackSnapshotTime
        fallbackSnapshotTime = startTime + strategy.fallbackWarmupDuration;

        emit DACEventsLib.ProposalPhaseTransition(
            id,
            uint8(phase),
            fallbackSnapshotTime,
            phaseStartTime,
            0,
            0,
            0,
            0
        );
    }

    function _activateFallback() internal {
        uint256 wrappedVotable = IVotes(wrappedToken).getPastTotalSupply(fallbackSnapshotTime)
            - IAssetController(assetController).getPastControlledBalance(fallbackSnapshotTime);

        if (wrappedVotable == 0) {
            _resolveWithoutElectorate(fallbackSnapshotTime, fallbackSnapshotTime);
            return;
        }

        // Fallback voting runs for `fallbackDuration` from the snapshot.
        _activateVotingPhase(
            ProposalPhase.FallbackVoting,
            fallbackSnapshotTime,
            wrappedVotable,
            fallbackSnapshotTime,
            fallbackSnapshotTime + strategy.fallbackDuration
        );
    }

    // No votable supply at the snapshot: nobody can vote, so the proposal is rejected
    // rather than left dormant. A dormant proposal would never resolve, and anything
    // gated on its resolution (a CAST_VETO_DEAL challenge holding a deal proposal)
    // would be frozen forever.
    function _resolveWithoutElectorate(uint256 snapshotTime, uint256 resolvedAt) internal {
        proposalResolved = true;
        resolvedOutcome = false;
        resolutionTime = resolvedAt;
        phase = ProposalPhase.Resolved;

        emit DACEventsLib.ProposalResolved(0, 0, false);
        emit DACEventsLib.ProposalPhaseTransition(
            id, uint8(phase), snapshotTime, resolvedAt, resolvedAt, 0, 0, 0
        );
    }

    function _countVote(bool support, uint256 weight) internal {
        if (support) {
            yesVotes += weight;
        } else {
            noVotes += weight;
        }
    }

    function _checkAndEmitResolution() internal {
        if (proposalResolved) return;

        // Lazy phase transitions: nothing gated on this proposal's resolution can be
        // frozen by nobody calling the explicit transition functions.
        _syncPhase();
        if (proposalResolved) return;

        if (phase != ProposalPhase.PrimaryVoting && phase != ProposalPhase.FallbackVoting) return;

        bool byTime = block.timestamp > phaseEndTime;
        bool nowResolved =
            ((yesVotes >= quorum) && ((blockingQuorum == 0) || (yesVotes >= (totalVotingPower - blockingQuorum)))) ||
            ((blockingQuorum > 0) && (noVotes >= blockingQuorum)) ||
            byTime;

        if (nowResolved) {
            ProposalPhase resolvedFromPhase = phase;
            proposalResolved = true;
            resolvedOutcome = _outcome();
            // A deciding vote stamps its own time; a resolution by time is stamped with the
            // end of voting, so the execution window does not depend on who observes it.
            resolutionTime = byTime ? phaseEndTime : block.timestamp;
            phase = ProposalPhase.Resolved;

            emit DACEventsLib.ProposalResolved(
                yesVotes,
                noVotes,
                resolvedOutcome
            );

            emit DACEventsLib.ProposalPhaseTransition(
                id,
                uint8(phase),
                resolvedFromPhase == ProposalPhase.FallbackVoting ? fallbackSnapshotTime : primarySnapshotTime,
                phaseStartTime,
                resolutionTime,
                totalVotingPower,
                quorum,
                blockingQuorum
            );
        }
    }

    function _outcome() internal view returns (bool) {
        // Before a voting phase is active quorum is still zero and `0 >= 0` would read
        // as a yes; only voting and resolved phases carry an outcome.
        require(
            phase == ProposalPhase.PrimaryVoting ||
                phase == ProposalPhase.FallbackVoting ||
                phase == ProposalPhase.Resolved,
            DACErrorsLib.NotResolved()
        );

        bool yesQuorumReached = yesVotes >= quorum;

        if (blockingQuorum > 0) {
            if (noVotes >= blockingQuorum) {
                return false;
            }

            if (!(yesVotes >= totalVotingPower - blockingQuorum)) {
                require(
                    phase == ProposalPhase.Resolved || block.timestamp > phaseEndTime,
                    DACErrorsLib.NotResolved()
                );
            }
        } else {
            require(
                phase == ProposalPhase.Resolved || yesQuorumReached || block.timestamp > phaseEndTime,
                DACErrorsLib.NotResolved()
            );
        }

        return yesQuorumReached;
    }

    function _executionDeadline() internal view returns (uint256 deadline) {
        if (!proposalResolved) {
            return 0;
        }

        deadline = resolutionTime + strategy.executionValidityDuration;
    }

    function _isExecutableNow() internal view returns (bool executable) {
        if (!proposalResolved || !resolvedOutcome || proposalExecuted) {
            return false;
        }

        executable = block.timestamp <= resolutionTime + strategy.executionValidityDuration;
    }
}
