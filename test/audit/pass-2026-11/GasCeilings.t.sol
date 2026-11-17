// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md, section 7). Gas measurement harness, not an assertion
// suite: it prints the figures behind the gas tables. Run with --isolate so every top-level
// call is its own transaction (cold storage), and size it through the environment, e.g.
//   N_HOLDERS=100 K_RESULTS=10 forge test --match-path 'test/audit/pass-2026-11/*GasCeilings*' --isolate -vv
// Variables: N_HOLDERS, K_RESULTS, N_COEFFS, DESC_BYTES, AGENTS_LIMIT.

import "forge-std/Test.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {DealParams, ProposalParams, EvaluationResult} from "../../../src/interfaces/Structs.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {Deal} from "../../../src/kernel/Deal.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {StakedAgent} from "../../../src/kernel/tokens/StakedAgent.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {CoreDealType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {TreasuryDealFactory} from "../../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {
    MockEvaluator,
    MockEvaluatorFactory,
    MockEvaluatorModuleFactory,
    MOCK_EVALUATOR_SELECTOR
} from "../../DealEvaluationRecoveryTest.t.sol";

/// Gas ceilings for the holder loops. Run with `--isolate` so every top-level call is
/// its own transaction (cold storage, real refunds) and read the numbers from the logs.
contract HolderLoopGasTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    MockEvaluatorModuleFactory mockModule;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);

        vm.prank(moduleOwner);
        mockModule = new MockEvaluatorModuleFactory(
            address(new TreasuryDealFactory(permit2)), address(new MockEvaluatorFactory())
        );

        vm.startPrank(founder);
        uint256 proposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(mockModule), i: 0, data: bytes("")
            })
        );
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(proposalId)).vote(true);
        dac.executeDACProposal(proposalId);
        vm.stopPrank();
    }

    /// forge-std v1.17.0 declares a wider `Gas` struct than the forge v1.5.1 binary returns,
    /// so decode the five words the binary actually returns.
    function _lastGas() internal view returns (uint256 used) {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok, "lastCallGas failed");
        (, uint64 total,,,) = abi.decode(ret, (uint64, uint64, uint64, int64, uint64));
        used = total;
    }

    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0xA11CE00000 + i));
    }

    function _createDeal(uint256 descBytes) internal returns (DealHandle memory handle, uint256 createGas) {
        vm.recordLogs();

        bytes memory desc = new bytes(descBytes);
        for (uint256 i = 0; i < descBytes; i++) {
            desc[i] = 0x61;
        }

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Gas Deal",
            description: string(desc),
            linkHash: "0x00",
            moduleFactory: address(mockModule),
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
            dealConfig: abi.encode("mock deal config"),
            evaluatorConfig: abi.encode(address(this), new EvaluationResult[](0)),
            evaluatorModuleFactory: address(0),
            agentsLimit: vm.envOr("AGENTS_LIMIT", uint256(0)),
            minimalStake: 0
        });

        vm.prank(agent1);
        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) =
            DealManager(dealManager).createDealProposal(params);
        createGas = _lastGas();

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

    function _single(uint8 action, uint256 percent) internal pure returns (EvaluationResult[] memory results) {
        results = new EvaluationResult[](1);
        results[0] = EvaluationResult(action, percent, 0);
    }

    function test_gas_holderLoops() public {
        uint256 n = vm.envOr("N_HOLDERS", uint256(10));
        uint256 descBytes = vm.envOr("DESC_BYTES", uint256(32));

        (DealHandle memory handle, uint256 createGas) = _createDeal(descBytes);
        emit log_named_uint("N_HOLDERS", n);
        emit log_named_uint("DESC_BYTES", descBytes);
        emit log_named_uint("gas createDealProposal (TreasuryDeal + mock evaluator)", createGas);

        vm.warp(block.timestamp + 1);

        // agent1 is holder #0
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        emit log_named_uint("gas stakeToDeal holder #1", _lastGas());

        uint256 lastStakeGas;
        for (uint256 i = 1; i < n; i++) {
            address h = _holder(i);
            vm.prank(address(dac));
            agentToken.mint(h, 100_000);
            vm.prank(agent1);
            IDealCell(handle.dealCell).invite(h, false);
            vm.prank(h);
            agentToken.stakeToDeal(handle.dealCell, 20_000);
            lastStakeGas = _lastGas();
        }
        emit log_named_uint("gas stakeToDeal last holder", lastStakeGas);

        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        emit log_named_uint("gas executeDACProposal(APPROVE_DEAL)", _lastGas());
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // convert #1: every holder's claimable slot goes 0 -> nonzero
        MockEvaluator(handle.evaluatorAddr).setResults(_single(1, MathLib.atScale(10)));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        emit log_named_uint("gas evaluateDeal convert (first, cold slots)", _lastGas());

        // convert #2: nonzero -> nonzero
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        emit log_named_uint("gas evaluateDeal convert (second)", _lastGas());

        // slash 10%: burn on every holder
        vm.warp(block.timestamp + 1);
        MockEvaluator(handle.evaluatorAddr).setResults(_single(0, MathLib.atScale(10)));
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        emit log_named_uint("gas evaluateDeal slash", _lastGas());

        // worst realistic single evaluation: convert + slash + close in one result set
        vm.warp(block.timestamp + 1);
        EvaluationResult[] memory three = new EvaluationResult[](3);
        three[0] = EvaluationResult(1, MathLib.atScale(10), 0);
        three[1] = EvaluationResult(0, MathLib.atScale(10), 0);
        three[2] = EvaluationResult(3, 0, 0);
        MockEvaluator(handle.evaluatorAddr).setResults(three);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        emit log_named_uint("gas evaluateDeal convert+slash+close", _lastGas());

        // claim and withdraw paths
        vm.prank(agent1);
        IDealCell(handle.dealCell).claimMainToken(0);
        emit log_named_uint("gas claimMainToken", _lastGas());

        vm.warp(IDealCell(handle.dealCell).dealDeadline() + 1);
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(handle.dealId);
        emit log_named_uint("gas forceReturnCapital (1 funding token)", _lastGas());

        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake();
        emit log_named_uint("gas unstake (closed deal)", _lastGas());
    }

    function test_gas_whitelistToggleLoop() public {
        uint256 n = vm.envOr("N_HOLDERS", uint256(10));
        (DealHandle memory handle,) = _createDeal(32);
        vm.warp(block.timestamp + 1);

        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        for (uint256 i = 1; i < n; i++) {
            address h = _holder(i);
            vm.prank(address(dac));
            agentToken.mint(h, 100_000);
            vm.prank(agent1);
            IDealCell(handle.dealCell).invite(h, false);
            vm.prank(h);
            agentToken.stakeToDeal(handle.dealCell, 20_000);
        }
        vm.warp(block.timestamp + 1);

        // whitelist off, then on again (the second toggle re-invites every holder)
        uint256 offGas = _toggleWhitelist(handle, false);
        uint256 onGas = _toggleWhitelist(handle, true);
        emit log_named_uint("N_HOLDERS", n);
        emit log_named_uint("gas execute TOGGLE_WHITELIST(false)", offGas);
        emit log_named_uint("gas execute TOGGLE_WHITELIST(true) [whitelistHolders loop]", onGas);
    }

    /// One evaluation carrying K results (convert, slash, convert, slash, ...), as a
    /// MilestoneBasedEvaluator produces when several milestones fall due together
    /// (up to 3 * milestones + 1 results). Every convert/slash result is one full pass over holders[].
    function test_gas_multiResultEvaluation() public {
        uint256 n = vm.envOr("N_HOLDERS", uint256(10));
        uint256 k = vm.envOr("K_RESULTS", uint256(4));

        (DealHandle memory handle,) = _createDeal(32);
        vm.warp(block.timestamp + 1);

        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        for (uint256 i = 1; i < n; i++) {
            address h = _holder(i);
            vm.prank(address(dac));
            agentToken.mint(h, 100_000);
            vm.prank(agent1);
            IDealCell(handle.dealCell).invite(h, false);
            vm.prank(h);
            agentToken.stakeToDeal(handle.dealCell, 20_000);
        }

        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        EvaluationResult[] memory results = new EvaluationResult[](k);
        for (uint256 i = 0; i < k; i++) {
            results[i] =
                i % 2 == 0 ? EvaluationResult(1, MathLib.atScale(1), 0) : EvaluationResult(0, MathLib.atScale(1), 0);
        }
        MockEvaluator(handle.evaluatorAddr).setResults(results);

        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        emit log_named_uint("N_HOLDERS", n);
        emit log_named_uint("K_RESULTS", k);
        emit log_named_uint("gas evaluateDeal (K alternating convert/slash results)", _lastGas());
    }

    function _toggleWhitelist(DealHandle memory handle, bool on) internal returns (uint256 gasUsed) {
        vm.prank(agent1);
        uint256 proposalId = Deal(handle.dealAddr)
            .createStakedAgentProposal(
                ProposalParams({
                    typ: AbstractDealManagementType.TOGGLE_WHITELIST, target: address(0), i: 0, data: abi.encode(on)
                })
            );
        vm.warp(block.timestamp + 1);
        uint256 n = vm.envOr("N_HOLDERS", uint256(10));
        address proposal = Deal(handle.dealAddr).getProposal(proposalId);
        vm.prank(agent1);
        IVoting(proposal).vote(true);
        for (uint256 i = 1; i < n; i++) {
            vm.prank(_holder(i));
            IVoting(proposal).vote(true);
        }
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
        gasUsed = _lastGas();
        vm.warp(block.timestamp + 1);
    }
}
