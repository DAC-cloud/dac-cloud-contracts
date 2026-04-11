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
import {MathLib} from "../libraries/MathLib.sol";
import {IVotes} from "../../lib/IVotes.sol";

contract HybridDACManagementProposal is IVoting, IExecutableProposal, ReentrancyGuard, Initializable {
    uint256 public id;
    address public dacCell;
    address public wrappedToken;
    address public governanceOracle;

    ProposalParams public proposal;
    GovernanceStrategyConfig private strategy;

    ProposalPhase public phase;

    uint256 public primarySnapshotBlock;
    uint256 public fallbackSnapshotBlock;
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
        address _wrappedToken,
        address _governanceOracle,
        ProposalParams memory _proposal,
        GovernanceStrategyConfig memory _strategy,
        bool _highQuorum,
        bool _blockingEnabled
    ) external initializer {
        require(block.number > 0, DACErrorsLib.NotAllowed());
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_wrappedToken != address(0), DACErrorsLib.NotAllowed());
        require(_governanceOracle != address(0), DACErrorsLib.NotAllowed());
        require(_strategy.duration > 0, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.executionValidityDuration > 0, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.oraclePublishDeadline > 0 || !_strategy.oraclePrimaryEnabled, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.fallbackWarmupDuration > 0, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.fallbackDuration > 0, DACErrorsLib.InvalidVotingConfig());

        id = _id;
        dacCell = _dacCell;
        wrappedToken = _wrappedToken;
        governanceOracle = _governanceOracle;
        proposal = _proposal;
        strategy = _strategy;
        highQuorum = _highQuorum;
        blockingEnabled = _blockingEnabled;
        primarySnapshotBlock = block.number - 1;
        if (_strategy.oraclePrimaryEnabled) {
            oracleSnapshotDeadline = block.timestamp + _strategy.oraclePublishDeadline;
            phase = ProposalPhase.AwaitingOracleSnapshot;
        } else {
            oracleSnapshotDeadline = 0;
            phase = ProposalPhase.FallbackWarmup;
            phaseStartTime = block.timestamp;
            phaseEndTime = block.timestamp + _strategy.fallbackWarmupDuration;
        }

        emit DACEventsLib.ProposalCreated(
            wrappedToken,
            0,
            0,
            0,
            primarySnapshotBlock,
            phase == ProposalPhase.AwaitingOracleSnapshot ? oracleSnapshotDeadline : phaseEndTime,
            false
        );
        emit DACEventsLib.ProposalPhaseTransition(
            id,
            uint8(phase),
            primarySnapshotBlock,
            phase == ProposalPhase.AwaitingOracleSnapshot ? block.timestamp : phaseStartTime,
            phase == ProposalPhase.AwaitingOracleSnapshot ? oracleSnapshotDeadline : phaseEndTime,
            0,
            0,
            0
        );
    }

    function activatePrimaryVoting() external {
        require(phase == ProposalPhase.AwaitingOracleSnapshot, DACErrorsLib.NotAllowed());
        require(strategy.oraclePrimaryEnabled, DACErrorsLib.NotAllowed());
        require(block.timestamp <= oracleSnapshotDeadline, DACErrorsLib.NotAllowed());
        require(IGovernanceOracle(governanceOracle).isActive(), DACErrorsLib.NotAllowed());

        OracleSnapshot memory snapshot = IGovernanceOracle(governanceOracle).getSnapshot(id);
        require(snapshot.merkleRoot != bytes32(0), DACErrorsLib.NotFound());
        require(snapshot.snapshotBlock == primarySnapshotBlock, DACErrorsLib.NotAllowed());

        _tryActivatePrimary();
    }

    function beginFallbackWarmup() external {
        require(phase == ProposalPhase.AwaitingOracleSnapshot, DACErrorsLib.NotAllowed());
        require(
            block.timestamp > oracleSnapshotDeadline || !IGovernanceOracle(governanceOracle).isActive(),
            DACErrorsLib.NotAllowed()
        );

        phase = ProposalPhase.FallbackWarmup;
        phaseStartTime = block.timestamp;
        phaseEndTime = block.timestamp + strategy.fallbackWarmupDuration;

        emit DACEventsLib.ProposalPhaseTransition(
            id,
            uint8(phase),
            primarySnapshotBlock,
            phaseStartTime,
            phaseEndTime,
            0,
            0,
            0
        );
    }

    function triggerEmergencyFallback() external {
        require(
            phase == ProposalPhase.AwaitingOracleSnapshot || phase == ProposalPhase.PrimaryVoting,
            DACErrorsLib.NotAllowed()
        );
        require(strategy.oraclePrimaryEnabled, DACErrorsLib.NotAllowed());
        require(!proposalResolved, DACErrorsLib.NotAllowed());
        require(!IGovernanceOracle(governanceOracle).isActive(), DACErrorsLib.NotAllowed());

        yesVotes = 0;
        noVotes = 0;
        totalVotingPower = 0;
        quorum = 0;
        blockingQuorum = 0;
        oracleMerkleRoot = bytes32(0);
        totalUnderlyingVotingPower = 0;

        phase = ProposalPhase.FallbackWarmup;
        phaseStartTime = block.timestamp;
        phaseEndTime = block.timestamp + strategy.fallbackWarmupDuration;

        emit DACEventsLib.ProposalPhaseTransition(
            id,
            uint8(phase),
            primarySnapshotBlock,
            phaseStartTime,
            phaseEndTime,
            0,
            0,
            0
        );
    }

    function activateFallbackVoting() external {
        require(phase == ProposalPhase.FallbackWarmup, DACErrorsLib.NotAllowed());
        require(block.timestamp > phaseEndTime, DACErrorsLib.NotAllowed());
        require(block.number > 0, DACErrorsLib.NotAllowed());

        _activateFallbackInternal();
    }

    function vote(bool support) external override nonReentrant {
        _voteWrapped(msg.sender, support);
    }

    function voteWrapped(bool support) external nonReentrant {
        _voteWrapped(msg.sender, support);
    }

    function voteMerkle(bool support, uint256 index, uint256 amount, bytes32[] calldata proof) external nonReentrant {
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
        uint256 snapshotBlock,
        uint256 phaseTotalVotingPower,
        uint256 duration
    ) internal {
        phase = nextPhase;
        phaseStartTime = block.timestamp;
        phaseEndTime = block.timestamp + duration;
        totalVotingPower = phaseTotalVotingPower;
        quorum = MathLib.mul(
            phaseTotalVotingPower,
            highQuorum ? strategy.highQuorumPercent : strategy.quorumPercent
        );
        blockingQuorum = blockingEnabled ? MathLib.mul(phaseTotalVotingPower, strategy.blockingPercent) : 0;

        emit DACEventsLib.ProposalPhaseTransition(
            id,
            uint8(phase),
            snapshotBlock,
            phaseStartTime,
            phaseEndTime,
            totalVotingPower,
            quorum,
            blockingQuorum
        );
    }

    function _voteWrapped(address voter, bool support) internal {
        // Opportunistic phase activation — only for transitions that land in a votable phase.
        // Keeps vote() usable by lightweight clients that don't implement explicit activation calls.
        if (phase == ProposalPhase.AwaitingOracleSnapshot) {
            _tryActivatePrimary();
        } else if (phase == ProposalPhase.FallbackWarmup && block.timestamp > phaseEndTime) {
            _activateFallbackInternal();
        }

        require(
            phase == ProposalPhase.PrimaryVoting || phase == ProposalPhase.FallbackVoting,
            DACErrorsLib.NotAllowed()
        );

        uint256 snapshotBlock = phase == ProposalPhase.PrimaryVoting ? primarySnapshotBlock : fallbackSnapshotBlock;
        require(block.timestamp <= phaseEndTime, DACErrorsLib.VotingEnded());

        if (phase == ProposalPhase.PrimaryVoting) {
            require(!primaryWrappedVoted[voter], DACErrorsLib.AlreadyVoted());
            primaryWrappedVoted[voter] = true;
        } else {
            require(!fallbackWrappedVoted[voter], DACErrorsLib.AlreadyVoted());
            fallbackWrappedVoted[voter] = true;
        }

        uint256 weight = IVotes(wrappedToken).getPastVotes(voter, snapshotBlock);
        require(weight > 0, DACErrorsLib.NoVotingPower());
        _countVote(support, weight);

        emit DACEventsLib.Voted(voter, support, weight);

        _checkAndEmitResolution();
    }

    function _tryActivatePrimary() internal {
        if (!strategy.oraclePrimaryEnabled) return;
        if (block.timestamp > oracleSnapshotDeadline) return;
        if (!IGovernanceOracle(governanceOracle).isActive()) return;

        OracleSnapshot memory snapshot = IGovernanceOracle(governanceOracle).getSnapshot(id);
        if (snapshot.merkleRoot == bytes32(0)) return;
        if (snapshot.snapshotBlock != primarySnapshotBlock) return;

        oracleMerkleRoot = snapshot.merkleRoot;
        totalUnderlyingVotingPower = snapshot.totalUnderlyingVotingPower;

        _activateVotingPhase(
            ProposalPhase.PrimaryVoting,
            primarySnapshotBlock,
            totalUnderlyingVotingPower + IVotes(wrappedToken).getPastTotalSupply(primarySnapshotBlock),
            strategy.duration
        );
    }

    function _activateFallbackInternal() internal {
        fallbackSnapshotBlock = block.number - 1;

        _activateVotingPhase(
            ProposalPhase.FallbackVoting,
            fallbackSnapshotBlock,
            IVotes(wrappedToken).getPastTotalSupply(fallbackSnapshotBlock),
            strategy.fallbackDuration
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
        if (phase != ProposalPhase.PrimaryVoting && phase != ProposalPhase.FallbackVoting) return;

        bool nowResolved =
            ((yesVotes >= quorum) && ((blockingQuorum == 0) || (yesVotes >= (totalVotingPower - blockingQuorum)))) ||
            ((blockingQuorum > 0) && (noVotes >= blockingQuorum)) ||
            (block.timestamp > phaseEndTime);

        if (nowResolved) {
            ProposalPhase resolvedFromPhase = phase;
            proposalResolved = true;
            resolvedOutcome = _outcome();
            resolutionTime = block.timestamp;
            phase = ProposalPhase.Resolved;

            emit DACEventsLib.ProposalResolved(
                yesVotes,
                noVotes,
                resolvedOutcome
            );

            emit DACEventsLib.ProposalPhaseTransition(
                id,
                uint8(phase),
                resolvedFromPhase == ProposalPhase.FallbackVoting ? fallbackSnapshotBlock : primarySnapshotBlock,
                phaseStartTime,
                block.timestamp,
                totalVotingPower,
                quorum,
                blockingQuorum
            );
        }
    }

    function _outcome() internal view returns (bool) {
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
