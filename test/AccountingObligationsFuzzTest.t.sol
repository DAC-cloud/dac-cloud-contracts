// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {MockEvaluatorModuleFactory, MockEvaluator} from "./DealEvaluationRecoveryTest.t.sol";
import {DealParams, EvaluationResult, ProposalParams} from "../src/interfaces/Structs.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {DealManager} from "../src/kernel/DealManager.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {DealState} from "../src/kernel/interfaces/Structs.sol";
import {IDealManagerAdapter} from "../src/kernel/interfaces/IDealManagerAdapter.sol";
import {CoreDealType} from "../src/modules/core/CoreModuleDeals.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";

contract AccountingObligationsFuzzTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    uint256 internal constant REWARDS_LIMIT = 500e6;
    bytes4 internal constant FUZZ_MOCK_EVALUATOR_SELECTOR = bytes4(keccak256("MOCK_EVALUATOR"));

    MockEvaluatorModuleFactory mockModule;

    function setUp() public {
        setUpBase();

        onboardAgent(agent1);
        onboardAgent(agent2);

        vm.prank(moduleOwner);
        mockModule = new MockEvaluatorModuleFactory(permit2);

        _approveModule(address(mockModule));
    }

    function testFuzz_rewardUnlocksClaimsAndClose_preserveObligations(
        uint8[6] memory rawPercents,
        uint16 claimMask
    ) public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        uint256 usedPercent;
        uint256 baseAgent1 = mainToken.balanceOf(agent1);
        uint256 baseAgent2 = mainToken.balanceOf(agent2);

        for (uint256 i = 0; i < rawPercents.length; i++) {
            if (usedPercent == MathLib.SCALE) break;

            uint256 remainingPercent = MathLib.SCALE - usedPercent;
            uint256 stepPercent = MathLib.mulDiv(remainingPercent, rawPercents[i], type(uint8).max);
            if (stepPercent == 0) continue;

            _setSingleEvaluationResult(handle.evaluatorAddr, 1, stepPercent, 0);
            vm.prank(agent1);
            DealManager(dealManager).evaluateDeal(handle.dealId, 0);

            usedPercent += stepPercent;

            if ((claimMask & uint16(1 << i)) != 0) {
                _claimIfPossible(agent1, handle.dealCell);
            }

            if ((claimMask & uint16(1 << (i + 6))) != 0) {
                _claimIfPossible(agent2, handle.dealCell);
            }

            _assertRewardAccounting(handle.dealCell);
        }

        if (!IDealCell(handle.dealCell).isClosed()) {
            _setSingleEvaluationResult(handle.evaluatorAddr, 3, 0, 0);
            vm.prank(agent1);
            DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        }

        DealState memory state = _state(handle.dealCell);
        assertEq(DealManager(dealManager).mainTokenObligations(), state.rewardsUnlocked - state.rewardsPaid);
        assertLe(state.rewardsPaid, state.rewardsUnlocked);
        assertLe(state.rewardsUnlocked, state.rewardsLimit);

        _claimIfPossible(agent1, handle.dealCell);
        _claimIfPossible(agent2, handle.dealCell);

        state = _state(handle.dealCell);
        assertEq(DealManager(dealManager).mainTokenObligations(), 0);
        assertEq(state.rewardsUnlocked, state.rewardsPaid);
        assertEq(mainToken.balanceOf(agent1) + mainToken.balanceOf(agent2), baseAgent1 + baseAgent2 + state.rewardsPaid);
    }

    function testFuzz_repeatedSlashes_preserveStakeBacking(uint8[8] memory rawPercents) public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();
        StakedAgent stakeToken = StakedAgent(IDealCell(handle.dealCell).stakeToken());

        for (uint256 i = 0; i < rawPercents.length; i++) {
            uint256 currentSupply = stakeToken.totalSupply();
            if (currentSupply == 0) break;

            uint256 slashPercent = MathLib.mulDiv(MathLib.SCALE, rawPercents[i], type(uint8).max);
            if (slashPercent == 0) continue;

            _setSingleEvaluationResult(handle.evaluatorAddr, 0, slashPercent, 0);
            vm.prank(agent1);
            DealManager(dealManager).evaluateDeal(handle.dealId, 0);

            assertEq(stakeToken.totalSupply(), agentToken.balanceOf(handle.dealCell));
            assertEq(stakeToken.balanceOf(agent1) + stakeToken.balanceOf(agent2), stakeToken.totalSupply());
        }

        assertEq(stakeToken.totalSupply(), agentToken.balanceOf(handle.dealCell));
    }

    function _approveModule(address moduleFactory) internal {
        vm.startPrank(founder);

        uint256 proposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE,
                target: moduleFactory,
                i: 0,
                data: bytes("")
            })
        );

        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(proposalId)).vote(true);
        dac.executeDACProposal(proposalId);

        vm.stopPrank();
    }

    function _createMockTreasuryDeal(address proposer) internal returns (DealHandle memory handle) {
        vm.recordLogs();

        vm.startPrank(proposer);

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Accounting Fuzz Deal",
            description: "Treasury deal with mock evaluator",
            linkHash: "0x00fuzz",
            moduleFactory: address(mockModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: proposer,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: REWARDS_LIMIT,
            approveDeadline: block.timestamp + 1 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: FUZZ_MOCK_EVALUATOR_SELECTOR,
            dealConfig: abi.encode("accounting fuzz config"),
            evaluatorConfig: abi.encode(address(this), new EvaluationResult[](0))
        });

        (handle.dealId, handle.dealCell, handle.dealAddr, handle.evaluatorAddr) =
            DealManager(dealManager).createDealProposal(params);

        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }

    function _setupApprovedMockTreasuryDeal() internal returns (DealHandle memory handle) {
        handle = _createMockTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);

        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        assertEq(DealManager(dealManager).mainTokenObligations(), REWARDS_LIMIT);
    }

    function _stakeAndDelegate(address agent, address dealCell, uint256 amount) internal {
        vm.startPrank(agent);
        agentToken.stakeToDeal(dealCell, amount);
        StakedAgent(IDealCell(dealCell).stakeToken()).delegate(agent);
        vm.stopPrank();
    }

    function _setSingleEvaluationResult(address evaluatorAddr, uint8 action, uint256 percent, uint256 extendTo) internal {
        EvaluationResult[] memory results = new EvaluationResult[](1);
        results[0] = EvaluationResult(action, percent, extendTo);
        MockEvaluator(evaluatorAddr).setResults(results);
    }

    function _claimIfPossible(address claimer, address dealCell) internal returns (bool ok) {
        vm.prank(claimer);
        (ok,) = dealCell.call(abi.encodeCall(IDealCell.claimMainToken, (0)));
    }

    function _assertRewardAccounting(address dealCell) internal {
        DealState memory state = _state(dealCell);
        uint256 expectedObligations = IDealCell(dealCell).isClosed()
            ? state.rewardsUnlocked - state.rewardsPaid
            : state.rewardsLimit - state.rewardsPaid;

        assertLe(state.rewardsPaid, state.rewardsUnlocked);
        assertLe(state.rewardsUnlocked, state.rewardsLimit);
        assertEq(DealManager(dealManager).mainTokenObligations(), expectedObligations);
    }

    function _state(address dealCell) internal returns (DealState memory state) {
        state = IDealManagerAdapter(dealManager).state(dealCell);
    }

    function _paid(address dealCell) internal returns (uint256) {
        return _state(dealCell).rewardsPaid;
    }
}
