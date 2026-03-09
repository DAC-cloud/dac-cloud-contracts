// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVoting {
    function castVeto() external;
    function vote(bool support) external;
    function isResolved() external returns (bool);
    function outcome() external returns (bool);
}
