// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OracleSnapshot} from "./GovernanceStructs.sol";

// Read-only consumer surface. Snapshots are namespaced per DAC so a single
// oracle instance can serve many DACs without proposalId collisions.
interface IGovernanceOracle {
    function isActive(address dac) external view returns (bool);

    function getSnapshot(address dac, uint256 proposalId)
        external
        view
        returns (OracleSnapshot memory snapshot);
}
