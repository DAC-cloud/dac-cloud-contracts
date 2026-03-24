// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealState} from "./Structs.sol";
import {IManagementProposal} from "../../interfaces/IManagementProposal.sol";

interface IDealManagerAdapter {
    function state(address dealCell) external returns (DealState memory);

    function onMainMove(address from, address to, uint256 amount) external;
    function onMainDelegate(address from, address to) external;

    function registerControlledAddress(address controlled) external;

    function legalWrapperMessage(uint256 id, bytes4 kind, bytes calldata message) external;
    function isRecoverable(uint256 id) external view returns (bool);
    
    function approveFunding(uint256 id, uint256 trancheId, uint256 rewardsLimit) external;
    function createTrancheProposal(uint256 dealId, uint256 trancheId) external;
    
    function executeProp(address msgSender, IManagementProposal prop) external;
    
    function mintMain(address deal, uint256 evaluatorId, address to, uint256 amount) external;

    function permitEvaluatorAdd(uint256 dealId, bytes memory evaluatorConfig) external;

    function onDealClosed(uint256 dealId) external;
}
