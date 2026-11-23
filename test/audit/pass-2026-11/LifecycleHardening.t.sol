// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Closing a deal, dividend claim windows, one-shot wiring.
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {
    DealParams,
    ProposalParams,
    EvaluationResult,
    DACConfig,
    VotingConfig,
    CapitalCall
} from "../../../src/interfaces/Structs.sol";
import {GovernanceLimits} from "../../../src/interfaces/GovernanceStructs.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {IDACCell} from "../../../src/interfaces/IDACCell.sol";
import {IAssetController} from "../../../src/interfaces/IAssetController.sol";
import {NativeAssetController} from "../../../src/kernel/controllers/NativeAssetController.sol";
import {IDealFactory} from "../../../src/interfaces/modules/IDealFactory.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../../src/interfaces/DACEventsLib.sol";
import {DACCell} from "../../../src/kernel/DACCell.sol";
import {Deal} from "../../../src/kernel/Deal.sol";
import {DealCell} from "../../../src/kernel/DealCell.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {UUPSProxy} from "../../../src/kernel/proxies/UUPSProxy.sol";
import {MainToken} from "../../../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../../../src/kernel/tokens/AgentToken.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {CoreDealManagementType} from "../../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {CoreDealType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {DACDeal} from "../../../src/modules/core/deals/DACDeal.sol";
import {TreasuryDeal} from "../../../src/modules/core/deals/TreasuryDeal.sol";
import {Permit2TreasuryFactory} from "../../../src/modules/core/deals/Permit2Treasury.sol";
import {TreasuryDealFactory} from "../../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {DACDealConfig} from "../../../src/modules/core/interfaces/Structs.sol";
import {
    MockEvaluator,
    MockEvaluatorFactory,
    MockEvaluatorModuleFactory,
    MOCK_EVALUATOR_SELECTOR
} from "../../DealEvaluationRecoveryTest.t.sol";

/// A module's deal whose close hook can be told to refuse, or to burn all its gas.
contract StubbornTreasuryDeal is TreasuryDeal {
    uint8 public closeMode; // 0 well behaved, 1 reverts, 2 burns gas

    function setCloseMode(uint8 mode) external {
        closeMode = mode;
    }

    function _beforeClose() internal view override {
        if (closeMode == 1) revert("module refuses to close");
        if (closeMode == 2) {
            while (true) {}
        }
    }
}

contract StubbornDealFactory is IDealFactory {
    address public immutable permit2VaultFactory;
    address public immutable referenceImpl;

    constructor(address permit2) {
        referenceImpl = address(new StubbornTreasuryDeal());
        permit2VaultFactory = address(new Permit2TreasuryFactory(permit2));
    }

    function deployDeal(
        uint256 id,
        address dealCell,
        DealParams calldata params,
        address dac,
        address agentToken,
        address mainToken
    ) external returns (address dealAddr) {
        bytes memory initData = abi.encodeWithSelector(
            TreasuryDeal.initialize.selector,
            id,
            dac,
            params.governanceFactory,
            agentToken,
            mainToken,
            params.proposer,
            permit2VaultFactory,
            address(this)
        );

        dealAddr = address(new UUPSProxy(address(referenceImpl), initData));

        TreasuryDeal(dealAddr).joinDac(dealCell);
    }
}

contract LifecycleHardening is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public recipient1 = makeAddr("recipient1");
    address public recipient2 = makeAddr("recipient2");
    address public outsider = makeAddr("outsider");

    MockEvaluatorModuleFactory mockModule;
    MockEvaluatorModuleFactory stubbornModule;

    bytes32 internal constant CLOSE_HOOK_FAILED = keccak256("DealCloseHookFailed(address,uint256,address)");
    // DealCell.CLOSE_HOOK_GAS
    uint256 internal constant CLOSE_HOOK_GAS = 5_000_000;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);

        vm.startPrank(moduleOwner);
        MockEvaluatorFactory evalFactory = new MockEvaluatorFactory();
        mockModule = new MockEvaluatorModuleFactory(address(new TreasuryDealFactory(permit2)), address(evalFactory));
        stubbornModule = new MockEvaluatorModuleFactory(address(new StubbornDealFactory(permit2)), address(evalFactory));
        vm.stopPrank();

        _passDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(mockModule), i: 0, data: bytes("")
            })
        );
        _passDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(stubbornModule), i: 0, data: bytes("")
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
        L-04: a module's close hook cannot stop a deal from closing
    //////////////////////////////////////////////////////////////*/

    function _count(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) n++;
        }
    }

    function test_REG_L04_revertingCloseHook_doesNotStopTheClose() public {
        DealHandle memory h = _createDeal(_treasuryParams(address(stubbornModule)));
        _stakeApprove(h);
        StubbornTreasuryDeal(h.dealAddr).setCloseMode(1);

        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.recordLogs();
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);

        assertTrue(IDealCell(h.dealCell).isClosed(), "closed in spite of the module");
        assertEq(_count(vm.getRecordedLogs(), CLOSE_HOOK_FAILED), 1, "the failed hook is reported");

        // Everything that follows a close still works: stakers leave, capital goes home.
        vm.prank(agent1);
        IDealCell(h.dealCell).unstake();
        vm.prank(agent2);
        IDealCell(h.dealCell).unstake();
        uint256 before = usdc.balanceOf(dac.getAssetController());
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(h.dealId);
        assertEq(usdc.balanceOf(dac.getAssetController()), before + 10_000);
    }

    function test_REG_L04_gasBurningCloseHook_costsItsStipendAndNothingElse() public {
        DealHandle memory h = _createDeal(_treasuryParams(address(stubbornModule)));
        _stakeApprove(h);
        StubbornTreasuryDeal(h.dealAddr).setCloseMode(2);

        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.prank(agent1);
        uint256 g = gasleft();
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        uint256 used = g - gasleft();
        emit log_named_uint("evaluation closing a deal whose hook burns its gas", used);

        assertTrue(IDealCell(h.dealCell).isClosed());
        assertLt(used, CLOSE_HOOK_GAS + 600_000);
    }

    /// The hook's stipend is guaranteed: a caller cannot make it fail by sending too little
    /// gas. Either the hook gets its full stipend or the whole evaluation reverts.
    function test_REG_L04_callerCannotStarveTheCloseHook() public {
        DealHandle memory h = _createDeal(_treasuryParams(address(mockModule)));
        _stakeApprove(h);

        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.prank(agent1);
        try DealManager(dealManager).evaluateDeal{gas: 800_000}(h.dealId, 0) {
            revert("closed without guaranteeing the hook");
        } catch {}
        assertFalse(IDealCell(h.dealCell).isClosed());

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        assertTrue(IDealCell(h.dealCell).isClosed());
    }

    /// DACDeal's close hook sends the child equity home. It works from the token the deal
    /// recorded at creation and fits its stipend several times over.
    function test_REG_L04_dacDeal_closeSendsChildEquityHome() public {
        DealHandle memory h = _createDeal(_dacDealParams(agent1));
        _stakeApprove(h);

        address childMain = IDACCell(DACDeal(h.dealAddr).managedEntity()).getMainToken();
        address homeController = dac.getAssetController();
        assertEq(IERC20(childMain).balanceOf(h.dealAddr), 100_000);

        // The hook on its own, for the stipend's sizing.
        uint256 snap = vm.snapshotState();
        vm.prank(h.dealCell);
        uint256 g = gasleft();
        Deal(h.dealAddr).beforeClose();
        uint256 hookGas = g - gasleft();
        emit log_named_uint("DACDeal close hook gas", hookGas);
        assertLt(hookGas, CLOSE_HOOK_GAS / 2, "hook fits its stipend with a 2x margin");
        vm.revertToState(snap);

        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.recordLogs();
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);

        assertTrue(IDealCell(h.dealCell).isClosed());
        assertEq(_count(vm.getRecordedLogs(), CLOSE_HOOK_FAILED), 0);
        assertEq(IERC20(childMain).balanceOf(h.dealAddr), 0);
        assertEq(IERC20(childMain).balanceOf(homeController), 100_000);
    }

    /// Child equity the deal has vote-locked in the child (it opened a proposal there) is
    /// not transferable at close. The close goes through with what is free, and anyone can
    /// send the rest home once the lock ends.
    function test_REG_L04_dacDeal_voteLockedEquityFollowsWhenTheLockEnds() public {
        DealHandle memory h = _createDeal(_dacDealParams(agent1));
        _stakeApprove(h);

        address childDac = DACDeal(h.dealAddr).managedEntity();
        address childMain = IDACCell(childDac).getMainToken();
        address homeController = dac.getAssetController();

        // The child DAC adopts a 1% proposal qualification...
        VotingConfig memory cfg = IDACCell(childDac).getVotingConfig();
        cfg.qualification = MathLib.atScale(1);
        _passChildProposal(
            h,
            childDac,
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG, target: address(0), i: 0, data: abi.encode(cfg)
            })
        );

        // ...and the deal opens another child proposal: 1% of the child's votable supply
        // is now locked on the deal for the child's voting period.
        vm.recordLogs();
        _passDealProposal(
            h,
            ProposalParams({
                typ: CoreDealManagementType.CREATE_DAC_PROPOSAL,
                target: address(0),
                i: 0,
                data: abi.encode(
                    ProposalParams({
                        typ: DACManagementProposalType.APPROVE_OFFCHAIN_ACTION,
                        target: address(0),
                        i: 0,
                        data: abi.encode(bytes4(0x12345678), bytes("memo"))
                    })
                )
            })
        );
        (uint256 locked, uint256 until) = MainToken(childMain).lockedVotes(h.dealAddr);
        assertEq(locked, 1_000, "1% of the 100_000 child supply");

        // The deal closes inside the lock: the free 99% go home, the hook does not fail.
        MockEvaluator(h.evaluatorAddr).setResults(_single(3, 0));
        vm.recordLogs();
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);
        assertTrue(IDealCell(h.dealCell).isClosed());
        assertEq(_count(vm.getRecordedLogs(), CLOSE_HOOK_FAILED), 0);
        assertEq(IERC20(childMain).balanceOf(homeController), 99_000);
        assertEq(IERC20(childMain).balanceOf(h.dealAddr), 1_000);

        // Nothing more is transferable until the lock ends.
        vm.prank(outsider);
        DACDeal(h.dealAddr).returnChildEquity();
        assertEq(IERC20(childMain).balanceOf(h.dealAddr), 1_000);

        vm.warp(until + 1);
        vm.prank(outsider);
        DACDeal(h.dealAddr).returnChildEquity();
        assertEq(IERC20(childMain).balanceOf(h.dealAddr), 0);
        assertEq(IERC20(childMain).balanceOf(homeController), 100_000);
    }

    function test_REG_L04_returnChildEquity_onlyAfterClose() public {
        DealHandle memory h = _createDeal(_dacDealParams(agent1));
        _stakeApprove(h);

        vm.expectRevert(DACErrorsLib.DealIsNotClosed.selector);
        DACDeal(h.dealAddr).returnChildEquity();
    }

    /*//////////////////////////////////////////////////////////////
        L-14: dividends have a claim window; the rest returns to the treasury
    //////////////////////////////////////////////////////////////*/

    // A second DAC with dividends switched on, funded with 20,000 USDC by the founder.
    function _dividendDAC() internal returns (DACCell ddac) {
        usdc.mint(founder, 20_000e6);
        vm.startPrank(founder);
        (address dacAddress, address mainAddress,) = dacFactory.deployDAC(
            DACConfig({
                symbol: "DIV",
                name: "Dividend DAC",
                description: "dividends on",
                mainTokenMaxSupply: 1_000_000_000e18,
                defaultQuorum: MathLib.atScale(50),
                founder: founder,
                founderAllocation: 200_000_000e18,
                treasuryToken: address(usdc),
                founderCommitment: 20_000e6,
                dividendsEnabled: true
            }),
            keccak256("dividend-dac"),
            address(0)
        );
        ddac = DACCell(dacAddress);
        usdc.approve(ddac.getAssetController(), 20_000e6);
        ddac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: 0,
                tokenRecipient: founder,
                tokenAmount: 200_000_000e18,
                cashAmount: 20_000e6
            })
        );
        MainToken(mainAddress).delegate(founder);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    function _dividend(DACCell ddac, uint256 a1, uint256 a2)
        internal
        returns (uint256 proposalId, bytes32[] memory p1, bytes32[] memory p2)
    {
        bytes32 leaf1 = keccak256(abi.encodePacked(uint256(0), recipient1, a1));
        bytes32 leaf2 = keccak256(abi.encodePacked(uint256(1), recipient2, a2));
        bytes32 root =
            leaf1 < leaf2 ? keccak256(abi.encodePacked(leaf1, leaf2)) : keccak256(abi.encodePacked(leaf2, leaf1));
        p1 = new bytes32[](1);
        p1[0] = leaf2;
        p2 = new bytes32[](1);
        p2[0] = leaf1;

        vm.startPrank(founder);
        proposalId = ddac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.DIVIDEND_PAYOUT,
                target: address(0),
                i: 0,
                data: abi.encode(address(usdc), a1 + a2, root)
            })
        );
        vm.warp(block.timestamp + 1);
        IVoting(ddac.getProposalVoting(proposalId)).vote(true);
        ddac.executeDACProposal(proposalId);
        vm.stopPrank();
    }

    function test_REG_L14_unclaimedDividend_returnsToTheFreeTreasuryAfterTheWindow() public {
        DACCell ddac = _dividendDAC();
        NativeAssetController controller = NativeAssetController(ddac.getAssetController());
        assertEq(controller.freeBalance(address(usdc)), 20_000e6);

        (uint256 pid, bytes32[] memory p1, bytes32[] memory p2) = _dividend(ddac, 3_000e6, 2_000e6);
        uint256 deadline = controller.dividendClaimDeadline(pid);
        assertEq(deadline, block.timestamp + GovernanceLimits.DIVIDEND_CLAIM_WINDOW);
        assertEq(controller.committedBalance(address(usdc)), 5_000e6, "payout is committed");
        assertEq(controller.freeBalance(address(usdc)), 15_000e6);

        // One recipient claims; the other never does.
        ddac.claimDividend(pid, 0, recipient1, 3_000e6, p1);
        assertEq(usdc.balanceOf(recipient1), 3_000e6);

        // Inside the window nothing can be swept.
        vm.warp(deadline);
        vm.expectRevert(DACErrorsLib.DividendClaimWindowOpen.selector);
        ddac.sweepDividend(pid);

        // After it, anyone releases the remainder; it never leaves the treasury.
        vm.warp(deadline + 1);
        vm.expectEmit(true, true, true, true, address(ddac));
        emit DACEventsLib.DividendSwept(pid, address(usdc), 2_000e6);
        vm.prank(outsider);
        ddac.sweepDividend(pid);
        assertEq(usdc.balanceOf(address(controller)), 17_000e6);
        assertEq(controller.committedBalance(address(usdc)), 0);
        assertEq(controller.freeBalance(address(usdc)), 17_000e6, "the unclaimed 2,000 are free again");

        // The window is closed for the late recipient, and there is nothing to sweep twice.
        vm.expectRevert(DACErrorsLib.DividendClaimWindowClosed.selector);
        ddac.claimDividend(pid, 1, recipient2, 2_000e6, p2);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        ddac.sweepDividend(pid);

        // The controller's sweep is reachable through the DAC cell only.
        vm.prank(outsider);
        vm.expectRevert();
        controller.sweepDividend(pid);
    }

    function test_REG_L14_claimsWorkUntilTheLastSecondOfTheWindow() public {
        DACCell ddac = _dividendDAC();
        IAssetController controller = IAssetController(ddac.getAssetController());
        (uint256 pid,, bytes32[] memory p2) = _dividend(ddac, 3_000e6, 2_000e6);

        vm.warp(controller.dividendClaimDeadline(pid));
        ddac.claimDividend(pid, 1, recipient2, 2_000e6, p2);
        assertEq(usdc.balanceOf(recipient2), 2_000e6);
    }

    /*//////////////////////////////////////////////////////////////
        L-15: wiring is set once
    //////////////////////////////////////////////////////////////*/

    function test_REG_L15_wiringIsOneShot() public {
        // MainToken and AgentToken: the DAC cell cannot re-point them at another manager.
        vm.startPrank(address(dac));
        vm.expectRevert(DACErrorsLib.AlreadyInitialized.selector);
        mainToken.dacInit(outsider, outsider);
        vm.expectRevert(DACErrorsLib.AlreadyInitialized.selector);
        agentToken.dacInit(outsider, outsider);
        vm.stopPrank();

        // A deal is bound to its cell once.
        DealHandle memory h = _createDeal(_treasuryParams(address(mockModule)));
        address dealFactory = mockModule.treasuryDealFactory();
        vm.prank(dealFactory);
        vm.expectRevert(DACErrorsLib.AlreadyInitialized.selector);
        Deal(h.dealAddr).joinDac(outsider);
        assertEq(Deal(h.dealAddr).getCell(), h.dealCell);

        // The stake notification is accepted from the AgentToken only, not from the DAC cell.
        vm.prank(address(dac));
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        DealCell(h.dealCell).onAgentTokenStaked(agent1, 1);
    }

    function test_REG_L15_dealManagerCannotMintAgentTokens() public {
        assertFalse(agentToken.hasRole(agentToken.MINTER_ROLE(), dealManager));
        assertTrue(agentToken.hasRole(agentToken.BURNER_ROLE(), dealManager));

        vm.prank(dealManager);
        vm.expectRevert();
        agentToken.mint(outsider, 1);
    }

    /// A deal cell that the manager never registered is refused before its module is asked
    /// anything.
    function test_REG_L15_unregisteredCellIsRefusedExplicitly() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(DACErrorsLib.InvalidDeal.selector, outsider));
        DealManager(dealManager).registerControlledAddress(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    function _treasuryParams(address module) internal view returns (DealParams memory params) {
        params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Treasury",
            description: "",
            linkHash: "",
            moduleFactory: module,
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent1,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
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

    function _dacDealParams(address agent) internal view returns (DealParams memory params) {
        DACConfig memory childDACConfig = DACConfig({
            symbol: "DAC-L2",
            name: "DAC L2",
            description: "",
            mainTokenMaxSupply: 1_000_000,
            defaultQuorum: MathLib.atScale(50),
            founder: founder,
            founderAllocation: 100_000,
            treasuryToken: address(usdc),
            founderCommitment: 10_000,
            dividendsEnabled: false
        });
        bytes32 salt = keccak256(abi.encode("DAC-L2", block.timestamp));
        DACDealConfig memory dacDealConfig = DACDealConfig({
            managedEquity: 100_000, config: abi.encode(address(dacFactory), address(0), salt, childDACConfig)
        });
        params = _treasuryParams(address(coreModule));
        params.dealKind = CoreDealType.DAC_DEAL;
        params.proposer = agent;
        params.dealConfig = abi.encode(dacDealConfig);
        params.evaluatorModuleFactory = address(mockModule);
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

    function _passDACProposal(ProposalParams memory params) internal {
        vm.startPrank(founder);
        uint256 pid = dac.createManagementProposal(params);
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(pid)).vote(true);
        dac.executeDACProposal(pid);
        vm.stopPrank();
    }

    function _passDealProposal(DealHandle memory h, ProposalParams memory params) internal {
        vm.prank(agent1);
        uint256 pid = Deal(h.dealAddr).createStakedAgentProposal(params);
        _voteAndExecuteDeal(h, pid);
    }

    function _voteAndExecuteDeal(DealHandle memory h, uint256 pid) internal {
        vm.warp(block.timestamp + 1);
        address prop = Deal(h.dealAddr).getProposal(pid);
        vm.prank(agent1);
        IVoting(prop).vote(true);
        vm.prank(agent2);
        IVoting(prop).vote(true);
        Deal(h.dealAddr).executeStakedAgentProposal(pid);
    }

    // The deal opens `childProposal` in its child DAC, votes it through and executes it.
    function _passChildProposal(DealHandle memory h, address childDac, ProposalParams memory childProposal) internal {
        vm.recordLogs();
        _passDealProposal(
            h,
            ProposalParams({
                typ: CoreDealManagementType.CREATE_DAC_PROPOSAL,
                target: address(0),
                i: 0,
                data: abi.encode(childProposal)
            })
        );
        (uint256 childPid, uint256 votePid) = _childVoteCreated(vm.getRecordedLogs());
        _voteAndExecuteDeal(h, votePid);
        vm.warp(block.timestamp + 1);
        IDACCell(childDac).executeDACProposal(childPid);
        vm.warp(block.timestamp + 1);
    }

    function _childVoteCreated(Vm.Log[] memory logs) internal pure returns (uint256 childPid, uint256 votePid) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ChildVoteCreated(uint256,uint256)")) {
                childPid = uint256(logs[i].topics[1]);
                votePid = abi.decode(logs[i].data, (uint256));
            }
        }
    }

    function _single(uint8 action, uint256 percent) internal pure returns (EvaluationResult[] memory r) {
        r = new EvaluationResult[](1);
        r[0] = EvaluationResult(action, percent, 0);
    }
}
