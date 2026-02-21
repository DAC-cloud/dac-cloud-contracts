// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

interface IDealAdmin {
    function onApproved(uint256 trancheId) external;
    function markAsSuccess(uint256 rewardPercent) external;
    function markAsFailed(uint256 slashPercent) external;
    function extendDeadline(uint256 newDeadline) external;
    function closeDeal() external;
}