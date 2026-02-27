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
        address mpToken,
        address lpToken,
        VotingConfig calldata votingConfig
    ) external returns (address dealCell, address dealAddr, address evaluatorAddr);
}
