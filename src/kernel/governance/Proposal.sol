// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {IExecutableProposal} from "../../interfaces/IExecutableProposal.sol";
import {IClock} from "../../lib/IClock.sol";
import {ProposalParams} from "../../interfaces/Structs.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

abstract contract Proposal is IVoting, IExecutableProposal, IClock, ReentrancyGuard, Initializable {
    bool private initialized;

    address public token;

    uint256 public endTime;
    uint256 public executionValidityDuration;
    uint256 public quorum;
    uint256 public blockingQuorum;
    uint256 public snapshotTime;
    uint256 public totalVotingPower;

    uint256 public yesVotes;
    uint256 public noVotes;
    mapping(address => bool) public voted;

    bool private proposalResolved;
    bool private resolvedOutcome;
    uint256 public resolutionTime;
    bool private proposalExecuted;

    ProposalParams public proposal;

    constructor() {
        _disableInitializers();
    }

    function __Proposal_init(
        ProposalParams memory _proposal,
        address _token,
        uint256 _duration,
        uint256 _executionValidityDuration,
        uint256 _totalVotingPower,
        uint256 _quorum,
        uint256 _blockingQuorum,
        bool _challengeEnabled
    ) internal onlyInitializing {
        initialized = true;

        snapshotTime = clock();

        endTime = block.timestamp + _duration;
        executionValidityDuration = _executionValidityDuration;
        token = _token;
        quorum = _quorum;
        blockingQuorum = _blockingQuorum;
        proposal = _proposal;
        totalVotingPower = _totalVotingPower;

        emit DACEventsLib.ProposalCreated(
            token,
            totalVotingPower,
            quorum,
            blockingQuorum,
            snapshotTime,
            endTime,
            _challengeEnabled
        );
    }

    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=timestamp";
    }

    function vote(bool support) external virtual nonReentrant {
        require(initialized, DACErrorsLib.NotInitialized());
        require(clock() <= endTime, DACErrorsLib.VotingEnded());
        require(!voted[msg.sender], DACErrorsLib.AlreadyVoted());

        uint256 weight = ERC20Votes(token).getPastVotes(msg.sender, snapshotTime);
        require(weight > 0, DACErrorsLib.NoVotingPower());

        if (support) {
            yesVotes += weight;
        } else {
            noVotes += weight;
        }

        voted[msg.sender] = true;

        emit DACEventsLib.Voted(msg.sender, support, weight);

        _checkAndEmitResolution();
    }

    function isResolved() external virtual returns (bool resolved) {
        _checkAndEmitResolution();
        resolved = proposalResolved;
    }

    function outcome() external virtual returns (bool) {
        _checkAndEmitResolution();

        if (proposalResolved) {
            return resolvedOutcome;
        }

        return _outcome();
    }

    function consumeExecution(bool requiredOutcome) external virtual nonReentrant {
        _checkAndEmitResolution();

        require(proposalResolved && resolvedOutcome == requiredOutcome, DACErrorsLib.VoteNotPassed());
        require(!proposalExecuted, DACErrorsLib.ProposalAlreadyExecuted());
        require(_isExecutableNow(), DACErrorsLib.ProposalNotExecutable());

        proposalExecuted = true;
    }

    function isExecutableNow() external virtual returns (bool executable) {
        _checkAndEmitResolution();
        executable = _isExecutableNow();
    }

    function isExecutionExpired() external virtual returns (bool expired) {
        _checkAndEmitResolution();
        expired = _isExecutionExpired();
    }

    function isExecuted() external view virtual returns (bool executed) {
        executed = proposalExecuted;
    }

    function executionDeadline() external virtual returns (uint256 deadline) {
        _checkAndEmitResolution();
        deadline = _executionDeadline();
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

    function _checkAndEmitResolution() internal {
        if (proposalResolved) return;

        bool nowResolved =
            ((yesVotes >= quorum) && ((blockingQuorum == 0) || (yesVotes >= (totalVotingPower - blockingQuorum)))) ||
            ((blockingQuorum > 0) && (noVotes >= blockingQuorum)) ||
            (clock() > endTime);

        if (nowResolved) {
            proposalResolved = true;
            resolvedOutcome = _outcome();
            resolutionTime = block.timestamp;

            emit DACEventsLib.ProposalResolved(
                yesVotes,
                noVotes,
                resolvedOutcome,
                false
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
                require(clock() > endTime, DACErrorsLib.NotResolved());
            }
        }

        return yesQuorumReached;
    }

    function _executionAvailableFrom() internal virtual returns (uint256 availableFrom) {
        availableFrom = resolutionTime;
    }

    function _executionDeadline() internal virtual returns (uint256 deadline) {
        uint256 availableFrom = _executionAvailableFrom();
        if (availableFrom == 0 || availableFrom == type(uint256).max) {
            return 0;
        }

        deadline = availableFrom + executionValidityDuration;
    }

    function _isExecutionExpired() internal virtual returns (bool expired) {
        uint256 deadline = _executionDeadline();
        expired = deadline != 0 && block.timestamp > deadline;
    }

    function _isExecutableNow() internal virtual returns (bool executable) {
        if (!proposalResolved || !resolvedOutcome || proposalExecuted) {
            return false;
        }

        uint256 availableFrom = _executionAvailableFrom();
        if (availableFrom == 0 || availableFrom == type(uint256).max || block.timestamp < availableFrom) {
            return false;
        }

        uint256 deadline = availableFrom + executionValidityDuration;
        executable = block.timestamp <= deadline;
    }
}
