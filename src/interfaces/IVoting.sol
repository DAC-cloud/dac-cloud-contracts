// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVoting {
    function vote(bool support) external;
    function isResolved() external view returns (bool);
    function outcome() external view returns (bool);
}
