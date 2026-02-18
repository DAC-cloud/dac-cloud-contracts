// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

interface IDeal {
    function initialize(DealParams calldata params) external;
    function onMPStaked(address staker, uint256 amount) external;
    function onApproved() external;
    function markAsSuccess(uint256 rewardPercent) external;
    function markAsFailed(uint256 slashPercent) external;
    function claimLP() external;
    function unstake() external;
    function returnCapitalToDAC() external;
    function getStakedMPTotal() external view returns (uint256);
    function getReturnedCapital() external view returns (uint256);
    function isValidDeal() external pure returns (bool);
    function votingContract() external view returns (address);
    function fundingToken() external view returns (address);
    function fundingAmount() external view returns (uint256);
    function approveDeadline() external view returns (uint256);
    function dealDeadline() external view returns (uint256);
}