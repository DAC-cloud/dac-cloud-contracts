// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {DealParams, ProposalParams, EvaluationResult, VotingConfig} from "../src/interfaces/Structs.sol";
import {IEvaluator} from "../src/interfaces/IEvaluator.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {IModuleFactory} from "../src/interfaces/IModuleFactory.sol";
import {IDealFactory} from "../src/interfaces/modules/IDealFactory.sol";
import {IEvaluatorFactory} from "../src/interfaces/modules/IEvaluatorFactory.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {DealManager} from "../src/kernel/DealManager.sol";
import {ModuleFactory} from "../src/kernel/ModuleFactory.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../src/kernel/governance/AbstractDealManagementProposals.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {DealState} from "../src/kernel/interfaces/Structs.sol";
import {IDealManagerAdapter} from "../src/kernel/interfaces/IDealManagerAdapter.sol";
import {CoreDealType} from "../src/modules/core/CoreModuleDeals.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {StakedAgentFactory} from "../src/kernel/tokens/factories/TokenFactories.sol";
import {DACEventsLib} from "../src/interfaces/DACEventsLib.sol";

bytes4 constant MOCK_EVALUATOR_SELECTOR = bytes4(keccak256("MOCK_EVALUATOR"));

contract MockEvaluator is IEvaluator {
    error NotAuthorized();

    address public admin;
    EvaluationResult[] internal plannedResults;

    constructor(address _admin, EvaluationResult[] memory initialResults) {
        admin = _admin;
        _setResults(initialResults);
    }

    function setResults(EvaluationResult[] memory newResults) external {
        require(msg.sender == admin, NotAuthorized());
        _setResults(newResults);
    }

    function permitMint(address, address, uint256) external pure returns (bool permit) {
        return true;
    }

    function evaluateDeal(uint256, address, address, address) external returns (EvaluationResult[] memory results) {
        results = new EvaluationResult[](plannedResults.length);
        for (uint256 i = 0; i < plannedResults.length; i++) {
            results[i] = plannedResults[i];
        }
    }

    function _setResults(EvaluationResult[] memory newResults) internal {
        delete plannedResults;
        for (uint256 i = 0; i < newResults.length; i++) {
            plannedResults.push(newResults[i]);
        }
    }
}

contract MockEvaluatorFactory is IEvaluatorFactory {
    function deployEvaluator(
        address,
        uint256,
        address,
        DealParams calldata,
        bytes calldata evaluatorConfig
    ) external returns (address evaluatorAddr) {
        (address admin, EvaluationResult[] memory initialResults) = abi.decode(
            evaluatorConfig,
            (address, EvaluationResult[])
        );

        evaluatorAddr = address(new MockEvaluator(admin, initialResults));
    }
}

contract MockEvaluatorModuleFactory is ModuleFactory {
    error DealKindNotSupported(bytes4 kind);
    error EvaluatorKindNotSupported(bytes4 selector);

    address public immutable treasuryDealFactory;
    address public immutable mockEvaluatorFactory;

    constructor(
        address dealCellFactory_,
        address stakedAgentFactory_,
        address treasuryDealFactory_,
        address mockEvaluatorFactory_
    ) ModuleFactory(dealCellFactory_, stakedAgentFactory_) {
        treasuryDealFactory = treasuryDealFactory_;
        mockEvaluatorFactory = mockEvaluatorFactory_;
    }

    function moduleId() external pure returns (bytes32) { return bytes32("mock.evaluator"); }
    function moduleVersion() external pure returns (uint32 major, uint32 minor, uint32 patch) { return (1, 0, 0); }
    function moduleManifestURI() external pure returns (string memory) { return ""; }
    function supportedDealKinds() external pure returns (bytes4[] memory kinds) {
        kinds = new bytes4[](1);
        kinds[0] = CoreDealType.PERMIT2_TREASURY;
    }
    function supportedEvaluatorKinds() external pure returns (bytes4[] memory kinds) {
        kinds = new bytes4[](1);
        kinds[0] = MOCK_EVALUATOR_SELECTOR;
    }
    function supportsDealKind(bytes4 dealKind) external pure returns (bool) {
        return dealKind == CoreDealType.PERMIT2_TREASURY;
    }
    function supportsEvaluatorKind(bytes4, bytes4 evaluatorSelector) external pure returns (bool) {
        return evaluatorSelector == MOCK_EVALUATOR_SELECTOR;
    }
    function supportsDealRewardPool(bytes4 dealKind) external pure returns (bool) {
        return dealKind == CoreDealType.PERMIT2_TREASURY;
    }

    function isActive() external pure returns (bool) { return true; }
    function safetyCheck(address) external pure returns (bool) { return true; }

    function getDealFactory(bytes4 dealKind) internal view override returns (IDealFactory factory) {
        if (dealKind != CoreDealType.PERMIT2_TREASURY) revert DealKindNotSupported(dealKind);
        factory = IDealFactory(treasuryDealFactory);
    }

    function getEvaluatorFactory(bytes4, bytes4 evaluatorSelector) internal view override returns (IEvaluatorFactory factory) {
        if (evaluatorSelector != MOCK_EVALUATOR_SELECTOR) revert EvaluatorKindNotSupported(evaluatorSelector);
        factory = IEvaluatorFactory(mockEvaluatorFactory);
    }
}

contract DealEvaluationRecoveryTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public liquidator = makeAddr("liquidator");

    MockEvaluatorModuleFactory mockModule;

    function setUp() public {
        setUpBase();

        onboardAgent(agent1);
        onboardAgent(agent2);

        vm.prank(moduleOwner);
        mockModule = new MockEvaluatorModuleFactory(
            address(new DealCellFactory()),
            address(new StakedAgentFactory()),
            address(new TreasuryDealFactory(permit2)),
            address(new MockEvaluatorFactory())
        );

        _approveModule(address(mockModule));
    }

    function test_mockEvaluator_successUnlocksAndClaimsRewards() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        EvaluationResult[] memory results = _singleResult(1, MathLib.atScale(50), 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        DealState memory state = IDealManagerAdapter(dealManager).state(handle.dealCell);
        assertEq(state.rewardsUnlocked, 250e6);
        assertEq(state.rewardsPaid, 0);

        uint256 beforeBalance = mainToken.balanceOf(agent1);
        vm.prank(agent1);
        IDealCell(handle.dealCell).claimMainToken(0);

        state = IDealManagerAdapter(dealManager).state(handle.dealCell);
        assertEq(state.rewardsPaid, 125e6);
        assertEq(mainToken.balanceOf(agent1), beforeBalance + 125e6);
    }

    function test_mockEvaluator_successAllocatesDealRewardPoolAndDealCanClaim() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal(MathLib.atScale(80));

        EvaluationResult[] memory results = _singleResult(1, MathLib.atScale(50), 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.expectEmit(true, true, true, true);
        emit DACEventsLib.DealRewardPoolAllocated(address(dac), handle.dealId, handle.dealAddr, 200e6);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        DealState memory state = IDealManagerAdapter(dealManager).state(handle.dealCell);
        assertEq(state.rewardsUnlocked, 250e6);
        assertEq(state.rewardsPaid, 0);

        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        uint256 dealBalanceBefore = mainToken.balanceOf(handle.dealAddr);
        uint256 treasuryBalanceBefore = mainToken.balanceOf(treasuryAddr);

        vm.expectEmit(true, true, true, true);
        emit DACEventsLib.RewardsClaimed(address(dac), handle.dealAddr, handle.dealAddr, 200e6);
        vm.expectEmit(true, true, true, true);
        emit DACEventsLib.DealRewardClaimed(address(dac), handle.dealId, handle.dealAddr, 200e6);

        vm.prank(agent1);
        TreasuryDeal(handle.dealAddr).claimDealRewardPool(0);

        state = IDealManagerAdapter(dealManager).state(handle.dealCell);
        assertEq(state.rewardsPaid, 200e6);
        assertEq(mainToken.balanceOf(handle.dealAddr), dealBalanceBefore);
        assertEq(mainToken.balanceOf(treasuryAddr), treasuryBalanceBefore + 200e6);

        uint256 agentBalanceBefore = mainToken.balanceOf(agent1);
        vm.prank(agent1);
        IDealCell(handle.dealCell).claimMainToken(0);

        state = IDealManagerAdapter(dealManager).state(handle.dealCell);
        assertEq(state.rewardsPaid, 225e6);
        assertEq(mainToken.balanceOf(agent1), agentBalanceBefore + 25e6);
    }

    function test_mockEvaluator_dealRewardPoolClaimRequiresStakedAgent() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal(MathLib.atScale(80));

        EvaluationResult[] memory results = _singleResult(1, MathLib.atScale(50), 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        address outsider = makeAddr("outsider");
        vm.expectRevert(DACErrorsLib.NoStake.selector);
        vm.prank(outsider);
        TreasuryDeal(handle.dealAddr).claimDealRewardPool(0);
    }

    function test_mockEvaluator_slashBurnsStakeAndEscrowedAgentTokens() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        EvaluationResult[] memory results = _singleResult(0, MathLib.atScale(25), 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        StakedAgent stakeToken = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        assertEq(stakeToken.balanceOf(agent1), 15_000);
        assertEq(stakeToken.balanceOf(agent2), 15_000);
        assertEq(agentToken.balanceOf(handle.dealCell), 30_000);
    }

    function test_mockEvaluator_fullSlashAutoClosesAndMakesDealRecoverable() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        EvaluationResult[] memory results = _singleResult(0, MathLib.SCALE, 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        StakedAgent stakeToken = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        assertEq(stakeToken.totalSupply(), 0);
        assertEq(agentToken.balanceOf(handle.dealCell), 0);
        assertTrue(IDealCell(handle.dealCell).isClosed());
        assertTrue(DealManager(dealManager).isRecoverable(handle.dealId));
    }

    function test_mockEvaluator_extendUpdatesDealDeadline() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        uint256 extendedDeadline = block.timestamp + 10 days;
        EvaluationResult[] memory results = _singleResult(2, 0, extendedDeadline);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(IDealCell(handle.dealCell).dealDeadline(), extendedDeadline);
    }

    function test_mockEvaluator_closeClosesDeal() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        EvaluationResult[] memory results = _singleResult(3, 0, 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertTrue(IDealCell(handle.dealCell).isClosed());
        assertFalse(IDealManagerAdapter(dealManager).state(handle.dealCell).active);
    }

    function test_forceReturnCapital_holderCanWithdrawAfterDeadline() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        uint256 dacBalanceBefore = usdc.balanceOf(dac.getAssetController());

        vm.warp(IDealCell(handle.dealCell).dealDeadline() + 1);
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(handle.dealId);

        assertEq(IDealCell(handle.dealCell).getReturnedCapital(address(usdc)), 10_000);
        assertEq(usdc.balanceOf(dac.getAssetController()), dacBalanceBefore + 10_000);
    }

    function test_forceReturnCapital_revertsBeforeDeadline() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.DeadlineNotPassed.selector);
        DealManager(dealManager).forceReturnCapital(handle.dealId);
    }

    function test_forceReturnCapital_nonHolderReverts() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        DealManager(dealManager).forceReturnCapital(handle.dealId);
    }

    function test_evaluateDeal_nonAgentOrHolderReverts() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
    }

    function test_recoverDealProposal_revertsWhileStakeStillOutstanding() public {
        DealHandle memory handle = _setupApprovedMockTreasuryDeal();

        EvaluationResult[] memory results = _singleResult(3, 0, 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        vm.startPrank(founder);
        vm.expectRevert(
            abi.encodeWithSelector(DACErrorsLib.InvalidDealState.selector, handle.dealCell)
        );
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.RECOVER_DEAL,
                target: liquidator,
                i: bytes32(uint256(8_000)),
                data: abi.encode(handle.dealId)
            })
        );
        vm.stopPrank();
    }

    function test_recoverDeal_assignsGovernanceOnlyStakeToLiquidator() public {
        DealHandle memory handle = _closeAndExitDeal();

        uint256 liquidatorStake = 8_000;
        _recoverDeal(handle, liquidatorStake);

        StakedAgent stakeToken = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        assertEq(agentToken.balanceOf(liquidator), 0);
        assertEq(stakeToken.balanceOf(liquidator), liquidatorStake);

        vm.prank(liquidator);
        stakeToken.delegate(liquidator);
        vm.warp(block.timestamp + 1);

        vm.startPrank(liquidator);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS,
                target: address(0),
                i: 0,
                data: abi.encode(true)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, liquidator, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        assertTrue(IDealCell(handle.dealCell).allowEarlyReturns());
    }

    function test_recoveryBlocksAddStakeProposalExecution() public {
        DealHandle memory handle = _closeAndExitDeal();

        uint256 liquidatorStake = 8_000;
        _recoverDeal(handle, liquidatorStake);

        StakedAgent stakeToken = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        vm.prank(liquidator);
        stakeToken.delegate(liquidator);
        vm.warp(block.timestamp + 1);

        vm.prank(agent1);
        agentToken.approve(handle.dealCell, 1_000);

        vm.startPrank(liquidator);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.ADD_STAKE,
                target: agent1,
                i: bytes32(uint256(1_000)),
                data: bytes("")
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, liquidator, true);

        vm.expectRevert(DACErrorsLib.DealInLiquidation.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
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

    function _createMockTreasuryDeal(address proposer, uint256 dealRewardPoolPercent) internal returns (DealHandle memory handle) {
        vm.recordLogs();

        vm.startPrank(proposer);

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Mock Evaluator Deal",
            description: "Treasury deal with mock evaluator",
            linkHash: "0x00mock",
            moduleFactory: address(mockModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: proposer,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: dealRewardPoolPercent,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: MOCK_EVALUATOR_SELECTOR,
            dealConfig: abi.encode("mock deal config"),
            evaluatorConfig: abi.encode(address(this), new EvaluationResult[](0)),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) = DealManager(dealManager).createDealProposal(params);

        vm.stopPrank();

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

    function _setupApprovedMockTreasuryDeal() internal returns (DealHandle memory handle) {
        handle = _setupApprovedMockTreasuryDeal(0);
    }

    function _setupApprovedMockTreasuryDeal(uint256 dealRewardPoolPercent) internal returns (DealHandle memory handle) {
        handle = _createMockTreasuryDeal(agent1, dealRewardPoolPercent);

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
    }

    function _closeAndExitDeal() internal returns (DealHandle memory handle) {
        handle = _setupApprovedMockTreasuryDeal();

        EvaluationResult[] memory results = _singleResult(3, 0, 0);
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake();
        vm.prank(agent2);
        IDealCell(handle.dealCell).unstake();

        assertTrue(DealManager(dealManager).isRecoverable(handle.dealId));
    }

    function _recoverDeal(DealHandle memory handle, uint256 liquidatorStake) internal {
        vm.startPrank(founder);

        uint256 proposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.RECOVER_DEAL,
                target: liquidator,
                i: bytes32(liquidatorStake),
                data: abi.encode(handle.dealId)
            })
        );

        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(proposalId)).vote(true);
        dac.executeDACProposal(proposalId);

        vm.stopPrank();
    }

    function _stakeAndDelegate(address agent, address dealCell, uint256 amount) internal {
        vm.startPrank(agent);
        agentToken.stakeToDeal(dealCell, amount);
        StakedAgent(IDealCell(dealCell).stakeToken()).delegate(agent);
        vm.stopPrank();
    }

    function _voteDealProposal(address dealAddr, uint256 proposalId, address voter, bool support) internal {
        address proposal = Deal(dealAddr).getProposal(proposalId);
        vm.prank(voter);
        IVoting(proposal).vote(support);
    }

    function _singleResult(uint8 action, uint256 percent, uint256 extendTo) internal pure returns (EvaluationResult[] memory results) {
        results = new EvaluationResult[](1);
        results[0] = EvaluationResult(action, percent, extendTo);
    }
}
