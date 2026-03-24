// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {IGovernanceOracle} from "../../interfaces/IGovernanceOracle.sol";
import {ProposalParams} from "../../interfaces/Structs.sol";
import {GovernanceStrategyConfig, OracleSnapshot, ProposalPhase} from "../../interfaces/GovernanceStructs.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IVotes} from "../../lib/IVotes.sol";

contract HybridDACManagementProposal is IVoting, ReentrancyGuard, Initializable {
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

    bool public vetoRight;
    address public vetoRightOwner;
    bool public vetoCasted;

    bool private proposalResolved;
    bool private resolvedOutcome;

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
        bool _blockingEnabled,
        address _vetoRightOwner
    ) external initializer {
        require(block.number > 0, DACErrorsLib.NotAllowed());
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_wrappedToken != address(0), DACErrorsLib.NotAllowed());
        require(_governanceOracle != address(0), DACErrorsLib.NotAllowed());
        require(_strategy.duration > 0, DACErrorsLib.InvalidVotingConfig());
        require(_strategy.oraclePublishDeadline > 0, DACErrorsLib.InvalidVotingConfig());
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
        oracleSnapshotDeadline = block.timestamp + _strategy.oraclePublishDeadline;
        phase = ProposalPhase.AwaitingOracleSnapshot;

        if (_vetoRightOwner != address(0)) {
            vetoRight = true;
            vetoRightOwner = _vetoRightOwner;
        }

        emit DACEventsLib.ProposalCreated(
            wrappedToken,
            0,
            0,
            0,
            primarySnapshotBlock,
            oracleSnapshotDeadline,
            vetoRight
        );
        emit DACEventsLib.ProposalPhaseTransition(
            id,
            uint8(phase),
            primarySnapshotBlock,
            block.timestamp,
            oracleSnapshotDeadline,
            0,
            0,
            0
        );
    }

    function activatePrimaryVoting() external {
        require(phase == ProposalPhase.AwaitingOracleSnapshot, DACErrorsLib.NotAllowed());
        require(block.timestamp <= oracleSnapshotDeadline, DACErrorsLib.NotAllowed());

        OracleSnapshot memory snapshot = IGovernanceOracle(governanceOracle).getSnapshot(id);
        require(snapshot.merkleRoot != bytes32(0), DACErrorsLib.NotFound());
        require(snapshot.snapshotBlock == primarySnapshotBlock, DACErrorsLib.NotAllowed());

        oracleMerkleRoot = snapshot.merkleRoot;
        totalUnderlyingVotingPower = snapshot.totalUnderlyingVotingPower;

        _activateVotingPhase(
            ProposalPhase.PrimaryVoting,
            primarySnapshotBlock,
            totalUnderlyingVotingPower + IVotes(wrappedToken).getPastTotalSupply(primarySnapshotBlock),
            strategy.duration
        );
    }

    function beginFallbackWarmup() external {
        require(phase == ProposalPhase.AwaitingOracleSnapshot, DACErrorsLib.NotAllowed());
        require(block.timestamp > oracleSnapshotDeadline, DACErrorsLib.NotAllowed());

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

        fallbackSnapshotBlock = block.number - 1;

        _activateVotingPhase(
            ProposalPhase.FallbackVoting,
            fallbackSnapshotBlock,
            IVotes(wrappedToken).getPastTotalSupply(fallbackSnapshotBlock),
            strategy.fallbackDuration
        );
    }

    function vote(bool support) external override nonReentrant {
        _voteWrapped(msg.sender, support);
    }

    function voteWrapped(bool support) external nonReentrant {
        _voteWrapped(msg.sender, support);
    }

    function _voteWrapped(address voter, bool support) internal {
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

    function castVeto() external {
        require(vetoRight, DACErrorsLib.VetoNotEnabled());
        require(msg.sender == vetoRightOwner, DACErrorsLib.NotAuthorized());
        require(!proposalResolved, DACErrorsLib.ProposalAlreadyExecuted());

        vetoCasted = true;

        emit DACEventsLib.VetoCasted();

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

        bool nowResolved = (
            vetoCasted ||
            (
                yesVotes >= quorum &&
                ((blockingQuorum == 0) || (yesVotes >= (totalVotingPower - blockingQuorum))) &&
                (!vetoRight)
            ) ||
            ((blockingQuorum > 0) && (noVotes >= blockingQuorum)) ||
            (block.timestamp > phaseEndTime)
        );

        if (nowResolved) {
            ProposalPhase resolvedFromPhase = phase;
            proposalResolved = true;
            resolvedOutcome = _outcome();
            phase = ProposalPhase.Resolved;

            emit DACEventsLib.ProposalResolved(yesVotes, noVotes, resolvedOutcome, vetoCasted);
            emit DACEventsLib.ProposalPhaseTransition(
                id,
                uint8(phase),
                resolvedFromPhase == ProposalPhase.PrimaryVoting ? primarySnapshotBlock : fallbackSnapshotBlock,
                phaseStartTime,
                block.timestamp,
                totalVotingPower,
                quorum,
                blockingQuorum
            );
        }
    }

    function _outcome() internal view returns (bool) {
        if (vetoCasted) return false;

        if (vetoRight) {
            require(block.timestamp > phaseEndTime, DACErrorsLib.NotResolved());
        }

        bool yesQuorumReached = yesVotes >= quorum;

        if (blockingQuorum > 0) {
            if (noVotes >= blockingQuorum) {
                return false;
            }

            if (!(yesVotes >= totalVotingPower - blockingQuorum)) {
                require(block.timestamp > phaseEndTime, DACErrorsLib.NotResolved());
            }
        }

        return yesQuorumReached;
    }
}
