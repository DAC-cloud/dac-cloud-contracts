// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "../base/DACTestBase.t.sol";
import {DealParams, ProposalParams, EvaluationResult, DACConfig, CapitalCall} from "../../src/interfaces/Structs.sol";
import {CoreDealManagementType} from "../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {IVoting} from "../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../src/interfaces/IDealManager.sol";
import {IDACCell} from "../../src/interfaces/IDACCell.sol";
import {IDealFactory} from "../../src/interfaces/modules/IDealFactory.sol";
import {IEvaluatorFactory} from "../../src/interfaces/modules/IEvaluatorFactory.sol";
import {IDealManagerAdapter} from "../../src/kernel/interfaces/IDealManagerAdapter.sol";
import {DealState} from "../../src/kernel/interfaces/Structs.sol";
import {DACErrorsLib} from "../../src/interfaces/DACErrorsLib.sol";
import {Deal} from "../../src/kernel/Deal.sol";
import {DealManager} from "../../src/kernel/DealManager.sol";
import {ModuleFactory} from "../../src/kernel/ModuleFactory.sol";
import {MainToken} from "../../src/kernel/tokens/MainToken.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {CoreDealType} from "../../src/modules/core/CoreModuleDeals.sol";
import {DACDeal} from "../../src/modules/core/deals/DACDeal.sol";
import {TreasuryDealFactory} from "../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {DACDealConfig} from "../../src/modules/core/interfaces/Structs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    MockEvaluator,
    MockEvaluatorFactory,
    MockEvaluatorModuleFactory,
    MOCK_EVALUATOR_SELECTOR
} from "../DealEvaluationRecoveryTest.t.sol";

/// Module whose owner can flip `isActive()` -- models a third-party module that
/// goes dormant / is disabled by its maintainer while deals are live.
contract ToggleModuleFactory is ModuleFactory {
    address public immutable treasuryDealFactory;
    address public immutable mockEvaluatorFactory;
    bool public active = true;

    constructor(address t, address e) { treasuryDealFactory = t; mockEvaluatorFactory = e; }

    function setActive(bool a) external { active = a; }

    function moduleId() external pure returns (bytes32) { return bytes32("toggle"); }
    function moduleVersion() external pure returns (uint32, uint32, uint32) { return (1, 0, 0); }
    function moduleManifestURI() external pure returns (string memory) { return ""; }
    function supportedDealKinds() external pure returns (bytes4[] memory k) { k = new bytes4[](1); k[0] = CoreDealType.PERMIT2_TREASURY; }
    function supportedEvaluatorKinds() external pure returns (bytes4[] memory k) { k = new bytes4[](1); k[0] = MOCK_EVALUATOR_SELECTOR; }
    function supportsDealKind(bytes4 d) external pure returns (bool) { return d == CoreDealType.PERMIT2_TREASURY; }
    function dealAcceptsEvaluator(bytes4, bytes4, address) external pure returns (bool) { return true; }
    function evaluatorAcceptsDeal(bytes4, bytes4, address) external pure returns (bool) { return true; }
    function dealAcceptsGovernanceFactory(bytes4, address) external pure returns (bool) { return true; }
    function supportsDealRewardPool(bytes4) external pure returns (bool) { return true; }
    function isActive() external view returns (bool) { return active; }
    function safetyCheck(address) external pure returns (bool) { return true; }
    function getDealFactory(bytes4) internal view override returns (IDealFactory) { return IDealFactory(treasuryDealFactory); }
    function getEvaluatorFactory(bytes4, bytes4) internal view override returns (IEvaluatorFactory) { return IEvaluatorFactory(mockEvaluatorFactory); }
}

contract AccountingRegressionTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    MockEvaluatorModuleFactory mockModule;
    ToggleModuleFactory toggleModule;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);

        vm.startPrank(moduleOwner);
        MockEvaluatorFactory evalFactory = new MockEvaluatorFactory();
        mockModule = new MockEvaluatorModuleFactory(address(new TreasuryDealFactory(permit2)), address(evalFactory));
        toggleModule = new ToggleModuleFactory(address(new TreasuryDealFactory(permit2)), address(evalFactory));
        vm.stopPrank();

        _passDACProposal(ProposalParams({typ: DACManagementProposalType.ADD_MODULE, target: address(mockModule), i: 0, data: bytes("")}));
        _passDACProposal(ProposalParams({typ: DACManagementProposalType.ADD_MODULE, target: address(toggleModule), i: 0, data: bytes("")}));
    }

    // ------------------------------------------------------------------ //
    // DACDeal reward pool stays claimable after close                      //
    // ------------------------------------------------------------------ //
    function test_dacDealRewardPool_claimableAfterClose() public {
        DealHandle memory h = _createDeal(_dacDealParams(agent1, MathLib.atScale(50)));
        _stakeApprove(h);

        address childDac = DACDeal(h.dealAddr).managedEntity();
        address childMain = IDACCell(childDac).getMainToken();
        address childController = IDACCell(childDac).getAssetController();

        MockEvaluator(h.evaluatorAddr).setResults(_single(1, MathLib.atScale(50)));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        vm.prank(agent1);
        DACDeal(h.dealAddr).claimDealRewardPool(0);
        assertEq(mainToken.balanceOf(childController), 125e6);

        // Final conversion closes in the same tx and moves all child equity home.
        MockEvaluator(h.evaluatorAddr).setResults(_single(1, MathLib.atScale(50)));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        assertTrue(IDealCell(h.dealCell).isClosed());
        assertEq(IERC20(childMain).balanceOf(h.dealAddr), 0);

        // The pool share of the closing conversion is still claimable: the child
        // credits forwarded tokens without requiring the caller to hold its token.
        vm.prank(agent1);
        DACDeal(h.dealAddr).claimDealRewardPool(0);
        assertEq(mainToken.balanceOf(childController), 250e6);

        vm.prank(agent1); IDealCell(h.dealCell).claimMainToken(0);
        vm.prank(agent2); IDealCell(h.dealCell).claimMainToken(0);

        DealState memory s = IDealManagerAdapter(dealManager).state(h.dealCell);
        assertEq(s.rewardsUnlocked, s.rewardsPaid);
        assertEq(DealManager(dealManager).mainTokenObligations(), 0, "no reservation left behind");
    }

    // ------------------------------------------------------------------ //
    // A dormant module cannot freeze claims or the close                  //
    // ------------------------------------------------------------------ //
    function test_inactiveModule_cannotFreezeClaimsOrClose() public {
        DealHandle memory h = _createDeal(_toggleTreasuryParams(agent1));
        _stakeApprove(h);
        assertEq(DealManager(dealManager).mainTokenObligations(), 500e6);

        MockEvaluator(h.evaluatorAddr).setResults(_single(1, MathLib.atScale(50)));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);

        toggleModule.setActive(false);

        // Unlocked rewards remain claimable.
        uint256 before = mainToken.balanceOf(agent1);
        vm.prank(agent1);
        IDealCell(h.dealCell).claimMainToken(0);
        assertEq(mainToken.balanceOf(agent1), before + 125e6);

        // Closing still releases the unused reservation.
        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        assertTrue(IDealCell(h.dealCell).isClosed());
        assertEq(DealManager(dealManager).mainTokenObligations(), 125e6); // only agent2's unclaimed share

        // New module-gated actions are still refused for the dormant module.
        vm.prank(h.dealCell);
        vm.expectRevert(abi.encodeWithSelector(DACErrorsLib.InvalidDeal.selector, h.dealCell));
        DealManager(dealManager).registerControlledAddress(address(this));
    }

    // ------------------------------------------------------------------ //
    // Early returns do not block the clawback of a closed, exited deal    //
    // ------------------------------------------------------------------ //
    function test_treasuryDeal_earlyReturnsDoesNotBlockClosedExitedClawback() public {
        DealHandle memory h = _createDeal(_mockTreasuryParams(agent1));
        _stakeApprove(h);

        _passDealProposal(h, ProposalParams({
            typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS, target: address(0), i: 0, data: abi.encode(true)
        }));
        assertTrue(IDealCell(h.dealCell).allowEarlyReturns());

        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        vm.prank(agent1); IDealCell(h.dealCell).unstake();
        vm.prank(agent2); IDealCell(h.dealCell).unstake();

        uint256 before = usdc.balanceOf(dac.getAssetController());
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(h.dealId);
        assertEq(usdc.balanceOf(dac.getAssetController()), before + 10_000);
    }

    // ------------------------------------------------------------------ //
    // REINVEST is refused after close; child equity can always go home    //
    // ------------------------------------------------------------------ //
    function test_dacDeal_reinvestBlockedAfterClose_childMainReturnable() public {
        DealHandle memory h = _createDeal(_dacDealParams(agent1, 0));
        _stakeApprove(h);

        address childDac = DACDeal(h.dealAddr).managedEntity();
        address childMain = IDACCell(childDac).getMainToken();

        ProposalParams memory childCall = ProposalParams({
            typ: DACManagementProposalType.CAPITAL_CALL,
            target: h.dealAddr,
            i: bytes32(uint256(50_000)),
            data: abi.encode(address(usdc), uint256(5_000))
        });
        vm.recordLogs();
        _passDealProposal(h, ProposalParams({
            typ: CoreDealManagementType.CREATE_DAC_PROPOSAL, target: address(0), i: 0, data: abi.encode(childCall)
        }));
        (uint256 childPid, uint256 votePid) = _childVoteCreated(vm.getRecordedLogs());
        _voteAndExecuteDeal(h, votePid);
        vm.warp(block.timestamp + 1);
        IDACCell(childDac).executeDACProposal(childPid);
        bytes32 callHash = keccak256(abi.encode(CapitalCall({
            treasuryToken: address(usdc), nonce: childPid, tokenRecipient: h.dealAddr, tokenAmount: 50_000, cashAmount: 5_000
        })));

        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        assertTrue(IDealCell(h.dealCell).isClosed());

        usdc.mint(h.dealAddr, 5_000);
        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.DealIsClosed.selector);
        Deal(h.dealAddr).createStakedAgentProposal(ProposalParams({
            typ: CoreDealManagementType.REINVEST_PROFITS, target: address(usdc), i: 0, data: abi.encode(uint256(5_000), callHash)
        }));

        // Child equity that still lands on the closed deal can be returned home.
        address homeController = dac.getAssetController();
        vm.prank(homeController);
        IERC20(childMain).transfer(h.dealAddr, 1_000);
        uint256 before = IERC20(childMain).balanceOf(homeController);
        _passDealProposal(h, ProposalParams({
            typ: CoreDealManagementType.RETURN_PROFITS, target: childMain, i: 0, data: abi.encode(uint256(1_000))
        }));
        assertEq(IERC20(childMain).balanceOf(homeController), before + 1_000);
    }

    // ------------------------------------------------------------------ //
    // CAST_VETO_DEAL needs a blocking-sized minority                       //
    // ------------------------------------------------------------------ //
    function test_castVeto_requiresMinimumQualification() public {
        DealHandle memory h = _createDeal(_mockTreasuryParams(agent1));
        _stakeApprove(h);

        // agent1 asks to leave: PERMIT_UNSTAKE is always challengeable.
        vm.recordLogs();
        vm.prank(agent1);
        IDealCell(h.dealCell).unstake();
        uint256 unstakePid = _dealProposalId(vm.getRecordedLogs());

        uint256 votable = DealManager(dealManager).totalReleasedVotable();
        address small = makeAddr("small-holder");   // 0.05%: below the 0.1% floor
        address normal = makeAddr("normal-holder"); // 0.2%: a normal active holder
        vm.startPrank(founder);
        mainToken.transfer(small, votable / 2000);
        mainToken.transfer(normal, votable / 500);
        vm.stopPrank();
        vm.prank(small); mainToken.delegate(small);
        vm.prank(normal); mainToken.delegate(normal);
        vm.warp(block.timestamp + 1);

        ProposalParams memory veto = ProposalParams({
            typ: DACManagementProposalType.CAST_VETO_DEAL, target: address(0), i: 0, data: abi.encode(h.dealId, unstakePid)
        });

        vm.prank(small);
        vm.expectRevert(DACErrorsLib.InsufficientBalance.selector);
        dac.createManagementProposal(veto);

        vm.prank(normal);
        dac.createManagementProposal(veto);
    }

    // ------------------------------------------------------------------ //
    // Factory refuses configs that produce a dead DAC                     //
    // ------------------------------------------------------------------ //
    function test_deployDAC_rejectsDeadConfigs() public {
        DACConfig memory cfg = DACConfig({
            symbol: "X", name: "X", description: "", mainTokenMaxSupply: 1_000_000,
            defaultQuorum: MathLib.atScale(50), founder: founder, founderAllocation: 100_000,
            treasuryToken: address(usdc), founderCommitment: 10_000, dividendsEnabled: false
        });

        cfg.founder = address(0);
        vm.expectRevert();
        dacFactory.deployDAC(cfg, keccak256("a"), address(0));

        cfg.founder = founder;
        cfg.treasuryToken = makeAddr("eoa-token");
        vm.expectRevert();
        dacFactory.deployDAC(cfg, keccak256("b"), address(0));

        cfg.treasuryToken = address(usdc);
        cfg.founderAllocation = 0;
        vm.expectRevert();
        dacFactory.deployDAC(cfg, keccak256("c"), address(0));
    }

    // ------------------------------------------------------------------ //
    // Permit2 spend approvals must outlive the vote                       //
    // ------------------------------------------------------------------ //
    function test_approvePermit2Spend_rejectsExpirationInsideVotingWindow() public {
        DealHandle memory h = _createDeal(_mockTreasuryParams(agent1));
        _stakeApprove(h);

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.PermitExpirationTooShort.selector);
        Deal(h.dealAddr).createStakedAgentProposal(ProposalParams({
            typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
            target: address(usdc),
            i: 0,
            data: abi.encode(makeAddr("spender"), uint160(1_000), uint48(block.timestamp + 1 days))
        }));

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.PermitExpirationTooShort.selector);
        Deal(h.dealAddr).createStakedAgentProposal(ProposalParams({
            typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
            target: address(usdc),
            i: 0,
            data: abi.encode(makeAddr("spender"), uint160(1_000), uint48(0))
        }));
    }

    function _dealProposalId(Vm.Log[] memory logs) internal pure returns (uint256 proposalId) {
        bytes32 sig = keccak256("DealManagementProposalCreated(address,address,uint256,bytes4,address,bytes32,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (proposalId,,,) = abi.decode(logs[i].data, (uint256, address, bytes32, bytes));
            }
        }
    }

    function _passDealProposal(DealHandle memory h, ProposalParams memory params) internal {
        vm.prank(agent1);
        uint256 pid = Deal(h.dealAddr).createStakedAgentProposal(params);
        _voteAndExecuteDeal(h, pid);
    }

    function _voteAndExecuteDeal(DealHandle memory h, uint256 pid) internal {
        vm.warp(block.timestamp + 1);
        address prop = Deal(h.dealAddr).getProposal(pid);
        vm.prank(agent1); IVoting(prop).vote(true);
        vm.prank(agent2); IVoting(prop).vote(true);
        Deal(h.dealAddr).executeStakedAgentProposal(pid);
    }

    function _childVoteCreated(Vm.Log[] memory logs) internal pure returns (uint256 childPid, uint256 votePid) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ChildVoteCreated(uint256,uint256)")) {
                childPid = uint256(logs[i].topics[1]);
                votePid = abi.decode(logs[i].data, (uint256));
            }
        }
    }

    // ------------------------------------------------------------------ //
    // Helpers                                                             //
    // ------------------------------------------------------------------ //
    function _dacDealParams(address agent, uint256 poolPct) internal view returns (DealParams memory params) {
        DACConfig memory childDACConfig = DACConfig({
            symbol: "DAC-L2", name: "DAC L2", description: "", mainTokenMaxSupply: 1_000_000,
            defaultQuorum: 50, founder: founder, founderAllocation: 100_000,
            treasuryToken: address(usdc), founderCommitment: 10_000, dividendsEnabled: false
        });
        bytes32 salt = keccak256(abi.encode("DAC-L2-poc", block.timestamp));
        DACDealConfig memory dacDealConfig = DACDealConfig({
            managedEquity: 100_000,
            config: abi.encode(address(dacFactory), address(0), salt, childDACConfig)
        });
        params = DealParams({
            dealKind: CoreDealType.DAC_DEAL, name: "PoC DAC Deal", description: "", linkHash: "",
            moduleFactory: address(coreModule), governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0), proposer: agent, vetoEnabled: false,
            fundingToken: address(usdc), fundingAmount: 10_000, rewardsLimit: 500e6,
            dealRewardPoolPercent: poolPct,
            approveDeadline: block.timestamp + 1 days, evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: MOCK_EVALUATOR_SELECTOR, dealConfig: abi.encode(dacDealConfig),
            evaluatorConfig: abi.encode(address(this), new EvaluationResult[](0)),
            evaluatorModuleFactory: address(mockModule), agentsLimit: 0, minimalStake: 0
        });
    }

    function _mockTreasuryParams(address agent) internal view returns (DealParams memory params) {
        params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY, name: "PoC Treasury", description: "", linkHash: "",
            moduleFactory: address(mockModule), governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0), proposer: agent, vetoEnabled: false,
            fundingToken: address(usdc), fundingAmount: 10_000, rewardsLimit: 500e6, dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days, evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: MOCK_EVALUATOR_SELECTOR, dealConfig: abi.encode("x"),
            evaluatorConfig: abi.encode(address(this), new EvaluationResult[](0)),
            evaluatorModuleFactory: address(0), agentsLimit: 0, minimalStake: 0
        });
    }

    function _toggleTreasuryParams(address agent) internal view returns (DealParams memory params) {
        params = _mockTreasuryParams(agent);
        params.moduleFactory = address(toggleModule);
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
        vm.prank(agent1); agentToken.stakeToDeal(h.dealCell, 20_000);
        vm.prank(agent1); IDealCell(h.dealCell).invite(agent2, true);
        vm.prank(agent2); agentToken.stakeToDeal(h.dealCell, 20_000);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(h.proposalId)).vote(true);
        dac.executeDACProposal(h.proposalId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    function _passDACProposal(ProposalParams memory params) internal {
        vm.startPrank(founder);
        uint256 pid = dac.createManagementProposal(params);
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
