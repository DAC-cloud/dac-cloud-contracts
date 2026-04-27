// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGovernanceOracle} from "./IGovernanceOracle.sol";

// Operator surface for the multisig-administered reference implementation.
// Consumers (DAC governance) only depend on IGovernanceOracle; this interface
// exists so a single oracle deployment can serve many DACs and so future
// implementations (optimistic/staked, ZK, etc.) can swap in transparently.
interface IBasicGovernanceOracle is IGovernanceOracle {
    function initialize(address admin, address initialPublisher) external;

    function setPublisher(address publisher, bool allowed) external;
    function isPublisher(address publisher) external view returns (bool);

    function deactivate(address dac) external;

    function publishSnapshot(
        address dac,
        uint256 proposalId,
        uint256 snapshotBlock,
        bytes32 merkleRoot,
        uint256 totalUnderlyingVotingPower
    ) external;
}
