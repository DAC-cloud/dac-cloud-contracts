// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase, MockUSDC} from "./base/DACTestBase.t.sol";
import {CapitalCall, DealParams, ProposalParams} from "../src/interfaces/Structs.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {DealManager} from "../src/kernel/DealManager.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {CoreDealManagementType} from "../src/modules/core/governance/CoreDealManagementProposals.sol";
import {CoreDealType, CoreEvaluatorType} from "../src/modules/core/CoreModuleDeals.sol";
import {MilestoneBasedEvaluator} from "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {Milestone} from "../src/modules/core/interfaces/Structs.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";

contract DACAccountingFuzzTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);
    }

    function testFuzz_recoverTreasury_syncsExternalDepositsBeforeFunding(
        uint96 rawDeposit,
        uint96 rawFunding
    ) public {
        MockUSDC extraToken = new MockUSDC();
        uint256 depositAmount = bound(rawDeposit, 1, 1_000_000e18);
        uint256 fundingAmount = bound(rawFunding, 1, depositAmount);

        extraToken.mint(founder, depositAmount);

        DealHandle memory handle = _createTreasuryDealWithToken(agent1, address(extraToken), fundingAmount);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);

        vm.prank(founder);
        extraToken.transfer(address(dac), depositAmount);

        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        vm.expectRevert(DACErrorsLib.InsufficientTreasury.selector);
        dac.executeDACProposal(handle.proposalId);

        dac.recoverTreasury(address(extraToken));
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();

        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        assertEq(extraToken.balanceOf(treasuryAddr), fundingAmount);
        assertEq(extraToken.balanceOf(dac.getAssetController()), depositAmount - fundingAmount);
        assertEq(IDealCell(handle.dealCell).getInvestedCapital(address(extraToken)), fundingAmount);
    }

    function testFuzz_capitalCallToExternalRecipient_updatesSupplyAndSingleUse(
        uint96 rawTokenAmount,
        uint96 rawCashAmount
    ) public {
        address recipient = makeAddr("capital-call-recipient");
        uint256 tokenAmount = bound(rawTokenAmount, 1, 50_000_000e18);
        uint256 cashAmount = bound(rawCashAmount, 1, usdc.balanceOf(founder));

        usdc.mint(address(recipient), cashAmount);

        vm.startPrank(recipient);
        usdc.approve(dac.getAssetController(), cashAmount);
        vm.stopPrank();

        uint256 releasedBefore = DealManager(dealManager).totalReleasedVotable();
        uint256 dacTreasuryBefore = usdc.balanceOf(dac.getAssetController());
        uint256 supplyBefore = mainToken.totalSupply();

        uint256 proposalId = _createAndExecuteCapitalCallProposal(recipient, tokenAmount, cashAmount);
        CapitalCall memory call = _capitalCall(proposalId, recipient, tokenAmount, cashAmount);
        bytes32 callHash = keccak256(abi.encode(call));

        vm.startPrank(founder);
        usdc.approve(dac.getAssetController(), cashAmount);
        dac.fulfillCapitalCall(call);
        vm.expectRevert(DACErrorsLib.AlreadyFulfilled.selector);
        dac.fulfillCapitalCall(call);
        vm.expectRevert(DACErrorsLib.AlreadyFulfilled.selector);
        dac.getCapitalCall(callHash);
        vm.stopPrank();

        assertEq(mainToken.balanceOf(recipient), tokenAmount);
        assertEq(mainToken.totalSupply(), supplyBefore + tokenAmount);
        assertEq(usdc.balanceOf(dac.getAssetController()), dacTreasuryBefore + cashAmount);
        assertEq(DealManager(dealManager).totalReleasedVotable(), releasedBefore + tokenAmount);
    }

    function _createAndExecuteCapitalCallProposal(
        address recipient,
        uint256 tokenAmount,
        uint256 cashAmount
    ) internal returns (uint256 proposalId) {
        vm.startPrank(founder);
        proposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.CAPITAL_CALL,
                target: recipient,
                i: bytes32(tokenAmount),
                data: abi.encode(address(usdc), cashAmount)
            })
        );

        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(proposalId)).vote(true);
        dac.executeDACProposal(proposalId);
        vm.stopPrank();
    }

    function _capitalCall(
        uint256 proposalId,
        address recipient,
        uint256 tokenAmount,
        uint256 cashAmount
    ) internal view returns (CapitalCall memory) {
        return CapitalCall({
            treasuryToken: address(usdc),
            nonce: proposalId,
            tokenRecipient: recipient,
            tokenAmount: tokenAmount,
            cashAmount: cashAmount
        });
    }

    function _setupApprovedTreasuryDealWithTwoAgents() internal returns (DealHandle memory handle) {
        handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);
    }

    function _createTreasuryDealWithToken(
        address agent,
        address fundingToken,
        uint256 fundingAmount
    ) internal returns (DealHandle memory handle) {
        vm.recordLogs();
        vm.startPrank(agent);

        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: fundingToken,
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: fundingAmount,
            timestamp: block.timestamp + 1 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18;
        milestones[0].penaltyCurve[0] = 1e18;

        MilestoneBasedEvaluator.Config memory evaluatorCfg = MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones);

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Sync Treasury Deal",
            description: "Sync Treasury Deal description",
            linkHash: "0x00112233",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: fundingToken,
            fundingAmount: fundingAmount,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: abi.encode(evaluatorCfg)
        });

        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) = IDealManager(dealManager).createDealProposal(params);
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

    function _directSpend(DealHandle memory handle, address token, address destination, uint256 amount) internal {
        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_DIRECT_SPEND,
                target: token,
                i: 0,
                data: abi.encode(destination, uint160(amount))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
    }

    function _stakeAndDelegate(address agent, address dealCell, uint256 amount) internal {
        vm.startPrank(agent);
        agentToken.stakeToDeal(dealCell, amount);
        StakedAgent(IDealCell(dealCell).stakeToken()).delegate(agent);
        vm.stopPrank();
    }

    function _approveDeal(DealHandle memory handle) internal {
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();
    }

    function _voteDealProposal(address dealAddr, uint256 proposalId, address voter, bool support) internal {
        address proposal = Deal(dealAddr).getProposal(proposalId);
        vm.prank(voter);
        IVoting(proposal).vote(support);
    }
}
