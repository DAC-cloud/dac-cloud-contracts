// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ManifestIO} from "../common/ManifestIO.sol";
import {ProtocolDeployment} from "../common/ScriptTypes.sol";
import {DACFactory} from "../../src/kernel/DACFactory.sol";
import {DACCellFactory} from "../../src/kernel/factories/DACCellFactory.sol";
import {DealManagerFactory} from "../../src/kernel/factories/DealManagerFactory.sol";
import {ModuleRegistryFactory} from "../../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../../src/kernel/factories/AssetControllerFactory.sol";
import {ExistingTokenAssetControllerFactory} from "../../src/kernel/factories/ExistingTokenAssetControllerFactory.sol";
import {DACManagementProposalFactory} from "../../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {NativeGovernanceSchemaFactory} from "../../src/kernel/governance/factories/NativeGovernanceSchemaFactory.sol";
import {HybridGovernanceSchemaFactory} from "../../src/kernel/governance/factories/HybridGovernanceSchemaFactory.sol";
import {GovernanceOracleFactory} from "../../src/kernel/governance/factories/GovernanceOracleFactory.sol";
import {HybridDACManagementProposalFactory} from "../../src/kernel/governance/factories/HybridDACManagementProposalFactory.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../../src/kernel/tokens/factories/TokenFactories.sol";
import {WrappedMainTokenFactory} from "../../src/kernel/tokens/factories/WrappedMainTokenFactory.sol";
import {CoreModuleFactory} from "../../src/modules/core/CoreModuleFactory.sol";
import {TreasuryDealFactory} from "../../src/modules/core/deals/factories/TreasuryDealFactory.sol";

contract SmokeCheckProtocol is ManifestIO {
    error ZeroAddress(string field);
    error UnexpectedPointer(string field, address actual, address expected);

    function run() external view returns (ProtocolDeployment memory deployment) {
        deployment = loadProtocolManifest();

        _requireNonZero("dacFactory", deployment.dacFactory);
        _requireNonZero("coreModuleFactory", deployment.coreModuleFactory);
        _requireNonZero("permit2", deployment.permit2);
        _requireNonZero("permit2TreasuryFactory", deployment.permit2TreasuryFactory);

        _expect(
            "DACFactory.mainTokenFactory",
            DACFactory(deployment.dacFactory).mainTokenFactory(),
            deployment.mainTokenFactory
        );
        _expect(
            "DACFactory.agentTokenFactory",
            DACFactory(deployment.dacFactory).agentTokenFactory(),
            deployment.agentTokenFactory
        );
        _expect(
            "DACFactory.cellFactory",
            DACFactory(deployment.dacFactory).cellFactory(),
            deployment.dacCellFactory
        );
        _expect(
            "DACFactory.managerFactory",
            DACFactory(deployment.dacFactory).managerFactory(),
            deployment.dealManagerFactory
        );
        _expect(
            "DACFactory.moduleRegistryFactory",
            DACFactory(deployment.dacFactory).moduleRegistryFactory(),
            deployment.moduleRegistryFactory
        );
        _expect(
            "DACFactory.assetControllerFactory",
            DACFactory(deployment.dacFactory).assetControllerFactory(),
            deployment.assetControllerFactory
        );
        _expect(
            "DACFactory.governanceSchemaFactory",
            DACFactory(deployment.dacFactory).governanceSchemaFactory(),
            deployment.governanceSchemaFactory
        );
        _expect(
            "DACFactory.existingAssetControllerFactory",
            DACFactory(deployment.dacFactory).existingAssetControllerFactory(),
            deployment.existingAssetControllerFactory
        );
        _expect(
            "DACFactory.hybridProposalFactory",
            DACFactory(deployment.dacFactory).hybridProposalFactory(),
            deployment.hybridProposalFactory
        );
        _expect(
            "DACFactory.hybridGovernanceSchemaFactory",
            DACFactory(deployment.dacFactory).hybridGovernanceSchemaFactory(),
            deployment.hybridGovernanceSchemaFactory
        );
        _expect(
            "DACFactory.wrappedMainTokenFactory",
            DACFactory(deployment.dacFactory).wrappedMainTokenFactory(),
            deployment.wrappedMainTokenFactory
        );
        _expect(
            "DACFactory.governanceOracleFactory",
            DACFactory(deployment.dacFactory).governanceOracleFactory(),
            deployment.governanceOracleFactory
        );
        _expect(
            "DACFactory.governanceFactory",
            DACFactory(deployment.dacFactory).governanceFactory(),
            deployment.dacGovernanceFactory
        );
        _expect(
            "DACFactory.coreModuleFactory",
            DACFactory(deployment.dacFactory).coreModuleFactory(),
            deployment.coreModuleFactory
        );

        _expect(
            "MainTokenFactory.referenceImpl",
            MainTokenFactory(deployment.mainTokenFactory).referenceImpl(),
            deployment.mainTokenImpl
        );
        _expect(
            "AgentTokenFactory.referenceImpl",
            AgentTokenFactory(deployment.agentTokenFactory).referenceImpl(),
            deployment.agentTokenImpl
        );
        _expect(
            "StakedAgentFactory.referenceImpl",
            StakedAgentFactory(deployment.stakedAgentFactory).referenceImpl(),
            deployment.stakedAgentImpl
        );
        _expect(
            "DACCellFactory.referenceImpl",
            DACCellFactory(deployment.dacCellFactory).referenceImpl(),
            deployment.dacCellImpl
        );
        _expect(
            "DealManagerFactory.referenceImpl",
            DealManagerFactory(deployment.dealManagerFactory).referenceImpl(),
            deployment.dealManagerImpl
        );
        _expect(
            "ModuleRegistryFactory.referenceImpl",
            ModuleRegistryFactory(deployment.moduleRegistryFactory).referenceImpl(),
            deployment.moduleRegistryImpl
        );
        _expect(
            "NativeAssetControllerFactory.referenceImpl",
            NativeAssetControllerFactory(deployment.assetControllerFactory).referenceImpl(),
            deployment.assetControllerImpl
        );
        _expect(
            "ExistingTokenAssetControllerFactory.referenceImpl",
            ExistingTokenAssetControllerFactory(deployment.existingAssetControllerFactory).referenceImpl(),
            deployment.existingAssetControllerImpl
        );
        _expect(
            "NativeGovernanceSchemaFactory.referenceImpl",
            NativeGovernanceSchemaFactory(deployment.governanceSchemaFactory).referenceImpl(),
            deployment.governanceSchemaImpl
        );
        _expect(
            "HybridGovernanceSchemaFactory.referenceImpl",
            HybridGovernanceSchemaFactory(deployment.hybridGovernanceSchemaFactory).referenceImpl(),
            deployment.hybridGovernanceSchemaImpl
        );
        _expect(
            "DACManagementProposalFactory.referenceImpl",
            DACManagementProposalFactory(deployment.dacGovernanceFactory).referenceImpl(),
            deployment.dacGovernanceImpl
        );
        _expect(
            "HybridDACManagementProposalFactory.referenceImpl",
            HybridDACManagementProposalFactory(deployment.hybridProposalFactory).referenceImpl(),
            deployment.hybridProposalImpl
        );
        _expect(
            "GovernanceOracleFactory.referenceImpl",
            GovernanceOracleFactory(deployment.governanceOracleFactory).referenceImpl(),
            deployment.governanceOracleImpl
        );
        _expect(
            "WrappedMainTokenFactory.referenceImpl",
            WrappedMainTokenFactory(deployment.wrappedMainTokenFactory).referenceImpl(),
            deployment.wrappedMainTokenImpl
        );

        _expect(
            "DACFactory.dealCellFactory",
            DACFactory(deployment.dacFactory).dealCellFactory(),
            deployment.dealCellFactory
        );
        _expect(
            "CoreModuleFactory.treasuryDealFactory",
            CoreModuleFactory(deployment.coreModuleFactory).treasuryDealFactory(),
            deployment.treasuryDealFactory
        );

        _expect(
            "TreasuryDealFactory.permit2VaultFactory",
            TreasuryDealFactory(deployment.treasuryDealFactory).permit2VaultFactory(),
            deployment.permit2TreasuryFactory
        );

        console2.log("Smoke check passed");
        console2.log("  chainId:", deployment.chainId);
        console2.log("  dacFactory:", deployment.dacFactory);
        console2.log("  manifest:", protocolManifestPath());
    }

    function _requireNonZero(string memory field, address value) private pure {
        if (value == address(0)) revert ZeroAddress(field);
    }

    function _expect(string memory field, address actual, address expected) private pure {
        if (actual != expected) revert UnexpectedPointer(field, actual, expected);
    }
}
