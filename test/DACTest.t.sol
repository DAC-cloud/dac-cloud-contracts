// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DACEntity.sol";
import "../src/LPToken.sol";
import "../src/MPToken.sol";
import "../src/DealFactory.sol";
import "../src/EvaluatorFactory.sol";
import "../src/LPManagementFactory.sol";
import "../src/VotingFactory.sol";

contract DACTest is Test {
    DACEntity dac;
    LPToken lpToken;
    MPToken mpToken;
    DealFactory dealFactory;
    EvaluatorFactory evaluatorFactory;
    LPManagementFactory lpFactory;
    VotingFactory votingFactory;
    address owner = address(1);
    address user = address(2);

    function setUp() public {
        vm.startPrank(owner);
        dealFactory = new DealFactory();
        evaluatorFactory = new EvaluatorFactory();
        lpFactory = new LPManagementFactory();
        votingFactory = new VotingFactory();
        lpToken = new LPToken("LP Token", "LP", address(0)); // Temp for dac creation
        mpToken = new MPToken(1000, address(0), "MP Token", "MP");
        dac = new DACEntity(
            address(lpToken),
            address(mpToken),
            50,
            address(dealFactory),
            address(evaluatorFactory),
            address(lpFactory),
            address(votingFactory)
        );
        lpToken = new LPToken("LP Token", "LP", address(dac)); // Correct dac
        mpToken = new MPToken(1000, address(dac), "MP Token", "MP");
        vm.stopPrank();
    }

    function testDeployment() public {
        assertEq(dac.getQuorumPercent(), 50);
    }
}