// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ManifestIO} from "../common/ManifestIO.sol";
import {ProtocolDeployment} from "../common/ScriptTypes.sol";

contract PreflightProtocol is ManifestIO {
    error WrongChain(uint256 manifestChainId, uint256 currentChainId);
    error MissingCode(string field, address target);
    error RuntimeSizeTooLarge(string field, uint256 actual, uint256 limit);

    uint256 internal constant EIP170_LIMIT = 24_576;

    function run() external view returns (ProtocolDeployment memory deployment) {
        deployment = loadProtocolManifest();
        if (deployment.chainId != block.chainid) revert WrongChain(deployment.chainId, block.chainid);

        _checkCode("permit2", deployment.permit2);
        _checkCode("dacFactory", deployment.dacFactory);
        _checkCode("mainTokenFactory", deployment.mainTokenFactory);
        _checkCode("mainTokenImpl", deployment.mainTokenImpl);
        _checkCode("agentTokenFactory", deployment.agentTokenFactory);
        _checkCode("agentTokenImpl", deployment.agentTokenImpl);
        _checkCode("stakedAgentFactory", deployment.stakedAgentFactory);
        _checkCode("stakedAgentImpl", deployment.stakedAgentImpl);
        _checkCode("dacCellFactory", deployment.dacCellFactory);
        _checkCode("dacCellImpl", deployment.dacCellImpl);
        _checkCode("dealCellFactory", deployment.dealCellFactory);
        _checkCode("dealCellImpl", deployment.dealCellImpl);
        _checkCode("dealManagerFactory", deployment.dealManagerFactory);
        _checkCode("dealManagerImpl", deployment.dealManagerImpl);
        _checkCode("dacGovernanceFactory", deployment.dacGovernanceFactory);
        _checkCode("dacGovernanceImpl", deployment.dacGovernanceImpl);
        _checkCode("coreDealGovernanceFactory", deployment.coreDealGovernanceFactory);
        _checkCode("coreDealGovernanceImpl", deployment.coreDealGovernanceImpl);
        _checkCode("dacDealFactory", deployment.dacDealFactory);
        _checkCode("dacDealImpl", deployment.dacDealImpl);
        _checkCode("treasuryDealFactory", deployment.treasuryDealFactory);
        _checkCode("treasuryDealImpl", deployment.treasuryDealImpl);
        _checkCode("permit2TreasuryFactory", deployment.permit2TreasuryFactory);
        _checkCode("coreModuleFactory", deployment.coreModuleFactory);
        _checkCode("milestoneEvaluatorFactory", deployment.milestoneEvaluatorFactory);
        _checkCode("milestoneEvaluatorImpl", deployment.milestoneEvaluatorImpl);
        _checkCode("revenueEvaluatorFactory", deployment.revenueEvaluatorFactory);
        _checkCode("revenueEvaluatorImpl", deployment.revenueEvaluatorImpl);

        _logMargin("DACCell", deployment.dacCellImpl);
        _logMargin("DealCell", deployment.dealCellImpl);
        _logMargin("DealManager", deployment.dealManagerImpl);
        _logMargin("DACDeal", deployment.dacDealImpl);
        _logMargin("TreasuryDeal", deployment.treasuryDealImpl);
        _logMargin("MainToken", deployment.mainTokenImpl);
        _logMargin("AgentToken", deployment.agentTokenImpl);

        console2.log("Preflight passed");
        console2.log("  chainId:", deployment.chainId);
        console2.log("  manifest:", protocolManifestPath());
    }

    function _checkCode(string memory field, address target) internal view {
        uint256 actualRuntimeSize = target.code.length;

        if (actualRuntimeSize == 0) revert MissingCode(field, target);
        if (actualRuntimeSize > EIP170_LIMIT) {
            revert RuntimeSizeTooLarge(field, actualRuntimeSize, EIP170_LIMIT);
        }
    }

    function _logMargin(string memory label, address target) internal view {
        uint256 runtimeSize = target.code.length;
        console2.log(string.concat("  ", label, " runtime bytes:"), runtimeSize);
        console2.log(string.concat("  ", label, " EIP-170 margin:"), EIP170_LIMIT - runtimeSize);
    }
}
