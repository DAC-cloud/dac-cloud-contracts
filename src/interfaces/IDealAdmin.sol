// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Structs.sol";

interface IDealAdmin {
    // Tranche approval hook
    function approveFunding(uint256 trancheId) external;
    
    // State management
    function markAsSuccess(uint256 rewardPercent) external;
    function markAsFailed(uint256 slashPercent) external;
    function extendDeadline(uint256 newDeadline) external;
    function closeDeal() external;
    function recoverDeal(address liquidator, uint256 stakedAmount) external;

    // Legal wrapper messages, can be handled in modules
    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external;

    // Messages - special LP-governed actions for modules
    function messageDeal(bytes4 message, bytes calldata data) external;
}