// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ManifestIO} from "../common/ManifestIO.sol";
import {BasicDACSeed, BasicDACSeedConfig, ProtocolDeployment} from "../common/ScriptTypes.sol";
import {ScriptMintableERC20} from "../mocks/ScriptMintableERC20.sol";
import {DACConfig, CapitalCall} from "../../src/interfaces/Structs.sol";
import {DACFactory} from "../../src/kernel/DACFactory.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {MainToken} from "../../src/kernel/tokens/MainToken.sol";

contract SeedBasicDAC is ManifestIO {
    function run() external returns (BasicDACSeed memory seed) {
        ProtocolDeployment memory protocol = loadProtocolManifest();
        BasicDACSeedConfig memory config = loadBasicDACSeedConfig();
        uint256 founderPk = founderKey();

        seed.chainId = block.chainid;
        seed.label = config.label;
        seed.broadcaster = vm.addr(founderPk);
        seed.founder = seed.broadcaster;
        seed.dacFactory = protocol.dacFactory;
        seed.founderAllocation = config.founderAllocation;
        seed.founderCommitment = config.founderCommitment;
        seed.dividendsEnabled = config.dividendsEnabled;

        vm.startBroadcast(founderPk);

        if (config.deployMockTreasuryToken) {
            ScriptMintableERC20 mockToken = new ScriptMintableERC20("Seed USD", "sUSD", config.mockTreasuryDecimals);
            mockToken.mint(seed.founder, config.mockTreasuryMint);
            config.treasuryToken = address(mockToken);
            seed.usedMockTreasuryToken = true;
        }

        DACConfig memory dacConfig = DACConfig({
            symbol: config.symbol,
            name: config.name,
            description: config.description,
            mainTokenMaxSupply: config.mainTokenMaxSupply,
            defaultQuorum: config.defaultQuorum,
            founder: seed.founder,
            founderAllocation: config.founderAllocation,
            treasuryToken: config.treasuryToken,
            founderCommitment: config.founderCommitment,
            dividendsEnabled: config.dividendsEnabled
        });

        bytes32 salt = keccak256(abi.encode(config.label, seed.founder, block.chainid, protocol.dacFactory));
        (seed.dac, seed.mainToken, seed.agentToken) = DACFactory(protocol.dacFactory).deployDAC(dacConfig, salt, address(0));

        seed.treasuryToken = config.treasuryToken;

        IERC20(config.treasuryToken).approve(DACCell(seed.dac).getAssetController(), config.founderCommitment);

        CapitalCall memory call = CapitalCall({
            treasuryToken: config.treasuryToken,
            nonce: 0,
            tokenRecipient: seed.founder,
            tokenAmount: config.founderAllocation,
            cashAmount: config.founderCommitment
        });

        DACCell(seed.dac).fulfillCapitalCall(call);
        MainToken(seed.mainToken).delegate(seed.founder);
        seed.dealManager = address(DACCell(seed.dac).getDealManager());
        seed.blockNumber = block.number;

        vm.stopBroadcast();

        string memory manifestPath = writeBasicDACSeedManifest(seed);

        console2.log("Basic DAC seeded");
        console2.log("  label:", seed.label);
        console2.log("  dac:", seed.dac);
        console2.log("  mainToken:", seed.mainToken);
        console2.log("  agentToken:", seed.agentToken);
        console2.log("  treasuryToken:", seed.treasuryToken);
        console2.log("  dealManager:", seed.dealManager);
        console2.log("  manifest:", manifestPath);
    }
}
