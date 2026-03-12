// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {stdJson} from "forge-std/StdJson.sol";
import {ScriptConfig} from "./ScriptConfig.sol";
import {BasicDACSeed, ProtocolDeployment, TreasuryFlowSeed} from "./ScriptTypes.sol";

abstract contract ManifestIO is ScriptConfig {
    using stdJson for string;

    function writeProtocolManifest(ProtocolDeployment memory deployment) internal returns (string memory path) {
        string memory root = "protocol";

        vm.createDir(deploymentsRoot(), true);
        vm.createDir(chainDeploymentsRoot(), true);

        vm.serializeUint(root, "chainId", deployment.chainId);
        vm.serializeUint(root, "blockNumber", deployment.blockNumber);
        vm.serializeAddress(root, "deployer", deployment.deployer);
        vm.serializeAddress(root, "permit2", deployment.permit2);
        vm.serializeAddress(root, "mainTokenFactory", deployment.mainTokenFactory);
        vm.serializeAddress(root, "mainTokenImpl", deployment.mainTokenImpl);
        vm.serializeAddress(root, "agentTokenFactory", deployment.agentTokenFactory);
        vm.serializeAddress(root, "agentTokenImpl", deployment.agentTokenImpl);
        vm.serializeAddress(root, "stakedAgentFactory", deployment.stakedAgentFactory);
        vm.serializeAddress(root, "stakedAgentImpl", deployment.stakedAgentImpl);
        vm.serializeAddress(root, "dacCellFactory", deployment.dacCellFactory);
        vm.serializeAddress(root, "dacCellImpl", deployment.dacCellImpl);
        vm.serializeAddress(root, "dealCellFactory", deployment.dealCellFactory);
        vm.serializeAddress(root, "dealCellImpl", deployment.dealCellImpl);
        vm.serializeAddress(root, "dealManagerFactory", deployment.dealManagerFactory);
        vm.serializeAddress(root, "dealManagerImpl", deployment.dealManagerImpl);
        vm.serializeAddress(root, "dacGovernanceFactory", deployment.dacGovernanceFactory);
        vm.serializeAddress(root, "dacGovernanceImpl", deployment.dacGovernanceImpl);
        vm.serializeAddress(root, "coreDealGovernanceFactory", deployment.coreDealGovernanceFactory);
        vm.serializeAddress(root, "coreDealGovernanceImpl", deployment.coreDealGovernanceImpl);
        vm.serializeAddress(root, "dacDealFactory", deployment.dacDealFactory);
        vm.serializeAddress(root, "dacDealImpl", deployment.dacDealImpl);
        vm.serializeAddress(root, "treasuryDealFactory", deployment.treasuryDealFactory);
        vm.serializeAddress(root, "treasuryDealImpl", deployment.treasuryDealImpl);
        vm.serializeAddress(root, "permit2TreasuryFactory", deployment.permit2TreasuryFactory);
        vm.serializeAddress(root, "milestoneEvaluatorFactory", deployment.milestoneEvaluatorFactory);
        vm.serializeAddress(root, "milestoneEvaluatorImpl", deployment.milestoneEvaluatorImpl);
        vm.serializeAddress(root, "revenueEvaluatorFactory", deployment.revenueEvaluatorFactory);
        vm.serializeAddress(root, "revenueEvaluatorImpl", deployment.revenueEvaluatorImpl);
        vm.serializeAddress(root, "coreModuleFactory", deployment.coreModuleFactory);
        string memory json = vm.serializeAddress(root, "dacFactory", deployment.dacFactory);

        path = protocolManifestPath();
        vm.writeJson(json, path);
    }

    function loadProtocolManifest() internal view returns (ProtocolDeployment memory deployment) {
        string memory json = vm.readFile(protocolManifestPath());

        deployment.chainId = json.readUint(".chainId");
        deployment.blockNumber = json.readUint(".blockNumber");
        deployment.deployer = json.readAddress(".deployer");
        deployment.permit2 = json.readAddress(".permit2");
        deployment.mainTokenFactory = json.readAddress(".mainTokenFactory");
        deployment.mainTokenImpl = json.readAddress(".mainTokenImpl");
        deployment.agentTokenFactory = json.readAddress(".agentTokenFactory");
        deployment.agentTokenImpl = json.readAddress(".agentTokenImpl");
        deployment.stakedAgentFactory = json.readAddress(".stakedAgentFactory");
        deployment.stakedAgentImpl = json.readAddress(".stakedAgentImpl");
        deployment.dacCellFactory = json.readAddress(".dacCellFactory");
        deployment.dacCellImpl = json.readAddress(".dacCellImpl");
        deployment.dealCellFactory = json.readAddress(".dealCellFactory");
        deployment.dealCellImpl = json.readAddress(".dealCellImpl");
        deployment.dealManagerFactory = json.readAddress(".dealManagerFactory");
        deployment.dealManagerImpl = json.readAddress(".dealManagerImpl");
        deployment.dacGovernanceFactory = json.readAddress(".dacGovernanceFactory");
        deployment.dacGovernanceImpl = json.readAddress(".dacGovernanceImpl");
        deployment.coreDealGovernanceFactory = json.readAddress(".coreDealGovernanceFactory");
        deployment.coreDealGovernanceImpl = json.readAddress(".coreDealGovernanceImpl");
        deployment.dacDealFactory = json.readAddress(".dacDealFactory");
        deployment.dacDealImpl = json.readAddress(".dacDealImpl");
        deployment.treasuryDealFactory = json.readAddress(".treasuryDealFactory");
        deployment.treasuryDealImpl = json.readAddress(".treasuryDealImpl");
        deployment.permit2TreasuryFactory = json.readAddress(".permit2TreasuryFactory");
        deployment.milestoneEvaluatorFactory = json.readAddress(".milestoneEvaluatorFactory");
        deployment.milestoneEvaluatorImpl = json.readAddress(".milestoneEvaluatorImpl");
        deployment.revenueEvaluatorFactory = json.readAddress(".revenueEvaluatorFactory");
        deployment.revenueEvaluatorImpl = json.readAddress(".revenueEvaluatorImpl");
        deployment.coreModuleFactory = json.readAddress(".coreModuleFactory");
        deployment.dacFactory = json.readAddress(".dacFactory");
    }

    function writeBasicDACSeedManifest(BasicDACSeed memory seed) internal returns (string memory path) {
        string memory root = "basicDac";

        vm.createDir(deploymentsRoot(), true);
        vm.createDir(chainDeploymentsRoot(), true);

        vm.serializeUint(root, "chainId", seed.chainId);
        vm.serializeUint(root, "blockNumber", seed.blockNumber);
        vm.serializeString(root, "label", seed.label);
        vm.serializeAddress(root, "broadcaster", seed.broadcaster);
        vm.serializeAddress(root, "dacFactory", seed.dacFactory);
        vm.serializeAddress(root, "founder", seed.founder);
        vm.serializeAddress(root, "dac", seed.dac);
        vm.serializeAddress(root, "mainToken", seed.mainToken);
        vm.serializeAddress(root, "agentToken", seed.agentToken);
        vm.serializeAddress(root, "dealManager", seed.dealManager);
        vm.serializeAddress(root, "treasuryToken", seed.treasuryToken);
        vm.serializeUint(root, "founderAllocation", seed.founderAllocation);
        vm.serializeUint(root, "founderCommitment", seed.founderCommitment);
        vm.serializeBool(root, "dividendsEnabled", seed.dividendsEnabled);
        string memory json = vm.serializeBool(root, "usedMockTreasuryToken", seed.usedMockTreasuryToken);

        path = basicDACSeedManifestPath(seed.label);
        vm.writeJson(json, path);
    }

    function loadBasicDACSeedManifest(string memory label) internal view returns (BasicDACSeed memory seed) {
        string memory json = vm.readFile(basicDACSeedManifestPath(label));

        seed.chainId = json.readUint(".chainId");
        seed.blockNumber = json.readUint(".blockNumber");
        seed.label = json.readString(".label");
        seed.broadcaster = json.readAddress(".broadcaster");
        seed.dacFactory = json.readAddress(".dacFactory");
        seed.founder = json.readAddress(".founder");
        seed.dac = json.readAddress(".dac");
        seed.mainToken = json.readAddress(".mainToken");
        seed.agentToken = json.readAddress(".agentToken");
        seed.dealManager = json.readAddress(".dealManager");
        seed.treasuryToken = json.readAddress(".treasuryToken");
        seed.founderAllocation = json.readUint(".founderAllocation");
        seed.founderCommitment = json.readUint(".founderCommitment");
        seed.dividendsEnabled = json.readBool(".dividendsEnabled");
        seed.usedMockTreasuryToken = json.readBool(".usedMockTreasuryToken");
    }

    function writeTreasuryFlowManifest(TreasuryFlowSeed memory seed) internal returns (string memory path) {
        string memory root = "treasuryFlow";

        vm.createDir(deploymentsRoot(), true);
        vm.createDir(chainDeploymentsRoot(), true);

        vm.serializeUint(root, "chainId", seed.chainId);
        vm.serializeUint(root, "blockNumber", seed.blockNumber);
        vm.serializeString(root, "label", seed.label);
        vm.serializeString(root, "basicDACLabel", seed.basicDACLabel);
        vm.serializeAddress(root, "founder", seed.founder);
        vm.serializeAddress(root, "agent", seed.agent);
        vm.serializeAddress(root, "recipient", seed.recipient);
        vm.serializeAddress(root, "dac", seed.dac);
        vm.serializeAddress(root, "mainToken", seed.mainToken);
        vm.serializeAddress(root, "agentToken", seed.agentToken);
        vm.serializeAddress(root, "treasuryToken", seed.treasuryToken);
        vm.serializeUint(root, "dealId", seed.dealId);
        vm.serializeAddress(root, "dealCell", seed.dealCell);
        vm.serializeAddress(root, "deal", seed.deal);
        vm.serializeAddress(root, "treasury", seed.treasury);
        vm.serializeAddress(root, "evaluator", seed.evaluator);
        vm.serializeUint(root, "dacProposalId", seed.dacProposalId);
        vm.serializeUint(root, "mintAgentProposalId", seed.mintAgentProposalId);
        vm.serializeUint(root, "directSpendProposalId", seed.directSpendProposalId);
        vm.serializeUint(root, "permit2ProposalId", seed.permit2ProposalId);
        vm.serializeUint(root, "assignClaimerProposalId", seed.assignClaimerProposalId);
        vm.serializeUint(root, "agentSpendProposalId", seed.agentSpendProposalId);
        vm.serializeUint(root, "agentSpendExecutionAmount", seed.agentSpendExecutionAmount);
        vm.serializeBool(root, "agentMinted", seed.agentMinted);
        vm.serializeBool(root, "dealApproved", seed.dealApproved);
        vm.serializeBool(root, "actionProposalsCreated", seed.actionProposalsCreated);
        string memory json = vm.serializeBool(root, "actionProposalsExecuted", seed.actionProposalsExecuted);

        path = treasuryFlowManifestPath(seed.label);
        vm.writeJson(json, path);
    }

    function loadTreasuryFlowManifest(string memory label) internal view returns (TreasuryFlowSeed memory seed) {
        string memory json = vm.readFile(treasuryFlowManifestPath(label));

        seed.chainId = json.readUint(".chainId");
        seed.blockNumber = json.readUint(".blockNumber");
        seed.label = json.readString(".label");
        seed.basicDACLabel = json.readString(".basicDACLabel");
        seed.founder = json.readAddress(".founder");
        seed.agent = json.readAddress(".agent");
        seed.recipient = json.readAddress(".recipient");
        seed.dac = json.readAddress(".dac");
        seed.mainToken = json.readAddress(".mainToken");
        seed.agentToken = json.readAddress(".agentToken");
        seed.treasuryToken = json.readAddress(".treasuryToken");
        seed.dealId = json.readUint(".dealId");
        seed.dealCell = json.readAddress(".dealCell");
        seed.deal = json.readAddress(".deal");
        seed.treasury = json.readAddress(".treasury");
        seed.evaluator = json.readAddress(".evaluator");
        seed.dacProposalId = json.readUint(".dacProposalId");
        seed.mintAgentProposalId = json.readUint(".mintAgentProposalId");
        seed.directSpendProposalId = json.readUint(".directSpendProposalId");
        seed.permit2ProposalId = json.readUint(".permit2ProposalId");
        seed.assignClaimerProposalId = json.readUint(".assignClaimerProposalId");
        seed.agentSpendProposalId = json.readUint(".agentSpendProposalId");
        seed.agentSpendExecutionAmount = json.readUint(".agentSpendExecutionAmount");
        seed.agentMinted = json.readBool(".agentMinted");
        seed.dealApproved = json.readBool(".dealApproved");
        seed.actionProposalsCreated = json.readBool(".actionProposalsCreated");
        seed.actionProposalsExecuted = json.readBool(".actionProposalsExecuted");
    }
}
