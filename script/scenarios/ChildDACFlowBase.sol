// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {BasicDACSeed, ChildDACFlowSeed, ChildDACFlowSeedConfig, ProtocolDeployment} from "../common/ScriptTypes.sol";
import {IDealManager} from "../../src/interfaces/IDealManager.sol";
import {IDACCell} from "../../src/interfaces/IDACCell.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {ProposalParams, DealParams, DACConfig} from "../../src/interfaces/Structs.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../../src/kernel/tokens/StakedAgent.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {CoreDealType, CoreEvaluatorType} from "../../src/modules/core/CoreModuleDeals.sol";
import {DACDeal} from "../../src/modules/core/deals/DACDeal.sol";
import {MilestoneBasedEvaluator} from "../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {DACDealConfig, Milestone} from "../../src/modules/core/interfaces/Structs.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {CoreDealManagementType} from "../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {ScenarioGovernanceBase} from "./ScenarioGovernanceBase.sol";

abstract contract ChildDACFlowBase is ScenarioGovernanceBase {
    error ChildDACFlowNotPrepared();
    error AgentMintNotExecuted();
    error DealNotApproved();
    error ChildProposalNotPrepared();
    error CapitalCallNotPrepared();
    error TokenNotMintable();

    function _initChildDACSeed(
        ChildDACFlowSeedConfig memory config
    ) internal view returns (ProtocolDeployment memory protocol, BasicDACSeed memory basic, ChildDACFlowSeed memory seed) {
        protocol = loadProtocolManifest();
        basic = loadBasicDACSeedManifest(config.basicDACLabel);

        seed.chainId = block.chainid;
        seed.label = config.label;
        seed.basicDACLabel = config.basicDACLabel;
        seed.founder = vm.addr(founderKey());
        seed.agent = vm.addr(agentKey());
        seed.beneficiary = recipientAddress();
        seed.dac = basic.dac;
        seed.mainToken = basic.mainToken;
        seed.agentToken = basic.agentToken;
        seed.treasuryToken = basic.treasuryToken;
    }

    function _createChildDACDeal(
        ChildDACFlowSeed memory seed,
        BasicDACSeed memory basic,
        ProtocolDeployment memory protocol,
        ChildDACFlowSeedConfig memory config
    ) internal returns (Vm.Log[] memory logs) {
        DealParams memory params = _childDACDealParams(seed, protocol, config);

        vm.recordLogs();
        (seed.dealId, seed.dealCell, seed.deal, seed.evaluator) = IDealManager(basic.dealManager).createDealProposal(params);
        AgentToken(seed.agentToken).stakeToDeal(seed.dealCell, config.stakeAmount);
        StakedAgent(IDealCell(seed.dealCell).stakeToken()).delegate(seed.agent);
        return vm.getRecordedLogs();
    }

    function _approveDeal(ChildDACFlowSeed memory seed) internal {
        _voteAndExecuteDACProposal(seed.dac, seed.dacProposalId, true);
        seed.dealApproved = true;
        seed.childDac = DACDeal(seed.deal).managedEntity();
        seed.childMainToken = IDACCell(seed.childDac).getMainToken();
        seed.childAgentToken = IDACCell(seed.childDac).getAgentToken();
    }

    function _createParentChildProposal(
        address deal,
        ProposalParams memory childProposal
    ) internal returns (uint256 proposalId) {
        proposalId = _createDealProposal(
            deal,
            ProposalParams({
                typ: CoreDealManagementType.CREATE_DAC_PROPOSAL,
                target: address(0),
                i: 0,
                data: abi.encode(childProposal)
            })
        );
    }

    function _executeParentCreateChildProposal(
        address deal,
        uint256 proposalId
    ) internal returns (uint256 childProposalId, uint256 childVoteProposalId) {
        vm.recordLogs();
        _voteAndExecuteDealProposal(deal, proposalId, true);
        return _findChildVoteCreated(vm.getRecordedLogs());
    }

    function _executeParentVoteAndChildProposal(
        ChildDACFlowSeed memory seed,
        uint256 voteProposalId,
        uint256 childProposalId
    ) internal {
        _voteAndExecuteDealProposal(seed.deal, voteProposalId, true);
        IDACCell(seed.childDac).executeDACProposal(childProposalId);
    }

    function _executeParentVoteAndChildCapitalCall(
        ChildDACFlowSeed memory seed,
        uint256 voteProposalId,
        uint256 childProposalId
    ) internal returns (bytes32 capitalCallHash) {
        _voteAndExecuteDealProposal(seed.deal, voteProposalId, true);
        vm.recordLogs();
        IDACCell(seed.childDac).executeDACProposal(childProposalId);
        return _findCapitalCallHash(vm.getRecordedLogs());
    }

    function _mintProfitsToDeal(address token, address deal, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", deal, amount));
        if (!ok) revert TokenNotMintable();
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

    function _findChildVoteCreated(
        Vm.Log[] memory logs
    ) internal pure returns (uint256 childProposalId, uint256 childVoteProposalId) {
        bytes32 eventSig = keccak256("ChildVoteCreated(uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                childProposalId = uint256(logs[i].topics[1]);
                childVoteProposalId = abi.decode(logs[i].data, (uint256));
                return (childProposalId, childVoteProposalId);
            }
        }

        revert("child vote event not found");
    }

    function _findCapitalCallHash(Vm.Log[] memory logs) internal pure returns (bytes32 capitalCallHash) {
        bytes32 eventSig =
            keccak256("CapitalCallCreated(uint256,address,bytes32,address,uint256,uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                return logs[i].topics[3];
            }
        }

        revert("capital call hash not found");
    }

    function _childDACDealParams(
        ChildDACFlowSeed memory seed,
        ProtocolDeployment memory protocol,
        ChildDACFlowSeedConfig memory config
    ) internal view returns (DealParams memory params) {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: seed.treasuryToken,
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: config.fundingAmount,
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

        DACConfig memory childDACConfig = DACConfig({
            symbol: "DAC-L2",
            name: "DAC L2",
            description: "Manifest-driven child DAC seed flow",
            mainTokenMaxSupply: config.childMainTokenMaxSupply,
            defaultQuorum: config.childDefaultQuorum,
            founder: seed.founder,
            founderAllocation: config.managedEquity,
            treasuryToken: seed.treasuryToken,
            founderCommitment: config.fundingAmount,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode(seed.label, seed.agent, block.chainid));

        DACDealConfig memory dacDealConfig = DACDealConfig({
            managedEquity: config.managedEquity,
            capitalCallId: 0,
            config: abi.encode(protocol.dacFactory, address(0), salt, childDACConfig)
        });

        params = DealParams({
            dealKind: CoreDealType.DAC_DEAL,
            name: "Seed Child DAC Deal",
            description: "Manifest-driven child DAC seeding flow",
            linkHash: "seed://child-dac-flow",
            moduleFactory: protocol.coreModuleFactory,
            governanceFactory: protocol.coreDealGovernanceFactory,
            dealTarget: address(0),
            proposer: seed.agent,
            vetoEnabled: false,
            fundingToken: seed.treasuryToken,
            fundingAmount: config.fundingAmount,
            rewardsLimit: config.rewardsLimit,
            approveDeadline: block.timestamp + 7 days,
            dealDeadline: block.timestamp + 30 days,
            dealConfig: abi.encode(dacDealConfig),
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            evaluatorConfig: abi.encode(evaluatorCfg)
        });
    }

    function _childMintAgentProposal(
        ChildDACFlowSeed memory seed,
        ChildDACFlowSeedConfig memory config
    ) internal pure returns (ProposalParams memory params) {
        params = ProposalParams({
            typ: DACManagementProposalType.MINT_AGENT_TOKENS,
            target: seed.beneficiary,
            i: bytes32(config.childMintAgentAmount),
            data: bytes("")
        });
    }

    function _childCapitalCallProposal(
        ChildDACFlowSeed memory seed,
        ChildDACFlowSeedConfig memory config
    ) internal pure returns (ProposalParams memory params) {
        params = ProposalParams({
            typ: DACManagementProposalType.CAPITAL_CALL,
            target: seed.deal,
            i: bytes32(config.childCapitalCallTokenAmount),
            data: abi.encode(seed.treasuryToken, config.childCapitalCallCashAmount)
        });
    }
}
