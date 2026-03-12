// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACExecuteReturnProfitsProposal is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        config;
        seed = loadChildDACFlowManifest(config.label);

        if (seed.returnProfitProposalId == 0) revert ChildDACFlowNotPrepared();

        vm.startBroadcast(agentKey());
        _voteAndExecuteDealProposal(seed.deal, seed.returnProfitProposalId, true);
        vm.stopBroadcast();

        seed.returnProfitExecuted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC return-profits proposal executed");
        console2.log("  label:", seed.label);
        console2.log("  returnProfitProposalId:", seed.returnProfitProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
