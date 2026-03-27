// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {
    BasicDACSeedConfig,
    ChildDACFlowSeedConfig,
    ExistingDACSeedConfig,
    ExistingGovernanceFlowSeedConfig,
    ExistingTreasuryFlowSeedConfig,
    ProtocolConfig,
    TreasuryFlowSeedConfig
} from "./ScriptTypes.sol";

abstract contract ScriptConfig is Script {
    error MissingEnv(string key);
    error InvalidAddress(string key);

    string internal constant PRIVATE_KEY_ENV = "PRIVATE_KEY";
    string internal constant PERMIT2_ENV = "PERMIT2_ADDRESS";
    string internal constant FOUNDER_PRIVATE_KEY_ENV = "FOUNDER_PRIVATE_KEY";

    string internal constant BASIC_DAC_LABEL_ENV = "BASIC_DAC_LABEL";
    string internal constant BASIC_DAC_SYMBOL_ENV = "BASIC_DAC_SYMBOL";
    string internal constant BASIC_DAC_NAME_ENV = "BASIC_DAC_NAME";
    string internal constant BASIC_DAC_DESCRIPTION_ENV = "BASIC_DAC_DESCRIPTION";
    string internal constant BASIC_DAC_MAX_SUPPLY_ENV = "BASIC_DAC_MAX_SUPPLY";
    string internal constant BASIC_DAC_DEFAULT_QUORUM_ENV = "BASIC_DAC_DEFAULT_QUORUM";
    string internal constant BASIC_DAC_FOUNDER_ALLOCATION_ENV = "BASIC_DAC_FOUNDER_ALLOCATION";
    string internal constant BASIC_DAC_FOUNDER_COMMITMENT_ENV = "BASIC_DAC_FOUNDER_COMMITMENT";
    string internal constant BASIC_DAC_DIVIDENDS_ENV = "BASIC_DAC_DIVIDENDS_ENABLED";
    string internal constant EXISTING_DAC_LABEL_ENV = "EXISTING_DAC_LABEL";
    string internal constant EXISTING_DAC_SYMBOL_ENV = "EXISTING_DAC_SYMBOL";
    string internal constant EXISTING_DAC_NAME_ENV = "EXISTING_DAC_NAME";
    string internal constant EXISTING_DAC_DESCRIPTION_ENV = "EXISTING_DAC_DESCRIPTION";
    string internal constant EXISTING_DAC_DIVIDENDS_ENV = "EXISTING_DAC_DIVIDENDS_ENABLED";
    string internal constant EXISTING_DAC_UNDERLYING_ENV = "EXISTING_DAC_UNDERLYING_TOKEN_ADDRESS";
    string internal constant EXISTING_DAC_MOCK_TOKEN_DECIMALS_ENV = "EXISTING_DAC_MOCK_TOKEN_DECIMALS";
    string internal constant EXISTING_DAC_MOCK_TOKEN_MINT_ENV = "EXISTING_DAC_MOCK_TOKEN_MINT";
    string internal constant EXISTING_DAC_WRAP_AMOUNT_ENV = "EXISTING_DAC_WRAP_AMOUNT";
    string internal constant EXISTING_DAC_TREASURY_SEED_ENV = "EXISTING_DAC_TREASURY_SEED";
    string internal constant EXISTING_DAC_ORACLE_ADMIN_ENV = "EXISTING_DAC_ORACLE_ADMIN_ADDRESS";
    string internal constant EXISTING_DAC_ORACLE_PUBLISHER_ENV = "EXISTING_DAC_ORACLE_PUBLISHER_ADDRESS";
    string internal constant EXISTING_DAC_QUORUM_ENV = "EXISTING_DAC_DEFAULT_QUORUM";
    string internal constant EXISTING_DAC_HIGH_QUORUM_ENV = "EXISTING_DAC_HIGH_QUORUM";
    string internal constant EXISTING_DAC_BLOCKING_QUORUM_ENV = "EXISTING_DAC_BLOCKING_QUORUM";
    string internal constant EXISTING_DAC_DURATION_ENV = "EXISTING_DAC_DURATION";
    string internal constant EXISTING_DAC_QUALIFICATION_ENV = "EXISTING_DAC_QUALIFICATION";
    string internal constant EXISTING_DAC_EXECUTION_VALIDITY_ENV = "EXISTING_DAC_EXECUTION_VALIDITY";
    string internal constant EXISTING_DAC_ORACLE_DEADLINE_ENV = "EXISTING_DAC_ORACLE_PUBLISH_DEADLINE";
    string internal constant EXISTING_DAC_FALLBACK_WARMUP_ENV = "EXISTING_DAC_FALLBACK_WARMUP";
    string internal constant EXISTING_DAC_FALLBACK_DURATION_ENV = "EXISTING_DAC_FALLBACK_DURATION";
    string internal constant EXISTING_GOV_FLOW_LABEL_ENV = "EXISTING_GOV_FLOW_LABEL";
    string internal constant EXISTING_GOV_FLOW_DAC_LABEL_ENV = "EXISTING_GOV_FLOW_EXISTING_DAC_LABEL";
    string internal constant EXISTING_GOV_FLOW_AGENT_MINT_AMOUNT_ENV = "EXISTING_GOV_FLOW_AGENT_MINT_AMOUNT";
    string internal constant EXISTING_GOV_FLOW_MERKLE_INDEX_ENV = "EXISTING_GOV_FLOW_MERKLE_INDEX";
    string internal constant EXISTING_GOV_FLOW_MERKLE_AMOUNT_ENV = "EXISTING_GOV_FLOW_MERKLE_AMOUNT";
    string internal constant TREASURY_TOKEN_ENV = "TREASURY_TOKEN_ADDRESS";
    string internal constant BASIC_DAC_MOCK_TOKEN_DECIMALS_ENV = "BASIC_DAC_MOCK_TOKEN_DECIMALS";
    string internal constant BASIC_DAC_MOCK_TOKEN_MINT_ENV = "BASIC_DAC_MOCK_TOKEN_MINT";
    string internal constant AGENT_PRIVATE_KEY_ENV = "AGENT_PRIVATE_KEY";
    string internal constant RECIPIENT_ADDRESS_ENV = "RECIPIENT_ADDRESS";

    string internal constant TREASURY_FLOW_LABEL_ENV = "TREASURY_FLOW_LABEL";
    string internal constant TREASURY_FLOW_BASIC_DAC_LABEL_ENV = "TREASURY_FLOW_BASIC_DAC_LABEL";
    string internal constant TREASURY_FLOW_AGENT_MINT_AMOUNT_ENV = "TREASURY_FLOW_AGENT_MINT_AMOUNT";
    string internal constant TREASURY_FLOW_STAKE_AMOUNT_ENV = "TREASURY_FLOW_STAKE_AMOUNT";
    string internal constant TREASURY_FLOW_FUNDING_AMOUNT_ENV = "TREASURY_FLOW_FUNDING_AMOUNT";
    string internal constant TREASURY_FLOW_REWARDS_LIMIT_ENV = "TREASURY_FLOW_REWARDS_LIMIT";
    string internal constant TREASURY_FLOW_EXPECTED_RETURN_ENV = "TREASURY_FLOW_EXPECTED_RETURN";
    string internal constant TREASURY_FLOW_DIRECT_SPEND_AMOUNT_ENV = "TREASURY_FLOW_DIRECT_SPEND_AMOUNT";
    string internal constant TREASURY_FLOW_PERMIT2_SPEND_AMOUNT_ENV = "TREASURY_FLOW_PERMIT2_SPEND_AMOUNT";
    string internal constant TREASURY_FLOW_ASSIGN_CLAIM_AMOUNT_ENV = "TREASURY_FLOW_ASSIGN_CLAIM_AMOUNT";
    string internal constant TREASURY_FLOW_AGENT_SPEND_TOTAL_ENV = "TREASURY_FLOW_AGENT_SPEND_TOTAL_AMOUNT";
    string internal constant TREASURY_FLOW_AGENT_SPEND_SINGLE_ENV = "TREASURY_FLOW_AGENT_SPEND_SINGLE_AMOUNT";
    string internal constant TREASURY_FLOW_AGENT_SPEND_DURATION_ENV = "TREASURY_FLOW_AGENT_SPEND_DURATION";
    string internal constant EXISTING_TREASURY_FLOW_LABEL_ENV = "EXISTING_TREASURY_FLOW_LABEL";
    string internal constant EXISTING_TREASURY_FLOW_DAC_LABEL_ENV = "EXISTING_TREASURY_FLOW_EXISTING_DAC_LABEL";
    string internal constant EXISTING_TREASURY_FLOW_AGENT_MINT_AMOUNT_ENV = "EXISTING_TREASURY_FLOW_AGENT_MINT_AMOUNT";
    string internal constant EXISTING_TREASURY_FLOW_STAKE_AMOUNT_ENV = "EXISTING_TREASURY_FLOW_STAKE_AMOUNT";
    string internal constant EXISTING_TREASURY_FLOW_FUNDING_AMOUNT_ENV = "EXISTING_TREASURY_FLOW_FUNDING_AMOUNT";
    string internal constant EXISTING_TREASURY_FLOW_REWARDS_LIMIT_ENV = "EXISTING_TREASURY_FLOW_REWARDS_LIMIT";
    string internal constant EXISTING_TREASURY_FLOW_EXPECTED_RETURN_ENV = "EXISTING_TREASURY_FLOW_EXPECTED_RETURN";
    string internal constant EXISTING_TREASURY_FLOW_MERKLE_INDEX_ENV = "EXISTING_TREASURY_FLOW_MERKLE_INDEX";
    string internal constant EXISTING_TREASURY_FLOW_MERKLE_AMOUNT_ENV = "EXISTING_TREASURY_FLOW_MERKLE_AMOUNT";
    string internal constant CHILD_FLOW_LABEL_ENV = "CHILD_FLOW_LABEL";
    string internal constant CHILD_FLOW_BASIC_DAC_LABEL_ENV = "CHILD_FLOW_BASIC_DAC_LABEL";
    string internal constant CHILD_FLOW_AGENT_MINT_AMOUNT_ENV = "CHILD_FLOW_AGENT_MINT_AMOUNT";
    string internal constant CHILD_FLOW_STAKE_AMOUNT_ENV = "CHILD_FLOW_STAKE_AMOUNT";
    string internal constant CHILD_FLOW_FUNDING_AMOUNT_ENV = "CHILD_FLOW_FUNDING_AMOUNT";
    string internal constant CHILD_FLOW_REWARDS_LIMIT_ENV = "CHILD_FLOW_REWARDS_LIMIT";
    string internal constant CHILD_FLOW_MANAGED_EQUITY_ENV = "CHILD_FLOW_MANAGED_EQUITY";
    string internal constant CHILD_FLOW_MAIN_MAX_SUPPLY_ENV = "CHILD_FLOW_MAIN_MAX_SUPPLY";
    string internal constant CHILD_FLOW_DEFAULT_QUORUM_ENV = "CHILD_FLOW_DEFAULT_QUORUM";
    string internal constant CHILD_FLOW_CHILD_MINT_AGENT_AMOUNT_ENV = "CHILD_FLOW_CHILD_MINT_AGENT_AMOUNT";
    string internal constant CHILD_FLOW_CAPITAL_CALL_TOKEN_AMOUNT_ENV = "CHILD_FLOW_CAPITAL_CALL_TOKEN_AMOUNT";
    string internal constant CHILD_FLOW_CAPITAL_CALL_CASH_AMOUNT_ENV = "CHILD_FLOW_CAPITAL_CALL_CASH_AMOUNT";
    string internal constant CHILD_FLOW_REINVEST_AMOUNT_ENV = "CHILD_FLOW_REINVEST_AMOUNT";
    string internal constant CHILD_FLOW_RETURN_PROFIT_AMOUNT_ENV = "CHILD_FLOW_RETURN_PROFIT_AMOUNT";

    function loadProtocolConfig() internal view returns (ProtocolConfig memory config) {
        if (!vm.envExists(PERMIT2_ENV)) revert MissingEnv(PERMIT2_ENV);

        config.permit2 = vm.envAddress(PERMIT2_ENV);
        if (config.permit2 == address(0)) revert InvalidAddress(PERMIT2_ENV);
    }

    function broadcasterKey() internal view returns (uint256) {
        if (!vm.envExists(PRIVATE_KEY_ENV)) revert MissingEnv(PRIVATE_KEY_ENV);
        return vm.envUint(PRIVATE_KEY_ENV);
    }

    function founderKey() internal view returns (uint256) {
        if (vm.envExists(FOUNDER_PRIVATE_KEY_ENV)) {
            return vm.envUint(FOUNDER_PRIVATE_KEY_ENV);
        }

        return broadcasterKey();
    }

    function agentKey() internal view returns (uint256) {
        if (vm.envExists(AGENT_PRIVATE_KEY_ENV)) {
            return vm.envUint(AGENT_PRIVATE_KEY_ENV);
        }

        return uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d);
    }

    function recipientAddress() internal view returns (address) {
        if (vm.envExists(RECIPIENT_ADDRESS_ENV)) {
            address recipient = vm.envAddress(RECIPIENT_ADDRESS_ENV);
            if (recipient == address(0)) revert InvalidAddress(RECIPIENT_ADDRESS_ENV);
            return recipient;
        }

        return vm.addr(
            uint256(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a)
        );
    }

    function deploymentsRoot() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments");
    }

    function chainDeploymentsRoot() internal view returns (string memory) {
        return string.concat(deploymentsRoot(), "/", vm.toString(block.chainid));
    }

    function protocolManifestPath() internal view returns (string memory) {
        return string.concat(chainDeploymentsRoot(), "/protocol.json");
    }

    function basicDACSeedManifestPath(string memory label) internal view returns (string memory) {
        return string.concat(chainDeploymentsRoot(), "/basic-dac-", label, ".json");
    }

    function existingDACSeedManifestPath(string memory label) internal view returns (string memory) {
        return string.concat(chainDeploymentsRoot(), "/existing-dac-", label, ".json");
    }

    function existingGovernanceFlowManifestPath(string memory label) internal view returns (string memory) {
        return string.concat(chainDeploymentsRoot(), "/existing-governance-flow-", label, ".json");
    }

    function treasuryFlowManifestPath(string memory label) internal view returns (string memory) {
        return string.concat(chainDeploymentsRoot(), "/treasury-flow-", label, ".json");
    }

    function existingTreasuryFlowManifestPath(string memory label) internal view returns (string memory) {
        return string.concat(chainDeploymentsRoot(), "/existing-treasury-flow-", label, ".json");
    }

    function childDACFlowManifestPath(string memory label) internal view returns (string memory) {
        return string.concat(chainDeploymentsRoot(), "/child-dac-flow-", label, ".json");
    }

    function loadBasicDACSeedConfig() internal view returns (BasicDACSeedConfig memory config) {
        config.label = vm.envOr(BASIC_DAC_LABEL_ENV, string("seed"));
        config.symbol = vm.envOr(BASIC_DAC_SYMBOL_ENV, string("SDAC"));
        config.name = vm.envOr(BASIC_DAC_NAME_ENV, string("Seed DAC"));
        config.description = vm.envOr(
            BASIC_DAC_DESCRIPTION_ENV,
            string("Manifest-driven seeded DAC for local and testnet scenario flows")
        );
        config.mainTokenMaxSupply = vm.envOr(BASIC_DAC_MAX_SUPPLY_ENV, uint256(1_000_000_000e18));
        config.defaultQuorum = vm.envOr(BASIC_DAC_DEFAULT_QUORUM_ENV, uint256(5e17));
        config.founderAllocation = vm.envOr(BASIC_DAC_FOUNDER_ALLOCATION_ENV, uint256(200_000_000e18));
        config.founderCommitment = vm.envOr(BASIC_DAC_FOUNDER_COMMITMENT_ENV, uint256(20_000e6));
        config.dividendsEnabled = vm.envOr(BASIC_DAC_DIVIDENDS_ENV, false);
        config.mockTreasuryDecimals = uint8(vm.envOr(BASIC_DAC_MOCK_TOKEN_DECIMALS_ENV, uint256(6)));
        config.mockTreasuryMint = vm.envOr(BASIC_DAC_MOCK_TOKEN_MINT_ENV, config.founderCommitment * 10);

        if (vm.envExists(TREASURY_TOKEN_ENV)) {
            config.treasuryToken = vm.envAddress(TREASURY_TOKEN_ENV);
            if (config.treasuryToken == address(0)) revert InvalidAddress(TREASURY_TOKEN_ENV);
            config.deployMockTreasuryToken = false;
        }
        else {
            config.treasuryToken = address(0);
            config.deployMockTreasuryToken = true;
        }
    }

    function loadExistingDACSeedConfig() internal view returns (ExistingDACSeedConfig memory config) {
        config.label = vm.envOr(EXISTING_DAC_LABEL_ENV, string("existing"));
        config.symbol = vm.envOr(EXISTING_DAC_SYMBOL_ENV, string("WDAC"));
        config.name = vm.envOr(EXISTING_DAC_NAME_ENV, string("Existing Token DAC"));
        config.description = vm.envOr(
            EXISTING_DAC_DESCRIPTION_ENV,
            string("Existing-token DAC seeded for hybrid oracle plus wrapper governance flows")
        );
        config.dividendsEnabled = vm.envOr(EXISTING_DAC_DIVIDENDS_ENV, false);
        config.mockUnderlyingDecimals = uint8(vm.envOr(EXISTING_DAC_MOCK_TOKEN_DECIMALS_ENV, uint256(18)));
        config.mockUnderlyingMint = vm.envOr(EXISTING_DAC_MOCK_TOKEN_MINT_ENV, uint256(1_000_000e18));
        config.wrapAmount = vm.envOr(EXISTING_DAC_WRAP_AMOUNT_ENV, uint256(250_000e18));
        config.treasurySeedAmount = vm.envOr(EXISTING_DAC_TREASURY_SEED_ENV, uint256(100_000e18));
        config.quorumPercent = vm.envOr(EXISTING_DAC_QUORUM_ENV, uint256(5e17));
        config.highQuorumPercent = vm.envOr(EXISTING_DAC_HIGH_QUORUM_ENV, uint256(75e16));
        config.blockingPercent = vm.envOr(EXISTING_DAC_BLOCKING_QUORUM_ENV, uint256(2e17));
        config.duration = vm.envOr(EXISTING_DAC_DURATION_ENV, uint256(7 days));
        config.qualification = vm.envOr(EXISTING_DAC_QUALIFICATION_ENV, uint256(0));
        config.executionValidityDuration = vm.envOr(EXISTING_DAC_EXECUTION_VALIDITY_ENV, uint256(1 days));
        config.oraclePublishDeadline = vm.envOr(EXISTING_DAC_ORACLE_DEADLINE_ENV, uint256(1 days));
        config.fallbackWarmupDuration = vm.envOr(EXISTING_DAC_FALLBACK_WARMUP_ENV, uint256(1 days));
        config.fallbackDuration = vm.envOr(EXISTING_DAC_FALLBACK_DURATION_ENV, uint256(3 days));

        if (vm.envExists(EXISTING_DAC_UNDERLYING_ENV)) {
            config.underlyingToken = vm.envAddress(EXISTING_DAC_UNDERLYING_ENV);
            if (config.underlyingToken == address(0)) revert InvalidAddress(EXISTING_DAC_UNDERLYING_ENV);
            config.deployMockUnderlyingToken = false;
        } else {
            config.underlyingToken = address(0);
            config.deployMockUnderlyingToken = true;
        }

        if (vm.envExists(EXISTING_DAC_ORACLE_ADMIN_ENV)) {
            config.oracleAdmin = vm.envAddress(EXISTING_DAC_ORACLE_ADMIN_ENV);
            if (config.oracleAdmin == address(0)) revert InvalidAddress(EXISTING_DAC_ORACLE_ADMIN_ENV);
        } else {
            config.oracleAdmin = vm.addr(founderKey());
        }

        if (vm.envExists(EXISTING_DAC_ORACLE_PUBLISHER_ENV)) {
            config.oraclePublisher = vm.envAddress(EXISTING_DAC_ORACLE_PUBLISHER_ENV);
            if (config.oraclePublisher == address(0)) revert InvalidAddress(EXISTING_DAC_ORACLE_PUBLISHER_ENV);
        } else {
            config.oraclePublisher = config.oracleAdmin;
        }
    }

    function loadTreasuryFlowSeedConfig() internal view returns (TreasuryFlowSeedConfig memory config) {
        config.label = vm.envOr(TREASURY_FLOW_LABEL_ENV, string("treasury"));
        config.basicDACLabel = vm.envOr(TREASURY_FLOW_BASIC_DAC_LABEL_ENV, vm.envOr(BASIC_DAC_LABEL_ENV, string("seed")));
        config.agentMintAmount = vm.envOr(TREASURY_FLOW_AGENT_MINT_AMOUNT_ENV, uint256(100_000));
        config.stakeAmount = vm.envOr(TREASURY_FLOW_STAKE_AMOUNT_ENV, uint256(20_000));
        config.fundingAmount = vm.envOr(TREASURY_FLOW_FUNDING_AMOUNT_ENV, uint256(10_000e6));
        config.rewardsLimit = vm.envOr(TREASURY_FLOW_REWARDS_LIMIT_ENV, uint256(500e6));
        config.expectedReturn = vm.envOr(TREASURY_FLOW_EXPECTED_RETURN_ENV, uint256(10_000e6));
        config.directSpendAmount = vm.envOr(TREASURY_FLOW_DIRECT_SPEND_AMOUNT_ENV, uint256(3_000e6));
        config.permit2SpendAmount = uint160(vm.envOr(TREASURY_FLOW_PERMIT2_SPEND_AMOUNT_ENV, uint256(2_500e6)));
        config.assignClaimAmount = vm.envOr(TREASURY_FLOW_ASSIGN_CLAIM_AMOUNT_ENV, uint256(2_000e6));
        config.agentSpendTotalAmount = uint160(vm.envOr(TREASURY_FLOW_AGENT_SPEND_TOTAL_ENV, uint256(4_000e6)));
        config.agentSpendSingleTxAmount = uint160(vm.envOr(TREASURY_FLOW_AGENT_SPEND_SINGLE_ENV, uint256(2_000e6)));
        config.agentSpendDuration = vm.envOr(TREASURY_FLOW_AGENT_SPEND_DURATION_ENV, uint256(1 days));
    }

    function loadExistingGovernanceFlowSeedConfig()
        internal
        view
        returns (ExistingGovernanceFlowSeedConfig memory config)
    {
        config.label = vm.envOr(EXISTING_GOV_FLOW_LABEL_ENV, string("hybrid-governance"));
        config.existingDACLabel =
            vm.envOr(EXISTING_GOV_FLOW_DAC_LABEL_ENV, vm.envOr(EXISTING_DAC_LABEL_ENV, string("existing")));
        config.agentMintAmount = vm.envOr(EXISTING_GOV_FLOW_AGENT_MINT_AMOUNT_ENV, uint256(12_345));
        config.merkleIndex = vm.envOr(EXISTING_GOV_FLOW_MERKLE_INDEX_ENV, uint256(0));
        config.merkleAmountOverride = vm.envOr(EXISTING_GOV_FLOW_MERKLE_AMOUNT_ENV, uint256(0));
    }

    function loadExistingTreasuryFlowSeedConfig()
        internal
        view
        returns (ExistingTreasuryFlowSeedConfig memory config)
    {
        config.label = vm.envOr(EXISTING_TREASURY_FLOW_LABEL_ENV, string("existing-treasury"));
        config.existingDACLabel =
            vm.envOr(EXISTING_TREASURY_FLOW_DAC_LABEL_ENV, vm.envOr(EXISTING_DAC_LABEL_ENV, string("existing")));
        config.agentMintAmount = vm.envOr(EXISTING_TREASURY_FLOW_AGENT_MINT_AMOUNT_ENV, uint256(100_000));
        config.stakeAmount = vm.envOr(EXISTING_TREASURY_FLOW_STAKE_AMOUNT_ENV, uint256(20_000));
        config.fundingAmount = vm.envOr(EXISTING_TREASURY_FLOW_FUNDING_AMOUNT_ENV, uint256(10_000e18));
        config.rewardsLimit = vm.envOr(EXISTING_TREASURY_FLOW_REWARDS_LIMIT_ENV, uint256(500e18));
        config.expectedReturn = vm.envOr(EXISTING_TREASURY_FLOW_EXPECTED_RETURN_ENV, uint256(10_000e18));
        config.merkleIndex = vm.envOr(EXISTING_TREASURY_FLOW_MERKLE_INDEX_ENV, uint256(0));
        config.merkleAmountOverride = vm.envOr(EXISTING_TREASURY_FLOW_MERKLE_AMOUNT_ENV, uint256(0));
    }

    function loadChildDACFlowSeedConfig() internal view returns (ChildDACFlowSeedConfig memory config) {
        config.label = vm.envOr(CHILD_FLOW_LABEL_ENV, string("child-dac"));
        config.basicDACLabel = vm.envOr(CHILD_FLOW_BASIC_DAC_LABEL_ENV, vm.envOr(BASIC_DAC_LABEL_ENV, string("seed")));
        config.agentMintAmount = vm.envOr(CHILD_FLOW_AGENT_MINT_AMOUNT_ENV, uint256(100_000));
        config.stakeAmount = vm.envOr(CHILD_FLOW_STAKE_AMOUNT_ENV, uint256(20_000));
        config.fundingAmount = vm.envOr(CHILD_FLOW_FUNDING_AMOUNT_ENV, uint256(10_000e6));
        config.rewardsLimit = vm.envOr(CHILD_FLOW_REWARDS_LIMIT_ENV, uint256(500e6));
        config.managedEquity = vm.envOr(CHILD_FLOW_MANAGED_EQUITY_ENV, uint256(100_000e18));
        config.childMainTokenMaxSupply = vm.envOr(CHILD_FLOW_MAIN_MAX_SUPPLY_ENV, uint256(1_000_000e18));
        config.childDefaultQuorum = vm.envOr(CHILD_FLOW_DEFAULT_QUORUM_ENV, uint256(5e17));
        config.childMintAgentAmount = vm.envOr(CHILD_FLOW_CHILD_MINT_AGENT_AMOUNT_ENV, uint256(12_345));
        config.childCapitalCallTokenAmount = vm.envOr(CHILD_FLOW_CAPITAL_CALL_TOKEN_AMOUNT_ENV, uint256(22_222e18));
        config.childCapitalCallCashAmount = vm.envOr(CHILD_FLOW_CAPITAL_CALL_CASH_AMOUNT_ENV, uint256(2_500e6));
        config.reinvestAmount = vm.envOr(CHILD_FLOW_REINVEST_AMOUNT_ENV, uint256(2_500e6));
        config.returnProfitAmount = vm.envOr(CHILD_FLOW_RETURN_PROFIT_AMOUNT_ENV, uint256(3_333e6));
    }
}
