// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDealManager {
    function deals(uint256 id) external view returns (address);
    function isRecoverable(uint256 id) external view returns (bool);
    function createTrancheProposal(uint256 dealId, uint256 trancheId) external;
    function totalUnreleasedMainTokens() external view returns (uint256);
}