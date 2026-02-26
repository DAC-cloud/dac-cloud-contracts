// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/IVoting.sol";
import "../../interfaces/Structs.sol";

abstract contract Proposal is IVoting {
    address public immutable token;

    // Voting configuration
    uint256 public immutable endTime;
    uint256 public immutable quorum;
    uint256 public immutable blockingQuorum;

    // Voting state
    uint256 public yesVotes;
    uint256 public noVotes;
    mapping(address => bool) public voted;

    // Proposal
    ProposalParams public proposal;

    // Events
    event Voted(address indexed voter, bool support, uint256 weight);

    constructor(
        ProposalParams memory _proposal, 
        address _token, 
        uint256 _duration, 
        uint256 _quorum, 
        uint256 _blockingQuorum
    ) {
        endTime = block.timestamp + _duration;
        token = _token;
        quorum = _quorum;
        blockingQuorum = _blockingQuorum;
        proposal = _proposal;
    }

    function vote(bool support) external {
        require(block.timestamp <= endTime, "Voting ended");
        require(!voted[msg.sender], "Already voted");

        uint256 weight = IERC20(token).balanceOf(msg.sender);
        
        if (support) yesVotes += weight; else noVotes += weight;
        voted[msg.sender] = true;
        
        emit Voted(msg.sender, support, weight);
    }

    function isResolved() external view returns (bool resolved) { 
        uint256 total = yesVotes + noVotes;

        resolved = (
            ((total > 0) && (yesVotes * 100 >= total * quorum)) ||
            ((blockingQuorum > 0) && (noVotes * 100 >= total * blockingQuorum)) ||
            (block.timestamp > endTime)
        );
    }

    function outcome() external view returns (bool) {
        uint256 total = yesVotes + noVotes;

        bool yesQuorumReached = (total > 0) && (yesVotes * 100 >= total * quorum);

        if (blockingQuorum > 0) {
            if (noVotes * 100 >= total * blockingQuorum) {
                return false;
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