// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams, VotingConfig} from "./Structs.sol";

interface IModuleFactory {
    function isActive() external view returns (bool);
    function safetyCheck(address deal) external view returns (bool);

    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address manager,
        VotingConfig calldata votingConfig
    ) external returns (address dealCell, address dealAddr, address evaluatorAddr);

    function deployEvaluator(
        address dac,
        uint256 id,
        address dealCell,
        DealParams calldata params,
        bytes4 evaluatorSelector,
        bytes calldata evaluatorConfig
    ) external returns (address evaluatorAddr);
}
