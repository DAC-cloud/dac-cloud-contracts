// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAgentToken {
    function stakeToDeal(address deal, uint256 amount) external;
}
