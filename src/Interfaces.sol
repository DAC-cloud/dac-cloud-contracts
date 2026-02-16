// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotingFactory {
    function deployVoting(uint256 id, uint256 duration, address owner, address token) external returns (address);
}

interface IVoting {
    function isResolved(uint256 propId) external view returns (bool);
    function outcome(uint256 propId) external view returns (bool);
}

enum LPManagementType { MintMP, Dividend, CapitalCall }