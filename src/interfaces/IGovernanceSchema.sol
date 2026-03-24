// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams, VotingConfig} from "./Structs.sol";
import {DealCreationConfig, GovernanceStrategyConfig} from "./GovernanceStructs.sol";

interface IGovernanceSchema {
    function createProposal(
        address creator,
        ProposalParams calldata params,
        uint256 totalVotingSupply,
        bool dividendsEnabled
    ) external returns (uint256 id, address proposal);

    function consumeApprovedProposal(uint256 id, bool requiredOutcome) external returns (address proposal);

    function setVotingConfig(VotingConfig calldata config) external;
    function setDealCreationConfig(DealCreationConfig calldata config) external;
    function setStrategyConfig(GovernanceStrategyConfig calldata config) external;
    function setGovernanceOracle(address oracle) external;

    function getVotingConfig() external view returns (VotingConfig memory config);
    function getDealCreationConfig() external view returns (DealCreationConfig memory config);
    function getStrategyConfig() external view returns (GovernanceStrategyConfig memory config);
    function getGovernanceOracle() external view returns (address oracle);
    function getProposal(uint256 id) external view returns (address proposal);
}
