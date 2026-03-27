// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACExecuteAgentMint is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        if (seed.mintAgentProposalId == 0) revert ChildDACFlowNotPrepared();

        vm.startBroadcast(founderKey());
        _executeParentDACProposal(seed, seed.mintAgentProposalId);
        vm.stopBroadcast();

        seed.agentMinted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC flow agent mint executed");
        console2.log("  label:", seed.label);
        console2.log("  mintAgentProposalId:", seed.mintAgentProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
