// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Voting.sol";

contract VotingFactory {
    function deployVoting(
        uint256 id, 
        uint256 duration, 
        address token, 
        uint256 quorum,
        uint256 blockingQuorum
    ) external returns (address) {
        return address(new Voting(id, duration, token, quorum, blockingQuorum));
    }
}