// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {TreasuryFlowBase} from "./TreasuryFlowBase.sol";
import {TreasuryFlowSeed, TreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ProposalParams} from "../../src/interfaces/Structs.sol";
import {CoreDealManagementType} from "../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {TreasurySpendAllowance} from "../../src/modules/core/interfaces/Structs.sol";

contract SeedTreasuryCreateActions is TreasuryFlowBase {
    function run() external returns (TreasuryFlowSeed memory seed) {
        TreasuryFlowSeedConfig memory config = loadTreasuryFlowSeedConfig();
        seed = loadTreasuryFlowManifest(config.label);

        vm.startBroadcast(agentKey());

        seed.directSpendProposalId = _createDealProposal(
            seed.deal,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_DIRECT_SPEND,
                target: seed.treasuryToken,
                i: 0,
                data: abi.encode(seed.recipient, uint160(config.directSpendAmount))
            })
        );

        seed.permit2ProposalId = _createDealProposal(
            seed.deal,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
                target: seed.treasuryToken,
                i: 0,
                data: abi.encode(seed.recipient, config.permit2SpendAmount, uint48(block.timestamp + 7 days))
            })
        );

        seed.assignClaimerProposalId = _createDealProposal(
            seed.deal,
            ProposalParams({
                typ: CoreDealManagementType.ASSIGN_CLAIMER,
                target: seed.agent,
                i: 0,
                data: abi.encode(seed.treasuryToken, seed.recipient, uint160(config.assignClaimAmount))
            })
        );

        TreasurySpendAllowance memory allowance = TreasurySpendAllowance({
            totalAmount: config.agentSpendTotalAmount,
            singleTxAmount: config.agentSpendSingleTxAmount,
            clockLimit: 0,
            duration: config.agentSpendDuration
        });

        seed.agentSpendProposalId = _createDealProposal(
            seed.deal,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_AGENT_SPEND,
                target: seed.treasuryToken,
                i: 0,
                data: abi.encode(seed.agent, seed.recipient, allowance)
            })
        );

        vm.stopBroadcast();

        seed.actionProposalsCreated = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeTreasuryFlowManifest(seed);

        console2.log("Treasury flow action proposals created");
        console2.log("  label:", seed.label);
        console2.log("  directSpendProposalId:", seed.directSpendProposalId);
        console2.log("  permit2ProposalId:", seed.permit2ProposalId);
        console2.log("  assignClaimerProposalId:", seed.assignClaimerProposalId);
        console2.log("  agentSpendProposalId:", seed.agentSpendProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
