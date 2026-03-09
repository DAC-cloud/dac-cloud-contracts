// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {IClock} from "../../lib/IClock.sol";
import {ProposalParams} from "../../interfaces/Structs.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

abstract contract Proposal is IVoting, IClock, ReentrancyGuard, Initializable {

    bool private initialized;

    address public token;

    // Voting configuration
    uint256 public endTime;
    uint256 public quorum;
    uint256 public blockingQuorum;

    // Voting power snapshot is taken at the proposal creation moment
    uint256 public snapshotTime;

    uint256 public totalVotingPower;

    bool public vetoRight;
    address public vetoRightOwner;

    // Voting state
    uint256 public yesVotes;
    uint256 public noVotes;
    mapping(address => bool) public voted;

    // Resolution state
    bool private proposalResolved;
    bool private resolvedOutcome;
    bool public vetoCasted;

    // Proposal
    ProposalParams public proposal;

    constructor() {
        _disableInitializers();
    }

    function __Proposal_init(
        ProposalParams memory _proposal, 
        address _token, 
        uint256 _duration, 
        uint256 _totalVotingPower,
        uint256 _quorum, 
        uint256 _blockingQuorum,
        address _vetoRightOwner
    ) internal onlyInitializing {
        initialized = true;

        snapshotTime = clock();
        
        endTime = block.timestamp + _duration;
        token = _token;
        quorum = _quorum;
        blockingQuorum = _blockingQuorum;
        proposal = _proposal;

        totalVotingPower = _totalVotingPower;

        if (_vetoRightOwner != address(0)) {
            vetoRight = true;
            vetoRightOwner = _vetoRightOwner;
        }

        emit DACEventsLib.ProposalCreated(
            token,
            totalVotingPower,
            quorum,
            blockingQuorum,
            snapshotTime,
            endTime,
            vetoRight
        );
    }

    // ERC-6372 Clock with timestamp mode
    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=timestamp";
    }

    function vote(bool support) external nonReentrant {
        require(initialized, DACErrorsLib.NotInitialized());

        require(clock() <= endTime, DACErrorsLib.VotingEnded());
        require(!voted[msg.sender], DACErrorsLib.AlreadyVoted());

        uint256 weight = ERC20Votes(token).getPastVotes(msg.sender, snapshotTime);

        require(weight > 0, DACErrorsLib.NoVotingPower());

        if (support) {
            yesVotes += weight; 
        }
        else {
            noVotes += weight;
        }

        voted[msg.sender] = true;
        
        emit DACEventsLib.Voted(msg.sender, support, weight);

        _checkAndEmitResolution();
    }

    function castVeto() external {
        require(vetoRight, DACErrorsLib.VetoNotEnabled());
        require(msg.sender == vetoRightOwner, DACErrorsLib.NotAuthorized());
        
        vetoCasted = true;

        emit DACEventsLib.VetoCasted();

        _checkAndEmitResolution();
    }

    function _checkAndEmitResolution() private {
        if (proposalResolved) return;

        // if veto possible - then proposal only becomes resolved after the end date, and not early

        // if blocking quorum set - not resolved unless yes overtook blocking quorum already

        bool nowResolved = (
            (vetoCasted) ||
            (
                (yesVotes >= quorum) && 
                ((blockingQuorum == 0) || (yesVotes >= (totalVotingPower - blockingQuorum))) &&
                (!vetoRight)
            ) ||
            ((blockingQuorum > 0) && (noVotes >= blockingQuorum)) ||
            (clock() > endTime)
        );

        if (nowResolved) {
            proposalResolved = true;

            resolvedOutcome = _outcome();

            emit DACEventsLib.ProposalResolved(
                yesVotes,
                noVotes,
                resolvedOutcome,
                vetoCasted
            );
        }
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

    function _outcome() private view returns (bool) {
        if (vetoCasted) return false;

        if (vetoRight) {
            require(clock() > endTime, DACErrorsLib.NotResolved());
        }

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
}