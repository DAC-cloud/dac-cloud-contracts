// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "../base/DACTestBase.t.sol";
import {DealParams, ProposalParams, VotingConfig, EvaluationResult} from "../../src/interfaces/Structs.sol";
import {AgentTokenMintAction} from "../../src/interfaces/GovernanceStructs.sol";
import {IVoting} from "../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../src/interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "../../src/kernel/interfaces/IDealManagerAdapter.sol";
import {DealState} from "../../src/kernel/interfaces/Structs.sol";
import {DACErrorsLib} from "../../src/interfaces/DACErrorsLib.sol";
import {Deal} from "../../src/kernel/Deal.sol";
import {DealManager} from "../../src/kernel/DealManager.sol";
import {StakedAgent} from "../../src/kernel/tokens/StakedAgent.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {CoreDealType, CoreEvaluatorType} from "../../src/modules/core/CoreModuleDeals.sol";
import {MilestoneBasedEvaluator} from "../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {Milestone} from "../../src/modules/core/interfaces/Structs.sol";
import {TreasuryDealFactory} from "../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {
    MockEvaluator,
    MockEvaluatorFactory,
    MockEvaluatorModuleFactory,
    MOCK_EVALUATOR_SELECTOR
} from "../DealEvaluationRecoveryTest.t.sol";

/// Regression coverage for the 2026-10 audit pass fixes that need a full DAC.
contract AuditPass202610Test is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public distributor = makeAddr("distributor");

    MockEvaluatorModuleFactory internal mockModule;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);

        vm.prank(moduleOwner);
        mockModule = new MockEvaluatorModuleFactory(
            address(new TreasuryDealFactory(permit2)),
            address(new MockEvaluatorFactory())
        );
        _passDACProposal(ProposalParams({
            typ: DACManagementProposalType.ADD_MODULE, target: address(mockModule), i: 0, data: bytes("")
        }));
    }

    // ------------------------------------------------------------------ //
    //  H-1: funding tokens join the withdrawal set only when settled      //
    // ------------------------------------------------------------------ //

    function test_fundingTokens_onlyPopulatedOnSettlement() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        assertEq(IDealCell(handle.dealCell).fundingTokens().length, 0);

        _stakeApprove(handle);

        address[] memory tokens = IDealCell(handle.dealCell).fundingTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdc));
    }

    function test_requestTranche_cannotTargetAgentOrStakeToken() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        _stakeApprove(handle);
        vm.warp(block.timestamp + 1);

        uint256 pid = _createDealProposal(handle, agent1, ProposalParams({
            typ: AbstractDealManagementType.REQUEST_TRANCHE,
            target: address(agentToken),
            i: bytes32(uint256(1)),
            data: abi.encode(uint256(0))
        }));
        _voteDeal(handle, pid, agent1);
        _voteDeal(handle, pid, agent2);

        vm.expectRevert(DACErrorsLib.InvalidToken.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);

        // Clawback still works: the agent token never entered the funding-token set.
        vm.warp(IDealCell(handle.dealCell).dealDeadline() + 1);
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(handle.dealId);
        assertEq(IDealCell(handle.dealCell).fundingTokens().length, 1);
    }

    function test_rejectedTranche_doesNotBrickClawback() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        _stakeApprove(handle);
        vm.warp(block.timestamp + 1);

        // Agents request a tranche in a token the DAC never approves.
        uint256 pid = _createDealProposal(handle, agent1, ProposalParams({
            typ: AbstractDealManagementType.REQUEST_TRANCHE,
            target: address(mainToken),
            i: bytes32(uint256(1_000)),
            data: abi.encode(uint256(0))
        }));
        _voteDeal(handle, pid, agent1);
        _voteDeal(handle, pid, agent2);
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);

        assertEq(IDealCell(handle.dealCell).fundingTokens().length, 1); // still usdc only

        vm.warp(IDealCell(handle.dealCell).dealDeadline() + 1);
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(handle.dealId);
    }

    // ------------------------------------------------------------------ //
    //  H-2: proposer-chosen deal-proposal factory must be module-vouched  //
    // ------------------------------------------------------------------ //

    function test_createDeal_rejectsUnvouchedGovernanceFactory() public {
        DealParams memory params = _treasuryParams(agent1);
        params.governanceFactory = makeAddr("rogue-factory");

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.GovernanceFactoryNotAccepted.selector);
        IDealManager(dealManager).createDealProposal(params);
    }

    // ------------------------------------------------------------------ //
    //  AgentToken: distributor inventory cannot be pulled in as stake     //
    // ------------------------------------------------------------------ //

    function test_distributorInventory_cannotBeStakedViaTransferFrom() public {
        _passDACProposal(ProposalParams({
            typ: DACManagementProposalType.MINT_AGENT_TOKENS,
            target: distributor,
            i: bytes32(uint256(100_000)),
            data: abi.encode(AgentTokenMintAction.DISTRIBUTOR_INVENTORY)
        }));
        assertEq(agentToken.qualifiedBalanceOf(distributor), 0);

        DealHandle memory handle = createTreasuryDeal(agent1);
        _stakeApprove(handle);

        vm.prank(distributor);
        agentToken.approve(handle.dealCell, 50_000);

        vm.prank(handle.dealCell);
        vm.expectRevert(DACErrorsLib.NotTransferable.selector);
        agentToken.transferFrom(distributor, handle.dealCell, 50_000);
    }

    // ------------------------------------------------------------------ //
    //  Native mints respect reward obligations                             //
    // ------------------------------------------------------------------ //

    function test_treasuryMint_cannotConsumeRewardObligations() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        _stakeApprove(handle); // reserves rewardsLimit = 500e6 as obligation

        uint256 headroom = mainToken.maxSupply() - mainToken.totalSupply();
        assertEq(DealManager(dealManager).mainTokenObligations(), 500e6);

        // Minting everything but the reservation succeeds...
        _passDACProposal(ProposalParams({
            typ: DACManagementProposalType.MINT_MAIN_TOKENS,
            target: address(0),
            i: bytes32(headroom - 500e6),
            data: bytes("")
        }));

        // ...one more wei would make the promised rewards unmintable.
        vm.startPrank(founder);
        uint256 pid = dac.createManagementProposal(ProposalParams({
            typ: DACManagementProposalType.MINT_MAIN_TOKENS, target: address(0), i: bytes32(uint256(1)), data: bytes("")
        }));
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(pid)).vote(true);
        vm.expectRevert(DACErrorsLib.MaxSupplyExceeded.selector);
        dac.executeDACProposal(pid);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ //
    //  Dividends: zero root rejected                                       //
    // ------------------------------------------------------------------ //

    function test_dividendPayout_rejectsZeroRoot() public {
        // base DAC has dividends disabled; use the controller path directly via DACCell execution
        // is gated by dividendsEnabled, so assert at the controller level through a prank.
        address controller = dac.getAssetController();
        vm.prank(address(dac));
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        (bool ok,) = controller.call(abi.encodeWithSignature(
            "recordDividendPayout(uint256,address,uint256,bytes32)", 1, address(usdc), 1_000e6, bytes32(0)
        ));
        ok;
    }

    // ------------------------------------------------------------------ //
    //  Config caps                                                         //
    // ------------------------------------------------------------------ //

    function test_votingConfig_rejectsUnboundedDuration() public {
        VotingConfig memory cfg = dac.getVotingConfig();
        cfg.duration = 366 days;

        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.InvalidVotingConfig.selector);
        dac.createManagementProposal(ProposalParams({
            typ: DACManagementProposalType.UPDATE_VOTING_CONFIG, target: address(0), i: 0, data: abi.encode(cfg)
        }));

        cfg.duration = 7 days;
        cfg.executionValidityDuration = type(uint256).max;
        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.InvalidVotingConfig.selector);
        dac.createManagementProposal(ProposalParams({
            typ: DACManagementProposalType.UPDATE_VOTING_CONFIG, target: address(0), i: 0, data: abi.encode(cfg)
        }));
    }

    function test_unknownProposalType_rejected() public {
        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.UnsupportedProposal.selector);
        dac.createManagementProposal(ProposalParams({
            typ: bytes4(keccak256("notAType()")), target: address(0), i: 0, data: bytes("")
        }));
    }

    // ------------------------------------------------------------------ //
    //  Revoke cannot touch staked collateral                              //
    // ------------------------------------------------------------------ //

    function test_revokeAgentTokens_cannotBurnFromDealCell() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        _stakeApprove(handle);

        vm.startPrank(founder);
        uint256 pid = dac.createManagementProposal(ProposalParams({
            typ: DACManagementProposalType.REVOKE_AGENT_TOKENS,
            target: handle.dealCell,
            i: bytes32(uint256(1_000)),
            data: bytes("")
        }));
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(pid)).vote(true);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        dac.executeDACProposal(pid);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ //
    //  StakedAgent self-delegates on mint                                 //
    // ------------------------------------------------------------------ //

    function test_stakedAgent_autoDelegatesOnStake() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);

        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);

        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        assertEq(stake.delegates(agent1), agent1);
        assertEq(stake.getVotes(agent1), 20_000);
    }

    // ------------------------------------------------------------------ //
    //  Active-holder agents limit                                         //
    // ------------------------------------------------------------------ //

    function test_agentsLimit_countsLiveStakersNotHistory() public {
        DealParams memory params = _treasuryParams(agent1);
        params.agentsLimit = 1;
        params.approveDeadline = block.timestamp + 1 hours;

        vm.recordLogs();
        vm.prank(agent1);
        (, address dealCell,,) = IDealManager(dealManager).createDealProposal(params);

        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(dealCell, 10_000);

        // Approval window lapses; agent1 leaves.
        vm.warp(block.timestamp + 2 hours);
        vm.prank(agent1);
        IDealCell(dealCell).unstake();
        assertEq(StakedAgent(IDealCell(dealCell).stakeToken()).balanceOf(agent1), 0);

        // agent1 is still in the historical holders list, but has no live stake, so a
        // second agent fits under agentsLimit = 1.
        vm.prank(agent1);
        IDealCell(dealCell).invite(agent2, false);
        vm.prank(agent2);
        agentToken.stakeToDeal(dealCell, 10_000);
    }

    // ------------------------------------------------------------------ //
    //  Closed deals: no tranches, one obligation release, bounded eval    //
    // ------------------------------------------------------------------ //

    function test_closedDeal_rejectsTrancheRequest() public {
        DealHandle memory handle = _closedMockDeal();

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.DealIsClosed.selector);
        Deal(handle.dealAddr).createStakedAgentProposal(ProposalParams({
            typ: AbstractDealManagementType.REQUEST_TRANCHE,
            target: address(usdc),
            i: bytes32(uint256(1_000)),
            data: abi.encode(uint256(0))
        }));
    }

    function test_onDealClosed_releasesObligationsOnce() public {
        DealHandle memory handle = _closedMockDeal();

        vm.prank(handle.dealCell);
        vm.expectRevert(DACErrorsLib.DealIsClosed.selector);
        IDealManagerAdapter(dealManager).onDealClosed(handle.dealId);
    }

    function test_evaluation_stopsAfterCloseInsteadOfReverting() public {
        DealHandle memory handle = _approvedMockDeal();

        EvaluationResult[] memory results = new EvaluationResult[](2);
        results[0] = EvaluationResult(3, 0, 0);                  // close
        results[1] = EvaluationResult(1, MathLib.atScale(50), 0); // convert after close: ignored
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertTrue(IDealCell(handle.dealCell).isClosed());
        assertEq(IDealManagerAdapter(dealManager).state(handle.dealCell).rewardsUnlocked, 0);
    }

    function test_evaluation_capsPercentAt100() public {
        DealHandle memory handle = _approvedMockDeal();

        MockEvaluator(handle.evaluatorAddr).setResults(_single(1, 3 * MathLib.SCALE));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        DealState memory state = IDealManagerAdapter(dealManager).state(handle.dealCell);
        assertEq(state.rewardsUnlocked, 500e6); // 100% of rewardsLimit, not 300%
        assertTrue(IDealCell(handle.dealCell).isClosed());
    }

    function test_extendDeadline_cannotShorten() public {
        DealHandle memory handle = _approvedMockDeal();
        uint256 deadline = IDealCell(handle.dealCell).dealDeadline();

        MockEvaluator(handle.evaluatorAddr).setResults(_single(2, 0, deadline - 1));
        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
    }

    // ------------------------------------------------------------------ //
    //  evaluationDeadline: earliest point a non-agent may evaluate         //
    // ------------------------------------------------------------------ //

    function test_holderCanEvaluateOnlyAfterEvaluationDeadline() public {
        DealHandle memory handle = _approvedMockDeal();
        MockEvaluator(handle.evaluatorAddr).setResults(new EvaluationResult[](0));

        uint256 evaluationDeadline = IDealCell(handle.dealCell).evaluationDeadline();
        assertLt(evaluationDeadline, IDealCell(handle.dealCell).dealDeadline());

        vm.warp(evaluationDeadline - 1);
        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        // Agents are never gated by it.
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        vm.warp(evaluationDeadline + 1);
        vm.prank(founder);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
    }

    // ------------------------------------------------------------------ //
    //  Recovery ignores voluntary-staker limits                           //
    // ------------------------------------------------------------------ //

    function test_recoverDeal_ignoresMinimalStakeAndAgentsLimit() public {
        DealParams memory params = _mockTreasuryParams(agent1);
        params.agentsLimit = 2;
        params.minimalStake = 20_000;

        vm.recordLogs();
        vm.prank(agent1);
        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) =
            DealManager(dealManager).createDealProposal(params);
        DealHandle memory handle = DealHandle(dealId, dealCell, dealAddr, evaluatorAddr, _lastDealProposalId());

        _stakeApprove(handle);

        MockEvaluator(handle.evaluatorAddr).setResults(_single(3, 0));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake();
        vm.prank(agent2);
        IDealCell(handle.dealCell).unstake();
        assertTrue(DealManager(dealManager).isRecoverable(handle.dealId));

        // Liquidator is a third address (holders list already has 2 = agentsLimit) with
        // a stake below minimalStake: recovery must still go through.
        address liquidator = makeAddr("liquidator");
        _passDACProposal(ProposalParams({
            typ: DACManagementProposalType.RECOVER_DEAL,
            target: liquidator,
            i: bytes32(uint256(1_000)),
            data: abi.encode(handle.dealId)
        }));

        assertEq(StakedAgent(IDealCell(handle.dealCell).stakeToken()).balanceOf(liquidator), 1_000);
    }

    // ------------------------------------------------------------------ //
    //  Zero-reward deal: later tranche approval no longer reverts         //
    // ------------------------------------------------------------------ //

    function test_zeroRewardDeal_canApproveLaterTranche() public {
        DealParams memory params = _treasuryParams(agent1);
        params.rewardsLimit = 0;

        vm.recordLogs();
        vm.prank(agent1);
        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) =
            IDealManager(dealManager).createDealProposal(params);
        DealHandle memory handle = DealHandle(dealId, dealCell, dealAddr, evaluatorAddr, _lastDealProposalId());

        _stakeApprove(handle);
        vm.warp(block.timestamp + 1);

        uint256 pid = _createDealProposal(handle, agent1, ProposalParams({
            typ: AbstractDealManagementType.REQUEST_TRANCHE,
            target: address(usdc),
            i: bytes32(uint256(2_000)),
            data: abi.encode(uint256(0)) // zero rewards again
        }));
        _voteDeal(handle, pid, agent1);
        _voteDeal(handle, pid, agent2);

        vm.recordLogs();
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);
        uint256 dacPid = _findTopic3(vm.getRecordedLogs(), keccak256("TrancheCreated(address,uint256,uint256,uint256)"));

        vm.warp(block.timestamp + 1);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(dacPid)).vote(true);
        dac.executeDACProposal(dacPid); // previously: arithmetic underflow
        vm.stopPrank();

        assertEq(IDealCell(handle.dealCell).getInvestedCapital(address(usdc)), 12_000);
        assertEq(IDealCell(handle.dealCell).rewardsConvertedPct(), 0);
    }

    // ------------------------------------------------------------------ //
    //  Helpers                                                            //
    // ------------------------------------------------------------------ //

    function _treasuryParams(address agent) internal view returns (DealParams memory params) {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 1 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18;
        milestones[0].penaltyCurve[0] = 1e18;

        params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Audit Treasury Deal",
            description: "",
            linkHash: "",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: abi.encode(MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones)),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });
    }

    function _mockTreasuryParams(address agent) internal view returns (DealParams memory params) {
        params = _treasuryParams(agent);
        params.moduleFactory = address(mockModule);
        params.evaluatorSelector = MOCK_EVALUATOR_SELECTOR;
        params.evaluatorConfig = abi.encode(address(this), new EvaluationResult[](0));
    }

    function _approvedMockDeal() internal returns (DealHandle memory handle) {
        vm.recordLogs();
        vm.prank(agent1);
        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) =
            DealManager(dealManager).createDealProposal(_mockTreasuryParams(agent1));
        handle = DealHandle(dealId, dealCell, dealAddr, evaluatorAddr, _lastDealProposalId());
        _stakeApprove(handle);
    }

    function _closedMockDeal() internal returns (DealHandle memory handle) {
        handle = _approvedMockDeal();
        MockEvaluator(handle.evaluatorAddr).setResults(_single(3, 0));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertTrue(IDealCell(handle.dealCell).isClosed());
    }

    function _stakeApprove(DealHandle memory handle) internal {
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        vm.prank(agent2);
        agentToken.stakeToDeal(handle.dealCell, 20_000);

        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
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

    function _createDealProposal(DealHandle memory handle, address agent, ProposalParams memory params)
        internal
        returns (uint256 pid)
    {
        vm.prank(agent);
        pid = Deal(handle.dealAddr).createStakedAgentProposal(params);
        vm.warp(block.timestamp + 1);
    }

    function _voteDeal(DealHandle memory handle, uint256 pid, address voter) internal {
        address proposal = Deal(handle.dealAddr).getProposal(pid);
        vm.prank(voter);
        IVoting(proposal).vote(true);
    }

    function _single(uint8 action, uint256 percent) internal pure returns (EvaluationResult[] memory results) {
        return _single(action, percent, 0);
    }

    function _single(uint8 action, uint256 percent, uint256 extendTo) internal pure returns (EvaluationResult[] memory results) {
        results = new EvaluationResult[](1);
        results[0] = EvaluationResult(action, percent, extendTo);
    }

    function _lastDealProposalId() internal returns (uint256 proposalId) {
        return _findTopic3(vm.getRecordedLogs(), keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)"));
    }

    function _findTopic3(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) return uint256(logs[i].topics[3]);
        }
        revert("event not found");
    }
}
