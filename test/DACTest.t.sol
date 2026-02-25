// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/kernel/DACEntity.sol";
import "../src/kernel/tokens/LPToken.sol";
import "../src/kernel/tokens/MPToken.sol";
import "../src/modules/core/CoreModuleFactory.sol";
import "../src/kernel/governance/factories/LPManagementProposalFactory.sol";
import "../src/kernel/DACFactory.sol";
import "../src/interfaces/IDACFactory.sol";
import "../src/interfaces/Structs.sol";

contract DACTest is Test {
    DACEntity dac;
    LPToken lpToken;
    MPToken mpToken;

    CoreModuleFactory coreModule;
    
    LPManagementProposalFactory lpFactory;
    DACFactory dacFactory;
    
    address owner = address(1);
    address user = address(2);

    function setUp() public {
        vm.startPrank(owner);

        coreModule = new CoreModuleFactory();
        
        lpFactory = new LPManagementProposalFactory();

        dacFactory = new DACFactory(
            address(lpFactory), 
            address(coreModule)
        );

        vm.stopPrank();

        DACConfig memory config = DACConfig({
            symbol: "",
            name: "",
            description: "",
            lpMaxSupply: 1_000_000_000,
            defaultQuorum: 50,
            founder: user,
            founderLP: 200_000_000,
            treasuryToken: address(0),
            founderCommitment: 1_000
        });

        bytes32 salt = keccak256(abi.encode("MyFirstDAC-v1", block.timestamp));

        (address dacAddress, address lpAddress, address mpAddress) = dacFactory.deployDAC(
            config, salt
        );

        lpToken = LPToken(lpAddress);
        mpToken = MPToken(mpAddress);

        dac = DACEntity(dacAddress);
    }

    function testDeployment() public {
        //assertEq(dac.getQuorumPercent(), 50);
    }
}