// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACCreateChildProposal is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        if (!seed.dealApproved) revert DealNotApproved();

        vm.startBroadcast(agentKey());
        seed.childCreateProposalId = _createParentChildProposal(seed.deal, _childMintAgentProposal(seed, config));
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC parent create-proposal created");
        console2.log("  label:", seed.label);
        console2.log("  childCreateProposalId:", seed.childCreateProposalId);
        console2.log("  manifest:", manifestPath);
    }
}

