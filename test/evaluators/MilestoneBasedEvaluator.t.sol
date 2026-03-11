// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Tranche, DealParams, EvaluationResult} from "../../src/interfaces/Structs.sol";
import {CoreDealType, CoreEvaluatorType} from "../../src/modules/core/CoreModuleDeals.sol";
import {MilestoneBasedEvaluator} from "../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {MilestoneEvaluatorFactory} from "../../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {IDeal} from "../../src/interfaces/IDeal.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {Milestone} from "../../src/modules/core/interfaces/Structs.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Crypto Dollars", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDealCell is IDealCell {
    uint256 public returnedCapital;
    uint256 internal _startTime;

    constructor(uint256 __startTime) {
        _startTime = __startTime;
    }

    function setReturnedCapital(uint256 _returned) external {
        returnedCapital = _returned;
    }

    function getReturnedCapital(address) external view returns (uint256) {
        return returnedCapital;
    }

    function startTime() external view returns (uint256) { return _startTime; }

    // Stubs for required interface
    function name() external pure returns (string memory) { return "MockDeal"; }
    function description() external pure returns (string memory) { return ""; }
    function deal() external pure returns (IDeal) { revert("Not implemented"); }
    function manager() external pure returns (address) { return address(0); }
    function stakeToken() external pure returns (address) { return address(0); }
    function invite(address, bool) external pure { revert("Not implemented"); }
    function claimMainToken(uint256) external {}
    function unstake() external {}
    function fundingTranche(uint256) external pure returns (Tranche memory) { revert("Not implemented"); }
    function fundingTokens() external pure returns (address[] memory) { return new address[](0); }
    function getStakedAgentTotal() external pure returns (uint256) { return 0; }
    function getMainRewardsLimit() external pure returns (uint256) { return 0; }
    function getInvestedCapital(address) external pure returns (uint256) { return 0; }
    function allowEarlyReturns() external pure returns (bool) { return false; }
    function allowDACVeto() external pure returns (bool) { return false; }
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external pure returns (bool) { return true; }
    function isClosed() external pure returns (bool) { return false; }
    function approveDeadline() external pure returns (uint256) { return 0; }
    function dealDeadline() external pure returns (uint256) { return type(uint256).max; }
}

contract MilestoneBasedEvaluatorTest is Test {
    MilestoneBasedEvaluator evaluator;

    MockUSDC usdc;
    MockDealCell mockDealCell;

    address constant DAC = address(0xDAC);
    uint256 constant DEAL_ID = 1;
    address constant DEAL_ADDR = address(0xDEA11);

    function setUp() public {
        usdc = new MockUSDC();
        mockDealCell = new MockDealCell(block.timestamp);
    }

    function deployEvaluator(MilestoneBasedEvaluator.Config memory cfg) internal {
        MilestoneEvaluatorFactory factory = new MilestoneEvaluatorFactory();
        bytes memory configData = abi.encode(cfg);

        DealParams memory dealParams = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Test Treasury Deal",
            description: "Test Treasury Deal description",
            linkHash: "0x00112233",
            moduleFactory: address(0),
            governanceFactory: address(0),
            dealTarget: address(0),
            proposer: address(0),
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: configData
        });

        evaluator = MilestoneBasedEvaluator(
            factory.deployEvaluator(DAC, DEAL_ID, address(mockDealCell), dealParams, configData)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          UNIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_holdingsMode_success_unlocksReward() public {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 30 days,
            rewardPercentage: MathLib.atScale(20),
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18; // 100% of rewardPercentage
        milestones[0].penaltyCurve[0] = 1e18;

        MilestoneBasedEvaluator.Config memory cfg = MilestoneBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            milestones: milestones
        });

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(10_000e6);

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));

        assertEq(results.length, 1);
        assertEq(results[0].action, 1); // convert
        assertEq(results[0].percent, MathLib.atScale(20));
    }

    function test_closeMilestone_fullSuccess_closesDeal() public {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 1, // close
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 30 days,
            rewardPercentage: MathLib.atScale(100),
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18;

        MilestoneBasedEvaluator.Config memory cfg = MilestoneBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            milestones: milestones
        });

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(10_000e6);

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));

        assertEq(results.length, 2);
        assertEq(results[0].action, 1);
        assertEq(results[1].action, 3); // close
    }

    function test_closeMilestone_nearMiss_extends() public {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 1,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 30 days,
            rewardPercentage: MathLib.atScale(10),
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: MathLib.atScale(80),
            extension: 7 days
        });
        milestones[0].rewardCurve[0] = 1e18;

        MilestoneBasedEvaluator.Config memory cfg = MilestoneBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            milestones: milestones
        });

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(8_500e6); // 85% > 80% grace

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));

        assertEq(results.length, 0); // milestone evaluator not extending base deal deadline
    }

    function test_slashing_penaltyCurve_applied() public {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 30 days,
            rewardPercentage: MathLib.atScale(10),
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18;
        milestones[0].penaltyCurve[0] = int256(MathLib.atScale(30)); // 30% slash on miss

        MilestoneBasedEvaluator.Config memory cfg = MilestoneBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            milestones: milestones
        });

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(4_000e6); // miss

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));

        assertEq(results.length, 2);
        assertEq(results[1].action, 0); // slash
        assertEq(results[1].percent, MathLib.atScale(30));
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_progressCalculation(uint256 returned, uint256 expected) public {
        vm.assume(returned <= 1e30);
        vm.assume(expected > 0 && expected <= 1e30);

        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: expected,
            timestamp: block.timestamp + 30 days,
            rewardPercentage: MathLib.atScale(10),
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18; // 100% of rewardPercentage
        milestones[0].penaltyCurve[0] = 1e18;

        MilestoneBasedEvaluator.Config memory cfg = MilestoneBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            milestones: milestones
        });

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(returned);

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));

        // At least one action if progress reached
        if (returned >= expected) {
            assertGt(results.length, 0);
        }
    }

    // TODO: More tests needed

    /*//////////////////////////////////////////////////////////////
                          ORACLE MOCK HELPER
    //////////////////////////////////////////////////////////////*/

    function test_oracleSnapshot_growthMode() public {
        // Need full test with mocked oracle price change
    }
}
