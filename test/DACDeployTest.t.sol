// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/kernel/DACCell.sol";
import "../src/kernel/tokens/MainToken.sol";
import "../src/kernel/tokens/AgentToken.sol";
import "../src/kernel/tokens/factories/TokenFactories.sol";
import "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import "../src/kernel/factories/DealManagerFactory.sol";
import "../src/kernel/factories/DealCellFactory.sol";
import "../src/kernel/DACFactory.sol";
import "../src/kernel/libraries/MathLib.sol";
import "../src/interfaces/IDACFactory.sol";
import "../src/interfaces/Structs.sol";
import "../src/modules/core/CoreModuleFactory.sol";
import "../src/modules/core/deals/factories/DACDealFactory.sol";
import "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";

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