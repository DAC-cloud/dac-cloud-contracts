// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {TreasuryFlowBase} from "./TreasuryFlowBase.sol";
import {TreasuryFlowSeed, TreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";
import {Permit2Treasury} from "../../src/modules/core/deals/Permit2Treasury.sol";

contract SeedTreasuryExecuteActions is TreasuryFlowBase {
    function run() external returns (TreasuryFlowSeed memory seed) {
        TreasuryFlowSeedConfig memory config = loadTreasuryFlowSeedConfig();
        seed = loadTreasuryFlowManifest(config.label);

        vm.startBroadcast(agentKey());

        _voteAndExecuteDealProposal(seed.deal, seed.directSpendProposalId, true);
        _voteAndExecuteDealProposal(seed.deal, seed.permit2ProposalId, true);
        _voteAndExecuteDealProposal(seed.deal, seed.assignClaimerProposalId, true);
        _voteAndExecuteDealProposal(seed.deal, seed.agentSpendProposalId, true);

        seed.agentSpendExecutionAmount = config.agentSpendSingleTxAmount;
        Permit2Treasury(seed.treasury).executeAgentSpend(
            seed.treasuryToken,
            seed.recipient,
            uint160(seed.agentSpendExecutionAmount)
        );

        vm.stopBroadcast();

        seed.actionProposalsExecuted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeTreasuryFlowManifest(seed);

        console2.log("Treasury flow actions executed");
        console2.log("  label:", seed.label);
        console2.log("  treasury:", seed.treasury);
        console2.log("  agentSpendExecutionAmount:", seed.agentSpendExecutionAmount);
        console2.log("  manifest:", manifestPath);
    }
}
