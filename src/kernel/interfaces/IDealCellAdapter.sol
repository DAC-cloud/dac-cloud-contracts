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

    function onAgentTokenStaked(address staker, uint256 amount) external;
    
    function transferCapital(address token, uint256 amount) external;

    function approveFunding(uint256 trancheId, uint256 rewardsLimit) external;
    function withdrawCapital() external;
    
    function executeCellAgentProposal(
        DealManagementProposal prop
    ) external returns (bool);
    
    function markAsSuccess(uint256 rewardPercent) external returns (uint256 currentReward);
    function markAsFailed(uint256 slashPercent) external returns (uint256 slashedTokens);
    function extendDeadline(uint256 newDeadline) external;
    function closeDeal() external;
    function recoverDeal(address liquidator, uint256 stakedAmount) external;

    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external;
    function messageDeal(bytes4 message, bytes calldata data) external;
}