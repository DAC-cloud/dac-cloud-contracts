// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Voting.sol";

contract VotingFactory {
    function deployVoting(uint256 id, uint256 duration, address owner, address token) external returns (address) {
        Voting voting = new Voting(id, duration, owner, token, 50); // Assume quorum 50
        return address(voting);
    }
}
