// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Voting.sol";

contract VotingFactory {
    function deployVoting(
        uint256 id, 
        uint256 duration, 
        address owner, 
        address token, 
        uint256 quorum
    ) external returns (address) {
        return address(new Voting(id, duration, owner, token, quorum));
    }
}