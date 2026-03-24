// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IExecutableProposal {
    function consumeExecution(bool requiredOutcome) external;
    function isExecutableNow() external returns (bool);
    function isExecutionExpired() external returns (bool);
    function isExecuted() external view returns (bool);
    function resolutionTime() external view returns (uint256);
    function executionDeadline() external returns (uint256);
}
