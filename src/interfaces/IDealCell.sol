// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Structs.sol";

interface IDealCell {
    function stakeToken() external view returns (address);

    function claimMainToken() external;
    function unstake() external;
    
    function fundingToken(uint256 trancheId) external view returns (address);
    function fundingAmount(uint256 trancheId) external view returns (uint256);
    function fundingTokens() external view returns (address[] memory);

    function getStakedAgentTotal() external view returns (uint256);
    function getReturnedCapital(address token) external view returns (uint256);
    function getInvestedCapital(address token) external view returns (uint256);
    function getMainRewardsLimit() external view returns (uint256);
    
    function isValidDeal() external pure returns (bool);
    function isApproved() external view returns (bool);
    function isClosed() external view returns (bool);
    function approveDeadline() external view returns (uint256);
    function dealDeadline() external view returns (uint256);
}