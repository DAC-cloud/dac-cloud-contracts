// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACApproveDeal is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        vm.startBroadcast(founderKey());
        _approveDeal(seed);
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC deal approved");
        console2.log("  label:", seed.label);
        console2.log("  deal:", seed.deal);
        console2.log("  childDac:", seed.childDac);
        console2.log("  childMainToken:", seed.childMainToken);
        console2.log("  childAgentToken:", seed.childAgentToken);
        console2.log("  manifest:", manifestPath);
    }
}

