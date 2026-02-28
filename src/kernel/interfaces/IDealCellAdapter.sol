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

    function withdrawCapital() external;
    
    function toggleEarlyReturns(bool earlyReturns) external;
    function toggleWhitelist(bool whitelistOnly) external;
    function enableVeto() external;

    function addStake(address staker, uint256 amount) external;
}