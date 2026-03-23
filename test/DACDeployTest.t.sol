// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACCell} from "../src/kernel/DACCell.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../src/kernel/tokens/factories/TokenFactories.sol";
import {DACManagementProposalFactory} from "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {DACCellFactory} from "../src/kernel/factories/DACCellFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {DealManagerFactory} from "../src/kernel/factories/DealManagerFactory.sol";
import {ModuleRegistryFactory} from "../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../src/kernel/factories/AssetControllerFactory.sol";
import {DACFactory} from "../src/kernel/DACFactory.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDACFactory} from "../src/interfaces/IDACFactory.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {DACConfig, CapitalCall, ProposalParams, DealParams} from "../src/interfaces/Structs.sol";
import {CoreModuleFactory} from "../src/modules/core/CoreModuleFactory.sol";
import {DACDealFactory} from "../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneEvaluatorFactory} from "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";

contract DACDeployTest is Test {
    DACCell dac;
    MainToken mainToken;
    AgentToken agentToken;

    CoreModuleFactory coreModule;
    
    DACManagementProposalFactory governanceFactory;
    DACFactory dacFactory;
    
    address owner = address(1);
    address user = address(2);

    address permit2 = address(10);

    function setUp() public {
        vm.startPrank(owner);

        coreModule = new CoreModuleFactory(
            address(new DealCellFactory()),
            address(new DACDealFactory()),
            address(new StakedAgentFactory()),
            address(new TreasuryDealFactory(permit2)),
            address(new MilestoneEvaluatorFactory()),
            address(new RevenueEvaluatorFactory())
        );
        
        governanceFactory = new DACManagementProposalFactory();

        dacFactory = new DACFactory(
            address(new MainTokenFactory()),
            address(new AgentTokenFactory()),
            address(new DACCellFactory()),
            address(new DealManagerFactory()),
            address(new ModuleRegistryFactory()),
            address(new NativeAssetControllerFactory()),
            address(governanceFactory), 
            address(coreModule)
        );

        vm.stopPrank();

        DACConfig memory config = DACConfig({
            symbol: "DACX",
            name: "DAC exchange",
            description: "future of finance",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: user,
            founderAllocation: 200_000_000e18,
            treasuryToken: address(0),
            founderCommitment: 20_000,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("MyFirstDAC-v1", block.timestamp));

        (address dacAddress, address lpAddress, address mpAddress) = dacFactory.deployDAC(
            config, salt, address(0)
        );

        mainToken = MainToken(lpAddress);
        agentToken = AgentToken(mpAddress);

        dac = DACCell(dacAddress);
    }

    function testDeployment() public {
        assertEq(dac.getMainToken(), address(mainToken), "Wrong main token");
    }
}
