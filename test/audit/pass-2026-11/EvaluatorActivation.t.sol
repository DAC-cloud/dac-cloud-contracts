// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Evaluators measure a deal from its activation (M-04).
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.
//   test_CONTROL_* the baseline a scenario is measured against.

import "forge-std/Test.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {DealParams, ProposalParams, EvaluationResult} from "../../../src/interfaces/Structs.sol";
import {IEvaluator, IEvaluatorActivation} from "../../../src/interfaces/IEvaluator.sol";
import {IEvaluatorFactory} from "../../../src/interfaces/modules/IEvaluatorFactory.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {TreasuryDealFactory} from "../../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MockEvaluatorModuleFactory, MOCK_EVALUATOR_SELECTOR} from "../../DealEvaluationRecoveryTest.t.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {StakedAgent} from "../../../src/kernel/tokens/StakedAgent.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {CoreDealType, CoreEvaluatorType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {MilestoneBasedEvaluator} from "../../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {RevenueBasedEvaluator} from "../../../src/modules/core/evaluators/RevenueBasedEvaluator.sol";
import {Milestone, RevenueSchedule} from "../../../src/modules/core/interfaces/Structs.sol";
import {IPriceOracle} from "../../../src/modules/core/interfaces/IPriceOracle.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";

contract ActivationPermit2Stub {
    function approve(address, address, uint160, uint48) external pure {}
}

contract ActivationPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function tokenPrice(address token) external view returns (uint256) {
        return prices[token];
    }
}

/// Does a fixed amount of work for whoever calls it.
contract GasWorker {
    mapping(uint256 => uint256) internal slots;
    uint256 internal next;

    // About 22k gas per unit: one fresh storage slot each.
    function work(uint256 units) external {
        uint256 from = next;
        for (uint256 i = 0; i < units; i++) {
            slots[from + i] = 1;
        }
        next = from + units;
    }
}

/// Evaluator whose activation hook behaves as configured.
contract HookEvaluator is IEvaluator, IEvaluatorActivation {
    uint8 public immutable mode; // 0 works then succeeds, 1 reverts, 2 never finishes, 3 works in a nested call
    uint256 public immutable units;
    GasWorker public immutable worker;

    bool public activated;
    mapping(uint256 => uint256) internal slots;

    constructor(uint8 _mode, uint256 _units) {
        mode = _mode;
        units = _units;
        worker = new GasWorker();
    }

    function onDealActivated() external override {
        if (mode == 1) revert("reference not available");
        if (mode == 2) {
            while (true) {}
        }
        if (mode == 3) {
            // A failure of the nested call, out of gas included, bubbles up.
            worker.work(units);
        } else {
            for (uint256 i = 0; i < units; i++) {
                slots[i] = 1;
            }
        }
        activated = true;
    }

    function permitMint(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function evaluateDeal(uint256, address, address, address) external pure returns (EvaluationResult[] memory) {
        return new EvaluationResult[](0);
    }
}

contract HookEvaluatorFactory is IEvaluatorFactory {
    function deployEvaluator(address, uint256, address, DealParams calldata, bytes calldata evaluatorConfig)
        external
        returns (address)
    {
        (uint8 mode, uint256 units) = abi.decode(evaluatorConfig, (uint8, uint256));
        return address(new HookEvaluator(mode, units));
    }
}

/// M-04. A deal is proposed, voted on for days, and only then approved. Its evaluators
/// count cycles and take reference prices from the approval, not from the proposal.
contract EvaluatorActivation is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    ActivationPriceOracle internal priceOracle;
    address internal constant PRICED_TOKEN = address(0xBEEF);
    MockEvaluatorModuleFactory internal hookModule;

    bytes32 internal constant ACTIVATION_SKIPPED = keccak256("EvaluatorActivationSkipped(address,uint256,address)");

    function setUp() public {
        setUpBase();
        vm.etch(permit2, address(new ActivationPermit2Stub()).code);
        onboardAgent(agent1);
        onboardAgent(agent2);
        priceOracle = new ActivationPriceOracle();

        // A module whose evaluators have a configurable activation hook.
        vm.prank(moduleOwner);
        hookModule = new MockEvaluatorModuleFactory(
            address(new TreasuryDealFactory(permit2)), address(new HookEvaluatorFactory())
        );
        vm.startPrank(founder);
        uint256 pid = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(hookModule), i: 0, data: bytes("")
            })
        );
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(pid)).vote(true);
        dac.executeDACProposal(pid);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        revenue schedule
    //////////////////////////////////////////////////////////////*/

    function _schedule(uint256 evaluationStart) internal view returns (RevenueSchedule memory schedule) {
        schedule = RevenueSchedule({
            token: address(usdc),
            duration: 1 days,
            revenueProjectionMode: 0,
            revenueProjection: 1_000e6,
            curveCoeffs: new int256[](2),
            requirementCurveCoeffs: new int256[](1),
            maxCycleUnlockPercent: 5e16,
            minCycleRevenuePercent: 5e17,
            graceCycles: 1,
            penaltyPerMiss: 1e17,
            evaluationStart: evaluationStart,
            autoClose: false,
            excludePrincipal: true
        });
        schedule.curveCoeffs[0] = 0;
        schedule.curveCoeffs[1] = 1e18;
        schedule.requirementCurveCoeffs[0] = 1e18;
    }

    function _revenueDeal(uint256 evaluationStart) internal returns (DealHandle memory handle) {
        handle = _createTreasuryDealWith(
            agent1,
            CoreEvaluatorType.REVENUE_EVALUATOR,
            abi.encode(RevenueBasedEvaluator.Config(MathLib.atScale(100), _schedule(evaluationStart)))
        );
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
    }

    function _approveAfter(DealHandle memory handle, uint256 delay) internal returns (uint256 approvedAt) {
        vm.warp(block.timestamp + delay);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();
        assertTrue(IDealCell(handle.dealCell).isApproved());
        approvedAt = IDealCell(handle.dealCell).approvedAt();
        assertEq(approvedAt, block.timestamp);
    }

    // The DAC takes five days to approve. No cycle is counted for those five days.
    function test_REG_M04_revenueSchedule_countsFromApproval() public {
        DealHandle memory handle = _revenueDeal(0);
        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        RevenueBasedEvaluator evaluator = RevenueBasedEvaluator(handle.evaluatorAddr);

        uint256 approvedAt = _approveAfter(handle, 5 days + 10);

        // Evaluated in the block of its approval: the deal has been live for zero seconds.
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(stake.balanceOf(agent1), 20_000, "nothing slashed");
        assertEq(evaluator.totalEvaluatedCycles(), 0, "no cycle has run yet");
        assertEq(evaluator.lastChecked(), approvedAt, "the schedule starts at the approval");

        // The first cycle ends one period after the approval.
        vm.warp(approvedAt + 1 days - 1);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.totalEvaluatedCycles(), 0);

        vm.warp(approvedAt + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.totalEvaluatedCycles(), 1);
        assertEq(stake.balanceOf(agent1), 20_000, "first miss is within the grace cycle");
    }

    // An explicit start that falls before the approval is moved up to it as well.
    function test_REG_M04_explicitStartBeforeApproval_movesToApproval() public {
        DealHandle memory handle = _revenueDeal(block.timestamp + 1 days);
        RevenueBasedEvaluator evaluator = RevenueBasedEvaluator(handle.evaluatorAddr);

        uint256 approvedAt = _approveAfter(handle, 5 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(evaluator.lastChecked(), approvedAt);
        assertEq(evaluator.totalEvaluatedCycles(), 0);
    }

    // Control: a start set after the approval is the proposer's choice and is kept.
    function test_CONTROL_M04_explicitStartAfterApproval_isKept() public {
        uint256 start = block.timestamp + 10 days;
        DealHandle memory handle = _revenueDeal(start);
        RevenueBasedEvaluator evaluator = RevenueBasedEvaluator(handle.evaluatorAddr);

        _approveAfter(handle, 5 days);

        vm.warp(start + 1 days - 1);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.lastChecked(), start);
        assertEq(evaluator.totalEvaluatedCycles(), 0);

        vm.warp(start + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.totalEvaluatedCycles(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                    growth milestone: reference price
    //////////////////////////////////////////////////////////////*/

    // One milestone: the priced token must be worth 1.5x its reference price by the
    // milestone date. Reached pays everything; missed pays nothing and slashes everything.
    function _growthDeal() internal returns (DealHandle memory handle) {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: PRICED_TOKEN,
            oracle: address(priceOracle),
            valuationMode: 2,
            fundingToken: address(0),
            expectedReturn: 15e17,
            timestamp: block.timestamp + 10 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0,
            excludePrincipal: false
        });
        milestones[0].rewardCurve[0] = 0;
        milestones[0].penaltyCurve[0] = 1e18;

        handle = _createTreasuryDealWith(
            agent1,
            CoreEvaluatorType.MILESTONES_EVALUATOR,
            abi.encode(MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones))
        );
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
    }

    // The price doubles while the DAC is still voting. That move happened before the deal
    // existed and earns nothing: growth is measured from the price at approval.
    function test_REG_M04_growthBaseline_isThePriceAtApproval() public {
        priceOracle.setPrice(PRICED_TOKEN, 1e18);
        DealHandle memory handle = _growthDeal();
        MilestoneBasedEvaluator evaluator = MilestoneBasedEvaluator(handle.evaluatorAddr);
        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());

        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 0, "no reference price before the deal is live");

        priceOracle.setPrice(PRICED_TOKEN, 2e18);
        _approveAfter(handle, 5 days);
        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 2e18, "reference price taken at approval");

        // The price stays where it was at approval: growth is 1.0x, not the 2.0x since proposal.
        vm.warp(block.timestamp + 6 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(IDealCell(handle.dealCell).rewardsConvertedPct(), 0, "milestone not reached");
        assertEq(stake.balanceOf(agent1), 0, "and its penalty applied");
    }

    // Control: the same move after the approval is the agents' result and is paid.
    function test_CONTROL_M04_growthAfterApproval_reachesTheMilestone() public {
        priceOracle.setPrice(PRICED_TOKEN, 1e18);
        DealHandle memory handle = _growthDeal();
        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());

        priceOracle.setPrice(PRICED_TOKEN, 2e18);
        _approveAfter(handle, 5 days);

        priceOracle.setPrice(PRICED_TOKEN, 3e18); // 1.5x the price at approval
        vm.warp(block.timestamp + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(IDealCell(handle.dealCell).rewardsConvertedPct(), MathLib.SCALE);
        assertEq(stake.balanceOf(agent1), 20_000);
    }

    // A reference price the oracle cannot give at approval is taken at the first evaluation
    // instead; the approval itself is never held up by an evaluator.
    function test_REG_M04_oracleSilentAtApproval_doesNotBlockIt() public {
        priceOracle.setPrice(PRICED_TOKEN, 1e18);
        DealHandle memory handle = _growthDeal();
        MilestoneBasedEvaluator evaluator = MilestoneBasedEvaluator(handle.evaluatorAddr);

        priceOracle.setPrice(PRICED_TOKEN, 0);
        _approveAfter(handle, 5 days);
        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 0);

        priceOracle.setPrice(PRICED_TOKEN, 4e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 4e18);
    }

    /*//////////////////////////////////////////////////////////////
            the activation hook: no gas limit, no silent skip
    //////////////////////////////////////////////////////////////*/

    // A staked deal whose evaluator's hook has the given behaviour, with the DAC's
    // approval voted and ready to execute.
    function _hookDeal(uint8 mode, uint256 units) internal returns (DealHandle memory handle, HookEvaluator evaluator) {
        handle = _createDealWith(agent1, address(hookModule), MOCK_EVALUATOR_SELECTOR, abi.encode(mode, units));
        evaluator = HookEvaluator(handle.evaluatorAddr);
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        address approval = dac.getProposalVoting(handle.proposalId);
        vm.prank(founder);
        IVoting(approval).vote(true);
    }

    function _skips(Vm.Log[] memory logs, address evaluator) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ACTIVATION_SKIPPED && address(uint160(uint256(logs[i].topics[3]))) == evaluator) {
                n++;
            }
        }
    }

    // A hook that needs well over a million gas simply gets it.
    function test_REG_activationHook_hasNoFixedGasLimit() public {
        (DealHandle memory handle, HookEvaluator evaluator) = _hookDeal(0, 120); // about 2.7M gas

        vm.recordLogs();
        uint256 g = gasleft();
        dac.executeDACProposal(handle.proposalId);
        emit log_named_uint("approval with a heavy activation hook, gas", g - gasleft());

        assertTrue(IDealCell(handle.dealCell).isApproved());
        assertTrue(evaluator.activated());
        assertEq(_skips(vm.getRecordedLogs(), address(evaluator)), 0);
    }

    // A hook that reverts for a reason of its own is reported and does not hold up the approval.
    function test_REG_activationHook_ownFailureIsReportedAndSkipped() public {
        (DealHandle memory handle, HookEvaluator evaluator) = _hookDeal(1, 0);

        vm.recordLogs();
        dac.executeDACProposal(handle.proposalId);

        assertTrue(IDealCell(handle.dealCell).isApproved());
        assertFalse(evaluator.activated());
        assertEq(_skips(vm.getRecordedLogs(), address(evaluator)), 1);
    }

    // Whatever gas the approval is sent with, it either reverts or runs the hook to the
    // end: no gas limit lets a caller approve the deal with the activation left out.
    function _assertNeverApprovedWithoutActivation(uint8 mode) internal {
        (DealHandle memory handle, HookEvaluator evaluator) = _hookDeal(mode, 120);

        uint256 approvedRuns;
        uint256 revertedRuns;
        for (uint256 gasLimit = 300_000; gasLimit <= 4_500_000; gasLimit += 50_000) {
            uint256 snap = vm.snapshotState();
            try dac.executeDACProposal{gas: gasLimit}(handle.proposalId) {
                assertTrue(evaluator.activated(), "approved with the activation left out");
                approvedRuns++;
            } catch {
                assertFalse(IDealCell(handle.dealCell).isApproved());
                revertedRuns++;
            }
            vm.revertToState(snap);
        }
        // The sweep crosses the point where the hook starts to fit.
        assertGt(approvedRuns, 0);
        assertGt(revertedRuns, 0);
    }

    function test_REG_activationHook_cannotBeLeftOutByUnderfundingTheCall() public {
        _assertNeverApprovedWithoutActivation(0);
    }

    // Same when the hook runs out of gas one call deeper and the failure bubbles up.
    function test_REG_activationHook_cannotBeLeftOut_nestedCall() public {
        _assertNeverApprovedWithoutActivation(3);
    }

    // A hook that can never finish keeps its own deal from being approved. Nothing has
    // left the treasury at that point, and stakers get their stake back after the
    // approval deadline.
    function test_NOTE_activationHook_thatNeverFinishes_blocksItsOwnDeal() public {
        (DealHandle memory handle,) = _hookDeal(2, 0);
        uint256 treasuryBefore = usdc.balanceOf(dac.getAssetController());

        try dac.executeDACProposal{gas: 16_000_000}(handle.proposalId) {
            revert("approved although the hook never returned");
        } catch (bytes memory err) {
            assertEq(bytes4(err), DACErrorsLib.InsufficientGas.selector);
        }
        assertFalse(IDealCell(handle.dealCell).isApproved());
        assertEq(usdc.balanceOf(dac.getAssetController()), treasuryBefore);

        vm.warp(IDealCell(handle.dealCell).approveDeadline() + 1);
        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake();
        assertEq(agentToken.balanceOf(agent1), 100_000);
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    function _createTreasuryDealWith(address agent, bytes4 evaluatorSelector, bytes memory evaluatorConfig)
        internal
        returns (DealHandle memory handle)
    {
        return _createDealWith(agent, address(coreModule), evaluatorSelector, evaluatorConfig);
    }

    function _createDealWith(address agent, address module, bytes4 evaluatorSelector, bytes memory evaluatorConfig)
        internal
        returns (DealHandle memory handle)
    {
        vm.recordLogs();

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Treasury Deal",
            description: "evaluator activation",
            linkHash: "0x00",
            moduleFactory: module,
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 1_000e6,
            rewardsLimit: 1_000e18,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 7 days,
            evaluationDeadline: block.timestamp + 30 days,
            dealDeadline: block.timestamp + 60 days,
            dealConfig: abi.encode("deal config"),
            evaluatorSelector: evaluatorSelector,
            evaluatorConfig: evaluatorConfig,
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        vm.prank(agent);
        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) =
            IDealManager(dealManager).createDealProposal(params);

        handle.dealId = dealId;
        handle.dealCell = dealCell;
        handle.dealAddr = dealAddr;
        handle.evaluatorAddr = evaluatorAddr;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }
}
