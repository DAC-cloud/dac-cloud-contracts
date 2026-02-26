// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/kernel/DACCell.sol";
import "../src/kernel/tokens/MainToken.sol";
import "../src/kernel/tokens/AgentToken.sol";
import "../src/modules/core/CoreModuleFactory.sol";
import "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import "../src/kernel/DACFactory.sol";
import "../src/interfaces/IDACFactory.sol";
import "../src/interfaces/Structs.sol";

contract DACTest is Test {
    DACCell dac;
    MainToken mainToken;
    AgentToken agentToken;

    CoreModuleFactory coreModule;
    
    DACManagementProposalFactory governanceFactory;
    DACFactory dacFactory;
    
    address owner = address(1);
    address user = address(2);

    function setUp() public {
        vm.startPrank(owner);

        coreModule = new CoreModuleFactory();
        
        governanceFactory = new DACManagementProposalFactory();

        dacFactory = new DACFactory(
            address(governanceFactory), 
            address(coreModule)
        );

        vm.stopPrank();

        DACConfig memory config = DACConfig({
            symbol: "",
            name: "",
            description: "",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: 50,
            founder: user,
            founderAllocation: 200_000_000e18,
            treasuryToken: address(0),
            founderCommitment: 1e18,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("MyFirstDAC-v1", block.timestamp));

        (address dacAddress, address lpAddress, address mpAddress) = dacFactory.deployDAC(
            config, salt
        );

        mainToken = MainToken(lpAddress);
        agentToken = AgentToken(mpAddress);

        dac = DACCell(dacAddress);
    }

    function testDeployment() public {
        //assertEq(dac.getQuorumPercent(), 50);
    }
}