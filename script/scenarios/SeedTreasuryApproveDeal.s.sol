// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {TreasuryFlowBase} from "./TreasuryFlowBase.sol";
import {TreasuryFlowSeed, TreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";

contract SeedTreasuryApproveDeal is TreasuryFlowBase {
    function run() external returns (TreasuryFlowSeed memory seed) {
        TreasuryFlowSeedConfig memory config = loadTreasuryFlowSeedConfig();
        seed = loadTreasuryFlowManifest(config.label);

        vm.startBroadcast(founderKey());
        _approveDeal(seed);
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeTreasuryFlowManifest(seed);

        console2.log("Treasury flow deal approved");
        console2.log("  label:", seed.label);
        console2.log("  deal:", seed.deal);
        console2.log("  treasury:", seed.treasury);
        console2.log("  manifest:", manifestPath);
    }
}
