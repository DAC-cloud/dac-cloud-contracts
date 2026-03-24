// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OracleSnapshot} from "./GovernanceStructs.sol";

interface IGovernanceOracle {
    function initialize(address admin, address initialPublisher) external;

    function setPublisher(address publisher, bool allowed) external;
    function isPublisher(address publisher) external view returns (bool);
    function isActive() external view returns (bool);
    function deactivate() external;

    function publishSnapshot(
        uint256 proposalId,
        uint256 snapshotBlock,
        bytes32 merkleRoot,
        uint256 totalUnderlyingVotingPower
    ) external;

    function getSnapshot(uint256 proposalId) external view returns (OracleSnapshot memory snapshot);
}
