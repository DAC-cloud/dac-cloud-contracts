// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Accounting properties that hold: reward caps under random
// conversions and tranches, sweep paths. test_VERIFY_* checks a property end to end.

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DACTestBase, MockUSDC} from "../../base/DACTestBase.t.sol";
import {
    DealParams,
    ProposalParams,
    EvaluationResult,
    CapitalCall,
    LegalWrapper,
    VotingConfig
} from "../../../src/interfaces/Structs.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "../../../src/kernel/interfaces/IDealManagerAdapter.sol";
import {DealState} from "../../../src/kernel/interfaces/Structs.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";
import {Deal} from "../../../src/kernel/Deal.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {CoreDealType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {TreasuryDeal} from "../../../src/modules/core/deals/TreasuryDeal.sol";
import {TreasuryDealFactory} from "../../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {
    MockEvaluator,
    MockEvaluatorFactory,
    MockEvaluatorModuleFactory,
    MOCK_EVALUATOR_SELECTOR
} from "../../DealEvaluationRecoveryTest.t.sol";

contract AccountingProperties is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public outsider = makeAddr("outsider");

    MockEvaluatorModuleFactory mockModule;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);

        vm.startPrank(moduleOwner);
        MockEvaluatorFactory evalFactory = new MockEvaluatorFactory();
        mockModule = new MockEvaluatorModuleFactory(address(new TreasuryDealFactory(permit2)), address(evalFactory));
        vm.stopPrank();

        _passDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(mockModule), i: 0, data: bytes("")
            })
        );
    }

    // ------------------------------------------------------------------ //
    // V-1  recoverERC20 (permissionless) never touches accounted balances //
    // ------------------------------------------------------------------ //
    function test_VERIFY_recoverERC20_onlyAddsFreeBalance_native() public {
        // Live deal with a reward reservation.
        DealHandle memory h = _createDeal(_mockTreasuryParams(agent1, 0));
        _stakeApprove(h);
        uint256 obligations = DealManager(dealManager).mainTokenObligations();
        assertEq(obligations, 500e6);

        address controller = dac.getAssetController();
        uint256 usdcBefore = usdc.balanceOf(controller);
        uint256 votableBefore = DealManager(dealManager).totalReleasedVotable();

        // Outsider donates USDC and main token to the cell and sweeps both.
        usdc.mint(address(dac), 777);
        vm.prank(founder);
        mainToken.transfer(address(dac), 1_000e18);
        assertEq(DealManager(dealManager).totalReleasedVotable(), votableBefore - 1_000e18);

        vm.startPrank(outsider);
        dac.recoverERC20(address(usdc));
        dac.recoverERC20(address(mainToken));
        vm.expectRevert(DACErrorsLib.NotEnoughBalance.selector);
        dac.recoverERC20(address(usdc));
        vm.stopPrank();

        assertEq(usdc.balanceOf(controller), usdcBefore + 777);
        assertEq(mainToken.balanceOf(controller), 1_000e18);
        assertEq(DealManager(dealManager).mainTokenObligations(), obligations, "obligations untouched");
        // Donated (released) main tokens stay out of the votable supply after the sweep.
        assertEq(DealManager(dealManager).totalReleasedVotable(), votableBefore - 1_000e18);

        // Agent / stake / deal balances cannot be swept: the cell never holds them.
        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotEnoughBalance.selector);
        dac.recoverERC20(address(agentToken));
    }

    // ------------------------------------------------------------------ //
    // V-2  Reward path under random conversions and tranche rescales      //
    // ------------------------------------------------------------------ //
    function testFuzz_VERIFY_rewardsNeverStuckNorOverpaid(
        uint64[6] memory rawPct,
        uint64[6] memory rawRewards,
        uint8 trancheMask,
        uint64 poolPct
    ) public {
        uint256 pool = bound(poolPct, 0, MathLib.SCALE);
        DealHandle memory h = _createDeal(_mockTreasuryParams(agent1, pool));
        _stakeApprove(h);

        uint256 supplyBefore = mainToken.totalSupply();

        for (uint256 i = 0; i < 6; i++) {
            if (IDealCell(h.dealCell).isClosed()) break;

            if ((trancheMask >> i) & 1 == 1) {
                // Tranche with extra rewards: rescales the converted percent.
                uint256 extra = bound(rawRewards[i], 0, 1_000_000e6);
                vm.recordLogs();
                _passDealProposal(
                    h,
                    ProposalParams({
                        typ: AbstractDealManagementType.REQUEST_TRANCHE,
                        target: address(usdc),
                        i: bytes32(uint256(1)),
                        data: abi.encode(extra)
                    })
                );
                uint256 dacPid = _trancheProposalId(vm.getRecordedLogs());
                vm.warp(block.timestamp + 1);
                vm.startPrank(founder);
                IVoting(dac.getProposalVoting(dacPid)).vote(true);
                dac.executeDACProposal(dacPid);
                vm.stopPrank();
            }

            uint256 pct = bound(rawPct[i], 0, MathLib.SCALE);
            MockEvaluator(h.evaluatorAddr).setResults(_single(1, pct));
            vm.prank(agent1);
            DealManager(dealManager).evaluateDeal(h.dealId, 0); // must never revert

            DealState memory s = IDealManagerAdapter(dealManager).state(h.dealCell);
            assertLe(s.rewardsUnlocked, s.rewardsLimit, "unlocked <= limit");
            assertEq(s.rewardsLimit, IDealCell(h.dealCell).getMainRewardsLimit(), "cell and manager limits agree");
        }

        // Asking for everything that is left always closes the deal.
        if (!IDealCell(h.dealCell).isClosed()) {
            MockEvaluator(h.evaluatorAddr).setResults(_single(1, MathLib.SCALE));
            vm.prank(agent1);
            DealManager(dealManager).evaluateDeal(h.dealId, 0);
        }
        assertTrue(IDealCell(h.dealCell).isClosed(), "full conversion closes");

        DealState memory fin = IDealManagerAdapter(dealManager).state(h.dealCell);
        // After close only unlocked-but-unclaimed rewards stay reserved.
        assertEq(DealManager(dealManager).mainTokenObligations(), fin.rewardsUnlocked - fin.rewardsPaid);

        // Everyone claims; the deal's pool share is claimed through the deal.
        _claimIfAny(h, agent1);
        _claimIfAny(h, agent2);
        if (pool > 0 && fin.rewardsUnlocked > 0) {
            vm.prank(agent1);
            try TreasuryDeal(h.dealAddr).claimDealRewardPool(0) {} catch {}
        }

        fin = IDealManagerAdapter(dealManager).state(h.dealCell);
        assertEq(fin.rewardsPaid, fin.rewardsUnlocked, "everything unlocked was claimable");
        assertEq(DealManager(dealManager).mainTokenObligations(), 0, "no reservation left");
        assertEq(mainToken.totalSupply(), supplyBefore + fin.rewardsPaid, "minted exactly what was paid");
        assertLe(fin.rewardsPaid, fin.rewardsLimit);
    }

    // ------------------------------------------------------------------ //
    // Helpers                                                             //
    // ------------------------------------------------------------------ //
    function _claimIfAny(DealHandle memory h, address who) internal {
        vm.prank(who);
        try IDealCell(h.dealCell).claimMainToken(0) {} catch {}
    }

    function _trancheProposalId(Vm.Log[] memory logs) internal pure returns (uint256 votingId) {
        bytes32 sig = keccak256("TrancheCreated(address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                votingId = uint256(logs[i].topics[3]);
            }
        }
        require(votingId != 0, "tranche proposal not found");
    }

    function _passDealProposal(DealHandle memory h, ProposalParams memory params) internal returns (uint256 pid) {
        vm.prank(agent1);
        pid = Deal(h.dealAddr).createStakedAgentProposal(params);
        vm.warp(block.timestamp + 1);
        address prop = Deal(h.dealAddr).getProposal(pid);
        vm.prank(agent1);
        IVoting(prop).vote(true);
        vm.prank(agent2);
        IVoting(prop).vote(true);
        Deal(h.dealAddr).executeStakedAgentProposal(pid);
    }

    function _mockTreasuryParams(address agent, uint256 poolPct) internal view returns (DealParams memory params) {
        params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Treasury",
            description: "",
            linkHash: "",
            moduleFactory: address(mockModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: poolPct,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: MOCK_EVALUATOR_SELECTOR,
            dealConfig: abi.encode("x"),
            evaluatorConfig: abi.encode(address(this), new EvaluationResult[](0)),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });
    }

    function _createDeal(DealParams memory params) internal returns (DealHandle memory h) {
        vm.recordLogs();
        vm.prank(params.proposer);
        (h.dealId, h.dealCell, h.dealAddr, h.evaluatorAddr) = IDealManager(dealManager).createDealProposal(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                h.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }

    function _stakeApprove(DealHandle memory h) internal {
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(h.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(h.dealCell).invite(agent2, true);
        vm.prank(agent2);
        agentToken.stakeToDeal(h.dealCell, 20_000);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(h.proposalId)).vote(true);
        dac.executeDACProposal(h.proposalId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    function _passDACProposal(ProposalParams memory params) internal returns (uint256 pid) {
        vm.startPrank(founder);
        pid = dac.createManagementProposal(params);
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(pid)).vote(true);
        dac.executeDACProposal(pid);
        vm.stopPrank();
    }

    function _single(uint8 action, uint256 percent) internal pure returns (EvaluationResult[] memory r) {
        r = new EvaluationResult[](1);
        r[0] = EvaluationResult(action, percent, 0);
    }
}
