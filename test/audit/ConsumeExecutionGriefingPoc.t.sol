// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Regression tests for H-01: unauthorized `consumeExecution` could grief any
// passed proposal by marking it executed without running the action. Pre-fix,
// the attacker call to `consumeExecution(true)` would succeed and the
// legitimate `executeDACProposal` / `executeStakedAgentProposal` would revert
// with `ProposalAlreadyExecuted`, permanently blocking the DAC action.
//
// Post-fix, every proposal type binds an `executor` at initialization and
// `consumeExecution` reverts with `NotAuthorized` for any other caller. The
// tests below assert both halves of that invariant:
//   1) an unrelated address calling `consumeExecution(true)` reverts;
//   2) the legitimate flow still executes the proposal action end-to-end.
//
// Three proposal surfaces are exercised:
//   • DACManagementProposal           — native DAC governance (full integration)
//   • HybridDACManagementProposal     — hybrid DAC governance (unit-style,
//                                       reusing the standalone pattern from
//                                       HybridDACManagementProposalTest)
//   • DealManagementProposal          — deal-level governance (full integration)

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UUPSProxy} from "../../src/kernel/proxies/UUPSProxy.sol";

import {DACTestBase} from "../base/DACTestBase.t.sol";

import {ProposalParams} from "../../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig, ProposalPhase} from "../../src/interfaces/GovernanceStructs.sol";
import {IVoting} from "../../src/interfaces/IVoting.sol";
import {IExecutableProposal} from "../../src/interfaces/IExecutableProposal.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {DACErrorsLib} from "../../src/interfaces/DACErrorsLib.sol";

import {Deal} from "../../src/kernel/Deal.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {StakedAgent} from "../../src/kernel/tokens/StakedAgent.sol";
import {HybridDACManagementProposal} from "../../src/kernel/governance/HybridDACManagementProposal.sol";

contract ConsumeExecutionGriefingPoc is DACTestBase {
    address internal attacker = address(0xDEAD);

    function setUp() public {
        setUpBase();
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. DACManagementProposal — native DAC governance
    // ─────────────────────────────────────────────────────────────────────

    function test_dacProposal_unauthorizedConsumeExecutionReverts() public {
        (address proposal, uint256 propId, address target) = _createAndVoteDacProposal();

        // Pre-fix this call succeeded and bricked the proposal. Post-fix it
        // must revert because the attacker is not the bound executor (the
        // NativeGovernanceSchema).
        vm.prank(attacker);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        IExecutableProposal(proposal).consumeExecution(true);

        // Legitimate flow still runs the action.
        dac.executeDACProposal(propId);
        assertEq(agentToken.balanceOf(target), 123, "agent tokens minted");
    }

    function test_dacProposal_legitimateFlowSucceeds() public {
        (, uint256 propId, address target) = _createAndVoteDacProposal();

        dac.executeDACProposal(propId);
        assertEq(agentToken.balanceOf(target), 123);

        // Once legitimately executed, no path (legitimate or otherwise) can
        // re-execute.
        vm.expectRevert(DACErrorsLib.ProposalAlreadyExecuted.selector);
        dac.executeDACProposal(propId);
    }

    function _createAndVoteDacProposal()
        internal
        returns (address proposal, uint256 propId, address target)
    {
        target = address(0xBEEF);

        vm.prank(founder);
        propId = dac.createManagementProposal(ProposalParams({
            typ: DACManagementProposalType.MINT_AGENT_TOKENS,
            target: target,
            i: bytes32(uint256(123)),
            data: bytes("")
        }));

        vm.warp(block.timestamp + 1);

        proposal = dac.getProposalVoting(propId);

        vm.prank(founder);
        IVoting(proposal).vote(true);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. HybridDACManagementProposal — hybrid DAC governance (standalone)
    // ─────────────────────────────────────────────────────────────────────

    function test_hybridProposal_unauthorizedConsumeExecutionReverts() public {
        H01HybridHarness h = new H01HybridHarness();
        (HybridDACManagementProposal proposal, address legitimateExecutor) = h.setupResolvedYes();

        // Non-executor attacker cannot mark the proposal executed.
        vm.prank(attacker);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        proposal.consumeExecution(true);

        // The bound executor can consume it (no other state-changing side
        // effects on this standalone setup — we only assert the gate).
        vm.prank(legitimateExecutor);
        proposal.consumeExecution(true);
        assertTrue(proposal.isExecuted(), "executor can consume");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. DealManagementProposal — deal-level governance
    // ─────────────────────────────────────────────────────────────────────

    function test_dealProposal_unauthorizedConsumeExecutionReverts() public {
        (address dealAddr, uint256 dealProposalId, address proposal) = _setupResolvedDealProposal();

        // Pre-fix: attacker calls `consumeExecution(true)` directly, locking
        // the proposal as executed; the deal's `executeStakedAgentProposal`
        // would then revert. Post-fix: the call reverts because the deal
        // contract is the only authorized executor.
        vm.prank(attacker);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        IExecutableProposal(proposal).consumeExecution(true);

        // The deal's legitimate execution path still runs the action.
        bool earlyReturnsBefore = IDealCell(_dealCellOf(dealAddr)).allowEarlyReturns();
        Deal(dealAddr).executeStakedAgentProposal(dealProposalId);
        bool earlyReturnsAfter = IDealCell(_dealCellOf(dealAddr)).allowEarlyReturns();
        assertFalse(earlyReturnsBefore, "early returns off before");
        assertTrue(earlyReturnsAfter, "early returns toggled on by executed proposal");
    }

    // Minimal end-to-end: onboard two agents, fund an approved treasury deal,
    // raise a TOGGLE_EARLY_RETURNS deal proposal, vote it through. Returns
    // the deal address, the deal-proposal id, and the proposal contract.
    function _setupResolvedDealProposal()
        internal
        returns (address dealAddr, uint256 dealProposalId, address proposal)
    {
        address agent1 = makeAddr("h01-agent-1");
        address agent2 = makeAddr("h01-agent-2");

        onboardAgent(agent1);
        onboardAgent(agent2);

        DealHandle memory handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);

        // DAC approves the deal.
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Raise a deal-level proposal that flips an observable boolean.
        vm.prank(agent1);
        dealProposalId = Deal(handle.dealAddr).createStakedAgentProposal(ProposalParams({
            typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS,
            target: address(0),
            i: 0,
            data: abi.encode(true)
        }));

        vm.warp(block.timestamp + 1);

        proposal = Deal(handle.dealAddr).getProposal(dealProposalId);

        vm.prank(agent1);
        IVoting(proposal).vote(true);
        vm.prank(agent2);
        IVoting(proposal).vote(true);

        dealAddr = handle.dealAddr;
    }

    function _stakeAndDelegate(address agent, address dealCell, uint256 amount) internal {
        vm.startPrank(agent);
        agentToken.stakeToDeal(dealCell, amount);
        StakedAgent(IDealCell(dealCell).stakeToken()).delegate(agent);
        vm.stopPrank();
    }

    function _dealCellOf(address dealAddr) internal view returns (address) {
        return Deal(dealAddr).getCell();
    }
}

// Standalone harness for the hybrid proposal. The HybridDACManagementProposal
// can be initialized without a full DAC by acting as our own dacCell+executor,
// which is the same pattern used by HybridDACManagementProposalTest. We only
// need the proposal to reach the `Resolved/yes` state so that
// `_isExecutableNow()` returns true inside `consumeExecution`.
contract H01HybridHarness is Test {
    HybridDACManagementProposal public proposal;
    address public publisher = makeAddr("h01-publisher");
    address public assetController = makeAddr("h01-assetController");
    H01UnderlyingToken public underlying;
    address public voter = makeAddr("h01-voter");

    function setupResolvedYes()
        external
        returns (HybridDACManagementProposal, address legitimateExecutor)
    {
        vm.mockCall(
            assetController,
            abi.encodeWithSelector(bytes4(keccak256("getPastControlledBalance(uint256)"))),
            abi.encode(uint256(0))
        );

        underlying = new H01UnderlyingToken();
        // Wrapped token mock that supports the IVotes calls the proposal makes
        H01WrappedToken wrapped = new H01WrappedToken();

        vm.roll(block.number + 5);
        wrapped.setPastVotes(voter, 100e18, block.number - 1);
        wrapped.setPastTotalSupply(block.number - 1, 100e18);

        proposal = HybridDACManagementProposal(
            address(new UUPSProxy(address(new HybridDACManagementProposal()), bytes("")))
        );

        // The harness contract acts as both the dacCell and the legitimate
        // executor for this isolated test — same shape as a real schema
        // calling `consumeApprovedProposal` on the proposal.
        legitimateExecutor = address(this);

        proposal.initialize(
            1,
            address(this),         // dacCell
            legitimateExecutor,    // executor
            address(wrapped),
            address(0),            // governanceOracle (only required when oraclePrimaryEnabled)
            assetController,
            ProposalParams({
                typ: bytes4(keccak256("H01_TEST")),
                target: address(0),
                i: bytes32(0),
                data: bytes("")
            }),
            _wrappedOnlyStrategyConfig(),
            false,
            false
        );

        // Bootstrap mode starts in FallbackWarmup; warp through it and into
        // FallbackVoting, then cast a fully-passing vote.
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1);
        proposal.activateFallbackVoting();
        wrapped.setPastVotes(voter, 100e18, block.number - 1);
        wrapped.setPastTotalSupply(block.number - 1, 100e18);

        vm.prank(voter);
        proposal.vote(true);

        assertTrue(proposal.isResolved(), "harness: proposal resolved");
        assertTrue(proposal.outcome(), "harness: yes outcome");

        return (proposal, legitimateExecutor);
    }

    function _wrappedOnlyStrategyConfig() internal pure returns (GovernanceStrategyConfig memory c) {
        c = GovernanceStrategyConfig({
            quorumPercent: 5e17,
            highQuorumPercent: 8e17,
            blockingPercent: 2e17,
            duration: 7 days,
            qualification: 0,
            executionValidityDuration: 1 days,
            oraclePublishDeadline: 0,
            fallbackWarmupDuration: 1 days,
            fallbackDuration: 1 days,
            blockingOnAllProposals: false,
            blockingOnHighQuorum: false,
            oraclePrimaryEnabled: false
        });
    }
}

contract H01UnderlyingToken is ERC20 {
    constructor() ERC20("h01 underlying", "h01u") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// Minimal mock that supports the IVotes calls HybridDACManagementProposal
// makes during voting + snapshotting. Setting past values per block lets the
// harness drive the proposal through Resolved/yes deterministically.
contract H01WrappedToken {
    mapping(address => mapping(uint256 => uint256)) internal _pastVotes;
    mapping(uint256 => uint256) internal _pastSupply;

    function setPastVotes(address account, uint256 amount, uint256 blockNum) external {
        _pastVotes[account][blockNum] = amount;
    }

    function setPastTotalSupply(uint256 blockNum, uint256 amount) external {
        _pastSupply[blockNum] = amount;
    }

    function getPastVotes(address account, uint256 blockNum) external view returns (uint256) {
        return _pastVotes[account][blockNum];
    }

    function getPastTotalSupply(uint256 blockNum) external view returns (uint256) {
        return _pastSupply[blockNum];
    }
}
