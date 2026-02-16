// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Voting {
    uint256 public propId;
    uint256 public endTime;
    address public owner;
    IERC20 public token; // LP or StakedMP
    uint256 public quorum;

    uint256 public yesVotes;
    uint256 public noVotes;
    mapping(address => bool) public voted;

    constructor(uint256 _propId, uint256 _duration, address _owner, address _token, uint256 _quorum) {
        propId = _propId;
        endTime = block.timestamp + _duration;
        owner = _owner;
        token = IERC20(_token);
        quorum = _quorum;
    }

    function vote(bool support) external {
        require(block.timestamp <= endTime, "Voting ended");
        require(!voted[msg.sender], "Already voted");
        uint256 weight = token.balanceOf(msg.sender);
        if (support) {
            yesVotes += weight;
        } else {
            noVotes += weight;
        }
        voted[msg.sender] = true;
        emit Voted(msg.sender, support, weight);
    }

    function isResolved(uint256 id) external view returns (bool) {
        return block.timestamp > endTime;
    }

    function outcome(uint256 id) external view returns (bool) {
        uint256 totalVotes = yesVotes + noVotes;
        return yesVotes >= (totalVotes * quorum) / 100;
    }

    event Voted(address indexed voter, bool support, uint256 weight);
}