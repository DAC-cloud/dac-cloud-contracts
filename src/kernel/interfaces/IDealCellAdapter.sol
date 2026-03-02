// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams, VotingConfig} from "../../interfaces/Structs.sol";
import {DealManagementProposal} from "../governance/DealManagementProposal.sol";

interface IDealCellAdapter {
    function onDACInit(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external;

    function registerControlledAddress(address controlled) external;

    function requestTranche(
        DealManagementProposal prop
    ) external;

    function onAgentTokenStaked(address staker, uint256 amount) external;
    
    function transferCapital(address token, uint256 amount) external;

    function approveFunding(uint256 trancheId) external;
    function withdrawCapital() external;
    
    function toggleEarlyReturns(bool earlyReturns) external;
    function toggleWhitelist(bool whitelistOnly) external;
    function enableVeto() external;

    function addStake(address staker, uint256 amount) external;

    function markAsSuccess(uint256 rewardPercent) external;
    function markAsFailed(uint256 slashPercent) external;
    function extendDeadline(uint256 newDeadline) external;
    function closeDeal() external;
    function recoverDeal(address liquidator, uint256 stakedAmount) external;

    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external;
    function messageDeal(bytes4 message, bytes calldata data) external;
}