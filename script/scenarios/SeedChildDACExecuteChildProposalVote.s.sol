// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACExecuteChildProposalVote is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        if (!seed.childProposalCreated || seed.childVoteProposalId == 0 || seed.childProposalId == 0) {
            revert ChildProposalNotPrepared();
        }

        vm.startBroadcast(agentKey());
        _executeParentVoteAndChildProposal(seed, seed.childVoteProposalId, seed.childProposalId);
        vm.stopBroadcast();

        seed.childProposalExecuted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC vote proposal executed");
        console2.log("  label:", seed.label);
        console2.log("  childProposalId:", seed.childProposalId);
        console2.log("  beneficiary:", seed.beneficiary);
        console2.log("  manifest:", manifestPath);
    }
}
