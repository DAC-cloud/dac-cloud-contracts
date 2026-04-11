// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ManifestIO} from "../common/ManifestIO.sol";
import {ExistingDACSeed, ExistingDACSeedConfig, ProtocolDeployment} from "../common/ScriptTypes.sol";
import {ScriptMintableERC20} from "../mocks/ScriptMintableERC20.sol";
import {ExistingDACConfig} from "../../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig} from "../../src/interfaces/GovernanceStructs.sol";
import {DACFactory} from "../../src/kernel/DACFactory.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {WrappedMainToken} from "../../src/kernel/tokens/WrappedMainToken.sol";

contract SeedExistingTokenDAC is ManifestIO {
    error InvalidTreasurySeedAmount();
    error InsufficientRetainedWrappedBalance();

    function run() external returns (ExistingDACSeed memory seed) {
        ProtocolDeployment memory protocol = loadProtocolManifest();
        ExistingDACSeedConfig memory config = loadExistingDACSeedConfig();
        uint256 founderPk = founderKey();

        seed.chainId = block.chainid;
        seed.label = config.label;
        seed.broadcaster = vm.addr(founderPk);
        seed.founder = seed.broadcaster;
        seed.dacFactory = protocol.dacFactory;
        seed.wrapAmount = config.wrapAmount;
        seed.treasurySeedAmount = config.treasurySeedAmount;
        seed.dividendsEnabled = config.dividendsEnabled;

        if (config.treasurySeedAmount == 0) revert InvalidTreasurySeedAmount();

        if (config.wrapAmount != 0) {
            if (config.wrapAmount <= config.qualification) revert InsufficientRetainedWrappedBalance();
        }

        vm.startBroadcast(founderPk);

        if (config.deployMockUnderlyingToken) {
            ScriptMintableERC20 mockToken = new ScriptMintableERC20(
                string.concat(config.name, " Underlying"),
                string.concat("u", config.symbol),
                config.mockUnderlyingDecimals
            );
            mockToken.mint(seed.founder, config.mockUnderlyingMint);
            config.underlyingToken = address(mockToken);
            seed.usedMockUnderlyingToken = true;
        }

        // Deploy the reference governance oracle up-front, separately from DAC creation.
        // Set to address(0) to start without an oracle (only valid when oraclePrimaryEnabled is false).
        address governanceOracle = config.oraclePrimaryEnabled
            ? DACFactory(protocol.dacFactory).deployGovernanceOracle(config.oracleAdmin, config.oraclePublisher)
            : address(0);
        seed.governanceOracle = governanceOracle;

        ExistingDACConfig memory dacConfig = ExistingDACConfig({
            symbol: config.symbol,
            name: config.name,
            description: config.description,
            underlyingToken: config.underlyingToken,
            treasurySeedAmount: config.treasurySeedAmount,
            governanceOracle: governanceOracle,
            dividendsEnabled: config.dividendsEnabled,
            governanceStrategy: GovernanceStrategyConfig({
                quorumPercent: config.quorumPercent,
                highQuorumPercent: config.highQuorumPercent,
                blockingPercent: config.blockingPercent,
                duration: config.duration,
                qualification: config.qualification,
                executionValidityDuration: config.executionValidityDuration,
                oraclePublishDeadline: config.oraclePublishDeadline,
                fallbackWarmupDuration: config.fallbackWarmupDuration,
                fallbackDuration: config.fallbackDuration,
                blockingOnAllProposals: config.blockingOnAllProposals,
                blockingOnHighQuorum: config.blockingOnHighQuorum,
                oraclePrimaryEnabled: config.oraclePrimaryEnabled
            })
        });

        IERC20(config.underlyingToken).approve(protocol.dacFactory, config.treasurySeedAmount);
        bytes32 salt = keccak256(abi.encode(config.label, seed.founder, block.chainid, protocol.dacFactory));
        (seed.dac, seed.mainToken, seed.agentToken) =
            DACFactory(protocol.dacFactory).deployExistingTokenDAC(abi.encode(dacConfig), salt);

        seed.underlyingToken = config.underlyingToken;
        seed.dealManager = DACCell(seed.dac).getDealManager();
        seed.assetController = DACCell(seed.dac).getAssetController();

        if (config.wrapAmount > 0) {
            IERC20(config.underlyingToken).approve(seed.mainToken, config.wrapAmount);
            WrappedMainToken(seed.mainToken).wrap(config.wrapAmount);
        }

        seed.blockNumber = block.number;

        vm.stopBroadcast();

        string memory manifestPath = writeExistingDACSeedManifest(seed);

        console2.log("Existing-token DAC seeded");
        console2.log("  label:", seed.label);
        console2.log("  dac:", seed.dac);
        console2.log("  wrappedMainToken:", seed.mainToken);
        console2.log("  underlyingToken:", seed.underlyingToken);
        console2.log("  governanceOracle:", seed.governanceOracle);
        console2.log("  assetController:", seed.assetController);
        console2.log("  manifest:", manifestPath);
    }
}
