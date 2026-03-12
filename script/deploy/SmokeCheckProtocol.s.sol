// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ManifestIO} from "../common/ManifestIO.sol";
import {ProtocolDeployment} from "../common/ScriptTypes.sol";
import {DACFactory} from "../../src/kernel/DACFactory.sol";
import {DACCellFactory} from "../../src/kernel/factories/DACCellFactory.sol";
import {DealManagerFactory} from "../../src/kernel/factories/DealManagerFactory.sol";
import {DACManagementProposalFactory} from "../../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../../src/kernel/tokens/factories/TokenFactories.sol";
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
            "DACManagementProposalFactory.referenceImpl",
            DACManagementProposalFactory(deployment.dacGovernanceFactory).referenceImpl(),
            deployment.dacGovernanceImpl
        );

        _expect(
            "CoreModuleFactory.dealCellFactory",
            CoreModuleFactory(deployment.coreModuleFactory).dealCellFactory(),
            deployment.dealCellFactory
        );
        _expect(
            "CoreModuleFactory.stakedAgentTokenFactory",
            CoreModuleFactory(deployment.coreModuleFactory).stakedAgentTokenFactory(),
            deployment.stakedAgentFactory
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
