// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Interfaces.sol";

contract Voting is IVoting {
    uint256 public immutable propId;
    uint256 public immutable endTime;
    address public immutable token; // LP or StakedMP
    uint256 public immutable quorum;
    uint256 public immutable blockingQuorum;

    uint256 public yesVotes;
    uint256 public noVotes;
    mapping(address => bool) public voted;

    // Events
    event Voted(address indexed voter, bool support, uint256 weight);

    constructor(uint256 _propId, uint256 _duration, address _token, uint256 _quorum, uint256 _blockingQuorum) {
        propId = _propId;
        endTime = block.timestamp + _duration;
        token = _token;
        quorum = _quorum;
        blockingQuorum = _blockingQuorum;
    }

    function vote(bool support) external {
        require(block.timestamp <= endTime, "Voting ended");
        require(!voted[msg.sender], "Already voted");
        uint256 weight = IERC20(token).balanceOf(msg.sender);
        if (support) yesVotes += weight; else noVotes += weight;
        voted[msg.sender] = true;
        emit Voted(msg.sender, support, weight);
    }

    function isResolved() external view returns (bool) { return block.timestamp > endTime; }
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
}