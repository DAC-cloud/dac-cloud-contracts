// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingTreasuryFlowBase} from "./ExistingTreasuryFlowBase.sol";
import {ExistingTreasuryFlowSeed, ExistingTreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";

contract SeedExistingTreasuryApproveDeal is ExistingTreasuryFlowBase {
    function run() external returns (ExistingTreasuryFlowSeed memory seed) {
        ExistingTreasuryFlowSeedConfig memory config = loadExistingTreasuryFlowSeedConfig();
        seed = loadExistingTreasuryFlowManifest(config.label);

        if (!seed.dealApprovalPublished) revert ExistingTreasuryFlowNotPrepared();

        bytes32[] memory proof = new bytes32[](0);

        vm.startBroadcast(founderKey());
        _voteDACProposal(seed.dac, seed.dacProposalId, true);
        _voteDACProposalMerkle(
            seed.dac, seed.dacProposalId, true, config.merkleIndex, seed.approveDealUnderlyingAmount, proof
        );
        _approveDeal(seed);
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeExistingTreasuryFlowManifest(seed);

        console2.log("Existing treasury flow deal approved");
        console2.log("  label:", seed.label);
        console2.log("  deal:", seed.deal);
        console2.log("  treasury:", seed.treasury);
        console2.log("  manifest:", manifestPath);
    }
}
