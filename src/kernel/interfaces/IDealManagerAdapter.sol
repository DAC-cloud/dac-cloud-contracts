// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealState} from "./Structs.sol";
import {DACManagementProposal} from "../governance/DACManagementProposal.sol";

interface IDealManagerAdapter {
    function state(address dealCell) external returns (DealState memory);

    function onMainMove(address from, address to, uint256 amount) external;
    function onMainDelegate(address from, address to) external;

    function registerControlledAddress(address controlled) external;

    function legalWrapperMessage(uint256 id, bytes4 kind, bytes calldata message) external;
    function isRecoverable(uint256 id) external view returns (bool);
    function approveFunding(uint256 id, uint256 trancheId, uint256 rewardsLimit) external;
    function executeProp(address msgSender, DACManagementProposal prop) external;
    function mintMain(address deal, address to, uint256 amount) external;
    function createTrancheProposal(uint256 dealId, uint256 trancheId) external;
}