// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    ExistingDACSeed,
    ExistingTreasuryFlowSeed,
    ExistingTreasuryFlowSeedConfig,
    ProtocolDeployment
} from "../common/ScriptTypes.sol";
import {IDealManager} from "../../src/interfaces/IDealManager.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {DealParams} from "../../src/interfaces/Structs.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../../src/kernel/tokens/StakedAgent.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {CoreDealType, CoreEvaluatorType} from "../../src/modules/core/CoreModuleDeals.sol";
import {TreasuryDeal} from "../../src/modules/core/deals/TreasuryDeal.sol";
import {MilestoneBasedEvaluator} from "../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {Milestone} from "../../src/modules/core/interfaces/Structs.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

abstract contract ExistingTreasuryFlowBase is ExistingGovernanceFlowBase {
    error ExistingTreasuryFlowNotPrepared();
    error ExistingTreasuryAgentMintNotExecuted();

    function _initExistingTreasurySeed(ExistingTreasuryFlowSeedConfig memory config)
        internal
        view
        returns (ProtocolDeployment memory protocol, ExistingDACSeed memory existing, ExistingTreasuryFlowSeed memory seed)
    {
        protocol = loadProtocolManifest();
        existing = loadExistingDACSeedManifest(config.existingDACLabel);

        seed.chainId = block.chainid;
        seed.label = config.label;
        seed.existingDACLabel = config.existingDACLabel;
        seed.founder = vm.addr(founderKey());
        seed.agent = vm.addr(agentKey());
        seed.recipient = recipientAddress();
        seed.dac = existing.dac;
        seed.mainToken = existing.mainToken;
        seed.agentToken = existing.agentToken;
        seed.underlyingToken = existing.underlyingToken;
        seed.governanceOracle = existing.governanceOracle;
    }

    function _createTreasuryDeal(
        ExistingTreasuryFlowSeed memory seed,
        ExistingDACSeed memory existing,
        ProtocolDeployment memory protocol,
        ExistingTreasuryFlowSeedConfig memory config
    ) internal returns (Vm.Log[] memory logs) {
        DealParams memory params = _treasuryDealParams(seed, protocol, config);

        vm.recordLogs();
        (seed.dealId, seed.dealCell, seed.deal, seed.evaluator) = IDealManager(existing.dealManager).createDealProposal(params);
        AgentToken(seed.agentToken).stakeToDeal(seed.dealCell, config.stakeAmount);
        StakedAgent(IDealCell(seed.dealCell).stakeToken()).delegate(seed.agent);
        return vm.getRecordedLogs();
    }

    function _resolveMerkleAmountForExistingTreasury(
        ExistingTreasuryFlowSeed memory seed,
        ExistingTreasuryFlowSeedConfig memory config
    ) internal view returns (uint256 amount) {
        amount = config.merkleAmountOverride;
        if (amount == 0) {
            amount = IERC20(seed.underlyingToken).balanceOf(seed.founder);
        }
        if (amount == 0) revert ZeroUnderlyingVotingPower();
    }

    function _approveDeal(ExistingTreasuryFlowSeed memory seed) internal {
        _executeDACProposal(seed.dac, seed.dacProposalId);
        seed.treasury = TreasuryDeal(seed.deal).managedEntity();
        seed.dealApproved = true;
    }

    function _findDealCreatedProposalId(Vm.Log[] memory logs) internal pure returns (uint256 proposalId) {
        bytes32 eventSig = keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                return uint256(logs[i].topics[3]);
            }
        }

        revert("deal proposal id not found");
    }

    function _treasuryDealParams(
        ExistingTreasuryFlowSeed memory seed,
        ProtocolDeployment memory protocol,
        ExistingTreasuryFlowSeedConfig memory config
    ) internal view returns (DealParams memory params) {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: seed.mainToken,
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: config.expectedReturn,
            timestamp: block.timestamp + 7 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = int256(1e18);
        milestones[0].penaltyCurve[0] = int256(1e18);

        MilestoneBasedEvaluator.Config memory evaluatorCfg =
            MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones);

        params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Existing Treasury Deal",
            description: "Hybrid-governed treasury seeding flow",
            linkHash: "seed://existing-treasury-flow",
            moduleFactory: protocol.coreModuleFactory,
            governanceFactory: protocol.coreDealGovernanceFactory,
            dealTarget: address(0),
            proposer: seed.agent,
            vetoEnabled: false,
            fundingToken: seed.mainToken,
            fundingAmount: config.fundingAmount,
            rewardsLimit: config.rewardsLimit,
            approveDeadline: block.timestamp + 7 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            dealConfig: abi.encode("existing treasury config"),
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            evaluatorConfig: abi.encode(evaluatorCfg)
        });
    }
}
