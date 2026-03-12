// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACExecuteCapitalCallCreate is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        if (seed.capitalCallCreateProposalId == 0) revert CapitalCallNotPrepared();

        vm.startBroadcast(agentKey());
        (seed.capitalCallProposalId, seed.capitalCallVoteProposalId) =
            _executeParentCreateChildProposal(seed.deal, seed.capitalCallCreateProposalId);
        vm.stopBroadcast();

        seed.childCapitalCallCreated = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC capital-call parent proposal executed");
        console2.log("  label:", seed.label);
        console2.log("  capitalCallProposalId:", seed.capitalCallProposalId);
        console2.log("  capitalCallVoteProposalId:", seed.capitalCallVoteProposalId);
        console2.log("  manifest:", manifestPath);
    }
}

