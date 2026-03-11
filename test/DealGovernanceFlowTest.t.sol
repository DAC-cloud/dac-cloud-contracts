// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {ProposalParams} from "../src/interfaces/Structs.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {AbstractDealManagementType} from "../src/kernel/governance/AbstractDealManagementProposals.sol";
import {CoreDealManagementType} from "../src/modules/core/governance/CoreDealManagementProposals.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";

contract DealGovernanceFlowTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    function setUp() public {
        setUpBase();

        onboardAgent(agent1);
        onboardAgent(agent2);
    }

    function test_requestTranche_createsDACProposalAndFundsTreasury() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        uint256 trancheRequestId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: address(usdc),
                i: bytes32(uint256(5_000)),
                data: bytes("")
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, trancheRequestId, agent1, true);
        _voteDealProposal(handle.dealAddr, trancheRequestId, agent2, true);

        vm.recordLogs();
        Deal(handle.dealAddr).executeStakedAgentProposal(trancheRequestId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 dacProposalId = _findProposalIdFromData(
            logs,
            keccak256("TrancheCreated(address,uint256,uint256,uint256)")
        );

        assertEq(IDealCell(handle.dealCell).fundingTranche(trancheRequestId).amount, 5_000);

        vm.warp(block.timestamp + 1);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(dacProposalId)).vote(true);
        dac.executeDACProposal(dacProposalId);
        vm.stopPrank();

        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        assertEq(usdc.balanceOf(treasuryAddr), 15_000);
    }

    function test_permitUnstake_releasesAgentPrincipalAfterApproval() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);

        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake();

        uint256 permitUnstakeId = 1;

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, permitUnstakeId, agent1, true);
        _voteDealProposal(handle.dealAddr, permitUnstakeId, agent2, true);

        Deal(handle.dealAddr).executeStakedAgentProposal(permitUnstakeId);

        assertEq(StakedAgent(IDealCell(handle.dealCell).stakeToken()).balanceOf(agent1), 0);
        assertEq(agentToken.balanceOf(agent1), 100_000);
    }

    function test_toggleEarlyReturns_thenReturnCapitalToDAC() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        uint256 toggleProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS,
                target: address(0),
                i: 0,
                data: abi.encode(true)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, toggleProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, toggleProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(toggleProposalId);

        assertTrue(IDealCell(handle.dealCell).allowEarlyReturns());

        uint256 dacBalanceBefore = usdc.balanceOf(address(dac));

        vm.startPrank(agent1);
        uint256 returnProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.RETURN_CAPITAL_TO_DAC,
                target: address(usdc),
                i: 0,
                data: abi.encode(uint256(4_000))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, returnProposalId, agent1, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(returnProposalId);

        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        assertEq(IDealCell(handle.dealCell).getReturnedCapital(address(usdc)), 4_000);
        assertEq(usdc.balanceOf(address(dac)), dacBalanceBefore + 4_000);
        assertEq(usdc.balanceOf(treasuryAddr), 6_000);
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

    function _findProposalIdFromData(Vm.Log[] memory logs, bytes32 eventSig) internal pure returns (uint256 proposalId) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                return abi.decode(logs[i].data, (uint256));
            }
        }

        revert("proposal id not found");
    }
}
