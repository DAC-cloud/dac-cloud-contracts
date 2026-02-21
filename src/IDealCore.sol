// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

interface IDealCore {
    function claimLP() external;
    function onMPStaked(address staker, uint256 amount) external;
    function unstake() external;
    function returnCapitalToDAC() external;
    function getStakedMPTotal() external view returns (uint256);
    function getReturnedCapital() external view returns (uint256);
    function getLPRewardsLimit() external view returns (uint256);
    function isValidDeal() external pure returns (bool);
    function isApproved() external view returns (bool);
    function isClosed() external view returns (bool);
    function fundingToken() external view returns (address);
    function fundingAmount(uint256 trancheId) external view returns (uint256);
    function approveDeadline() external view returns (uint256);
    function dealDeadline() external view returns (uint256);
}