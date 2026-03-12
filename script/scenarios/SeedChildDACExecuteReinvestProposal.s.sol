// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACExecuteReinvestProposal is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        config;
        seed = loadChildDACFlowManifest(config.label);

        if (seed.reinvestProposalId == 0) revert ChildDACFlowNotPrepared();

        vm.startBroadcast(agentKey());
        _voteAndExecuteDealProposal(seed.deal, seed.reinvestProposalId, true);
        vm.stopBroadcast();

        seed.reinvestExecuted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC reinvest proposal executed");
        console2.log("  label:", seed.label);
        console2.log("  reinvestProposalId:", seed.reinvestProposalId);
        console2.log("  manifest:", manifestPath);
    }
}

