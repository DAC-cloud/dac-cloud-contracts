// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/DACEntity.sol";
import "../src/LPToken.sol";
import "../src/MPToken.sol";
import "../src/DealFactory.sol";
import "../src/EvaluatorFactory.sol";
import "../src/LPManagementFactory.sol";
import "../src/VotingFactory.sol";
import "../src/DACFactory.sol";
import "../src/IDACFactory.sol";

contract DACTest is Test {
    DACEntity dac;
    LPToken lpToken;
    MPToken mpToken;
    DealFactory dealFactory;
    EvaluatorFactory evaluatorFactory;
    LPManagementFactory lpFactory;
    VotingFactory votingFactory;
    DACFactory dacFactory;
    address owner = address(1);
    address user = address(2);

    function setUp() public {
        vm.startPrank(owner);

        dealFactory = new DealFactory();
        evaluatorFactory = new EvaluatorFactory();
        lpFactory = new LPManagementFactory();
        votingFactory = new VotingFactory();

        dacFactory = new DACFactory(
            address(votingFactory), 
            address(lpFactory), 
            address(dealFactory),
            address(evaluatorFactory)
        );

        vm.stopPrank();

        IDACFactory.DACConfig memory config = IDACFactory.DACConfig({
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