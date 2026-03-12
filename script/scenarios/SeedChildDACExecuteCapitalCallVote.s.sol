// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACExecuteCapitalCallVote is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        if (!seed.childCapitalCallCreated || seed.capitalCallProposalId == 0 || seed.capitalCallVoteProposalId == 0) {
            revert CapitalCallNotPrepared();
        }

        vm.startBroadcast(agentKey());
        seed.childCapitalCallHash =
            _executeParentVoteAndChildCapitalCall(seed, seed.capitalCallVoteProposalId, seed.capitalCallProposalId);
        vm.stopBroadcast();

        seed.childCapitalCallExecuted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC capital-call vote executed");
        console2.log("  label:", seed.label);
        console2.logBytes32(seed.childCapitalCallHash);
        console2.log("  manifest:", manifestPath);
    }
}

