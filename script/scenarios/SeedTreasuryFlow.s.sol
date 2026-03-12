// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {BasicDACSeed, ProtocolDeployment, TreasuryFlowSeed, TreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ProposalParams} from "../../src/interfaces/Structs.sol";
import {CoreDealManagementType} from "../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {TreasurySpendAllowance} from "../../src/modules/core/interfaces/Structs.sol";
import {TreasuryFlowBase} from "./TreasuryFlowBase.sol";

contract SeedTreasuryFlow is TreasuryFlowBase {
    function run() external returns (TreasuryFlowSeed memory seed) {
        ProtocolDeployment memory protocol = loadProtocolManifest();
        TreasuryFlowSeedConfig memory config = loadTreasuryFlowSeedConfig();
        BasicDACSeed memory basic = loadBasicDACSeedManifest(config.basicDACLabel);

        uint256 founderPk = founderKey();
        uint256 agentPk = agentKey();

        seed.chainId = block.chainid;
        seed.label = config.label;
        seed.basicDACLabel = config.basicDACLabel;
        seed.founder = vm.addr(founderPk);
        seed.agent = vm.addr(agentPk);
        seed.recipient = recipientAddress();
        seed.dac = basic.dac;
        seed.mainToken = basic.mainToken;
        seed.agentToken = basic.agentToken;
        seed.treasuryToken = basic.treasuryToken;

        vm.startBroadcast(founderPk);
        _voteAndExecuteDACProposal(
            seed.dac,
            _createMintAgentProposal(seed.dac, seed.agent, config.agentMintAmount),
            true
        );
        vm.stopBroadcast();
        _createAndApproveTreasuryDeal(seed, basic, protocol, config, agentPk, founderPk);

        _runTreasuryActions(seed, config, agentPk);

        seed.blockNumber = block.number;

        string memory manifestPath = writeTreasuryFlowManifest(seed);

        console2.log("Treasury flow seeded");
        console2.log("  label:", seed.label);
        console2.log("  dealId:", seed.dealId);
        console2.log("  deal:", seed.deal);
        console2.log("  treasury:", seed.treasury);
        console2.log("  agent:", seed.agent);
        console2.log("  recipient:", seed.recipient);
        console2.log("  manifest:", manifestPath);
    }

    function _createAndApproveTreasuryDeal(
        TreasuryFlowSeed memory seed,
        BasicDACSeed memory basic,
        ProtocolDeployment memory protocol,
        TreasuryFlowSeedConfig memory config,
        uint256 agentPk,
        uint256 founderPk
    ) internal {
        vm.startBroadcast(agentPk);
        Vm.Log[] memory logs = _createTreasuryDeal(seed, basic, protocol, config);
        vm.stopBroadcast();

        seed.dacProposalId = _findDealCreatedProposalId(logs);

        vm.startBroadcast(founderPk);
        _approveDeal(seed);
        vm.stopBroadcast();
    }

    function _runTreasuryActions(
        TreasuryFlowSeed memory seed,
        TreasuryFlowSeedConfig memory config,
        uint256 agentPk
    ) internal {
        vm.startBroadcast(agentPk);

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

        seed.directSpendProposalId = _voteAndReturnDealProposal(seed.deal, seed.directSpendProposalId);
        seed.permit2ProposalId = _voteAndReturnDealProposal(seed.deal, seed.permit2ProposalId);
        seed.assignClaimerProposalId = _voteAndReturnDealProposal(seed.deal, seed.assignClaimerProposalId);
        seed.agentSpendProposalId = _voteAndReturnDealProposal(seed.deal, seed.agentSpendProposalId);

        vm.stopBroadcast();
    }

    function _voteAndReturnDealProposal(address deal, uint256 proposalId) internal returns (uint256) {
        _voteAndExecuteDealProposal(deal, proposalId, true);
        return proposalId;
    }
}
