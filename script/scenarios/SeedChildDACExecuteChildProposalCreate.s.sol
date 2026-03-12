// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACExecuteChildProposalCreate is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        if (seed.childCreateProposalId == 0) revert ChildProposalNotPrepared();

        vm.startBroadcast(agentKey());
        (seed.childProposalId, seed.childVoteProposalId) =
            _executeParentCreateChildProposal(seed.deal, seed.childCreateProposalId);
        vm.stopBroadcast();

        seed.childProposalCreated = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC parent create-proposal executed");
        console2.log("  label:", seed.label);
        console2.log("  childProposalId:", seed.childProposalId);
        console2.log("  childVoteProposalId:", seed.childVoteProposalId);
        console2.log("  manifest:", manifestPath);
    }
}

