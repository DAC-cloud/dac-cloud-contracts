// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ManifestIO} from "../common/ManifestIO.sol";
import {ProtocolConfig, ProtocolDeployment} from "../common/ScriptTypes.sol";
import {DACFactory} from "../../src/kernel/DACFactory.sol";
import {DACCellFactory} from "../../src/kernel/factories/DACCellFactory.sol";
import {DealCellFactory} from "../../src/kernel/factories/DealCellFactory.sol";
import {DealManagerFactory} from "../../src/kernel/factories/DealManagerFactory.sol";
import {ModuleRegistryFactory} from "../../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../../src/kernel/factories/AssetControllerFactory.sol";
import {DACManagementProposalFactory} from "../../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {NativeGovernanceSchemaFactory} from "../../src/kernel/governance/factories/NativeGovernanceSchemaFactory.sol";
import {CoreManagementProposalFactory} from "../../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../../src/kernel/tokens/factories/TokenFactories.sol";
import {DACDealFactory} from "../../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneEvaluatorFactory} from "../../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {CoreModuleFactory} from "../../src/modules/core/CoreModuleFactory.sol";

contract DeployProtocol is ManifestIO {
    function run() external returns (ProtocolDeployment memory deployment) {
        ProtocolConfig memory config = loadProtocolConfig();
        uint256 deployerKey = broadcasterKey();

        deployment.chainId = block.chainid;
        deployment.deployer = vm.addr(deployerKey);
        deployment.permit2 = config.permit2;

        vm.startBroadcast(deployerKey);
        deployment = _deployFactories(config, deployment);
        deployment.blockNumber = block.number;
        vm.stopBroadcast();

        deployment = _hydrateKernelRefs(deployment);
        deployment = _hydrateCoreRefs(deployment);

        string memory manifestPath = writeProtocolManifest(deployment);

        console2.log("Protocol deployed");
        console2.log("  chainId:", deployment.chainId);
        console2.log("  deployer:", deployment.deployer);
        console2.log("  permit2:", deployment.permit2);
        console2.log("  dacFactory:", deployment.dacFactory);
        console2.log("  manifest:", manifestPath);
    }

    function _deployFactories(
        ProtocolConfig memory config,
        ProtocolDeployment memory deployment
    ) internal returns (ProtocolDeployment memory) {
        deployment.mainTokenFactory = address(new MainTokenFactory());
        deployment.agentTokenFactory = address(new AgentTokenFactory());
        deployment.stakedAgentFactory = address(new StakedAgentFactory());
        deployment.dacCellFactory = address(new DACCellFactory());
        deployment.dealCellFactory = address(new DealCellFactory());
        deployment.dealManagerFactory = address(new DealManagerFactory());
        deployment.moduleRegistryFactory = address(new ModuleRegistryFactory());
        deployment.assetControllerFactory = address(new NativeAssetControllerFactory());
        deployment.governanceSchemaFactory = address(new NativeGovernanceSchemaFactory());
        deployment.dacGovernanceFactory = address(new DACManagementProposalFactory());
        deployment.coreDealGovernanceFactory = address(new CoreManagementProposalFactory());
        deployment.dacDealFactory = address(new DACDealFactory());
        deployment.treasuryDealFactory = address(new TreasuryDealFactory(config.permit2));
        deployment.milestoneEvaluatorFactory = address(new MilestoneEvaluatorFactory());
        deployment.revenueEvaluatorFactory = address(new RevenueEvaluatorFactory());

        deployment.coreModuleFactory = address(new CoreModuleFactory(
            deployment.dealCellFactory,
            deployment.dacDealFactory,
            deployment.stakedAgentFactory,
            deployment.treasuryDealFactory,
            deployment.milestoneEvaluatorFactory,
            deployment.revenueEvaluatorFactory
        ));

        deployment.dacFactory = address(new DACFactory(
            deployment.mainTokenFactory,
            deployment.agentTokenFactory,
            deployment.dacCellFactory,
            deployment.dealManagerFactory,
            deployment.moduleRegistryFactory,
            deployment.assetControllerFactory,
            deployment.dacGovernanceFactory,
            deployment.governanceSchemaFactory,
            deployment.coreModuleFactory
        ));

        return deployment;
    }

    function _hydrateKernelRefs(
        ProtocolDeployment memory deployment
    ) internal view returns (ProtocolDeployment memory) {
        deployment.mainTokenImpl = MainTokenFactory(deployment.mainTokenFactory).referenceImpl();
        deployment.agentTokenImpl = AgentTokenFactory(deployment.agentTokenFactory).referenceImpl();
        deployment.stakedAgentImpl = StakedAgentFactory(deployment.stakedAgentFactory).referenceImpl();
        deployment.dacCellImpl = DACCellFactory(deployment.dacCellFactory).referenceImpl();
        deployment.dealCellImpl = DealCellFactory(deployment.dealCellFactory).referenceImpl();
        deployment.dealManagerImpl = DealManagerFactory(deployment.dealManagerFactory).referenceImpl();
        deployment.moduleRegistryImpl = ModuleRegistryFactory(deployment.moduleRegistryFactory).referenceImpl();
        deployment.assetControllerImpl = NativeAssetControllerFactory(deployment.assetControllerFactory).referenceImpl();
        deployment.governanceSchemaImpl =
            NativeGovernanceSchemaFactory(deployment.governanceSchemaFactory).referenceImpl();
        deployment.dacGovernanceImpl = DACManagementProposalFactory(deployment.dacGovernanceFactory).referenceImpl();
        deployment.coreDealGovernanceImpl =
            CoreManagementProposalFactory(deployment.coreDealGovernanceFactory).referenceImpl();

        return deployment;
    }

    function _hydrateCoreRefs(
        ProtocolDeployment memory deployment
    ) internal view returns (ProtocolDeployment memory) {
        TreasuryDealFactory treasuryDealFactory = TreasuryDealFactory(deployment.treasuryDealFactory);

        deployment.dacDealImpl = DACDealFactory(deployment.dacDealFactory).referenceImpl();
        deployment.treasuryDealImpl = treasuryDealFactory.referenceImpl();
        deployment.permit2TreasuryFactory = treasuryDealFactory.permit2VaultFactory();
        deployment.milestoneEvaluatorImpl =
            MilestoneEvaluatorFactory(deployment.milestoneEvaluatorFactory).referenceImpl();
        deployment.revenueEvaluatorImpl =
            RevenueEvaluatorFactory(deployment.revenueEvaluatorFactory).referenceImpl();

        return deployment;
    }
}
