// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {IClock} from "../../lib/IClock.sol";
import {ProposalParams} from "../../interfaces/Structs.sol";

abstract contract Proposal is IVoting, IClock, ReentrancyGuard, Initializable {

    error NotInitialized();
    error NotResolved();
    error VetoNotEnabled();
    error NotAuthorized();
    error VotingEnded();
    error AlreadyVoted();
    error NoVotingPower();

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

    bool public vetoCasted;

    // Proposal
    ProposalParams public proposal;

    // Events
    event Voted(address indexed voter, bool support, uint256 weight);

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
    }

    // ERC-6372 Clock with timestamp mode
    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=timestamp";
    }

    function vote(bool support) external nonReentrant {
        require(initialized, NotInitialized());

        require(clock() <= endTime, VotingEnded());
        require(!voted[msg.sender], AlreadyVoted());

        uint256 weight = ERC20Votes(token).getPastVotes(msg.sender, snapshotTime);

        require(weight > 0, NoVotingPower());

        if (support) {
            yesVotes += weight; 
        }
        else {
            noVotes += weight;
        }

        voted[msg.sender] = true;
        
        emit Voted(msg.sender, support, weight);
    }

    function castVeto() external {
        require(vetoRight, VetoNotEnabled());
        require(msg.sender == vetoRightOwner, NotAuthorized());
        
        vetoCasted = true;
    }

    function isResolved() external view returns (bool resolved) { 
        // if veto possible - then proposal only becomes resolved after the end date, and not early

        // if blocking quorum set - not resolved unless yes overtook blocking quorum already

        resolved = (
            (
                (yesVotes >= quorum) && 
                ((blockingQuorum == 0) || (yesVotes >= (totalVotingPower - blockingQuorum))) &&
                (!vetoRight)
            ) ||
            ((blockingQuorum > 0) && (noVotes >= blockingQuorum)) ||
            (clock() > endTime)
        );
    }

    function outcome() external view returns (bool) {
        if (vetoCasted) return false;

        if (vetoRight) {
            require(clock() > endTime, NotResolved());
        }

        bool yesQuorumReached = yesVotes >= quorum;

        if (blockingQuorum > 0) {
            if (noVotes >= blockingQuorum) {
                return false;
            }

            if (!(yesVotes >= totalVotingPower - blockingQuorum)) {
                require(clock() > endTime, NotResolved());
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