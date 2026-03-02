// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams, VotingConfig, ProposalParams} from "./Structs.sol";

interface IDeal {
    function getProposal(uint256 proposalId) external view returns (address);

    function createStakedAgentProposal(ProposalParams calldata params) external returns (uint256 proposalId);

    function beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external;

    function afterInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external;

    function onVoluntaryStake(address staker, uint256 amount) external;
    function beforeEveryStake(address staker, uint256 amount) external;
    function afterEveryStake(address staker, uint256 amount) external;
    function beforeApproveFunding(uint256 trancheId) external;
    function afterApproveFunding(uint256 trancheId) external;
    function onInvite(address invitee, bool grantInviteRight) external;
    function onUnstake(address staker, uint256 amount) external;

    function beforeWithdrawCapital() external;
    function afterWithdrawCapital() external;

    function onMarkAsSuccess(uint256 rewardPercent) external;
    function onMarkAsFailed(uint256 slashPercent) external;
    function onExtendDeadline(uint256 oldDeadline, uint256 newDeadline) external;
    function beforeClose() external;

    function afterRecovery(address liquidator, uint256 liquidatorStake) external;
    function beforeRecovery(address liquidator, uint256 liquidatorStake) external;

    function beforeClaimMainToken(address grantee, uint256 amount) external;
    function afterClaimMainToken(address grantee, uint256 amount) external;

    function onMessageDeal(bytes4 messageKind, bytes calldata message) external returns (bool);
    function onLegalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external;
}
