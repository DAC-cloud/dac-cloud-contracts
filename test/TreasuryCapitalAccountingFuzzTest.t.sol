// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {ProposalParams, Tranche} from "../src/interfaces/Structs.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {DealManager} from "../src/kernel/DealManager.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {AbstractDealManagementType} from "../src/kernel/governance/AbstractDealManagementProposals.sol";
import {CoreDealManagementType} from "../src/modules/core/governance/CoreDealManagementProposals.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";
import {Permit2Treasury} from "../src/modules/core/deals/Permit2Treasury.sol";
import {TreasurySpendAllowance} from "../src/modules/core/interfaces/Structs.sol";

contract TreasuryCapitalAccountingFuzzTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    struct CapitalState {
        uint256 trackedStart;
        uint256 invested;
        uint256 returned;
        uint256 spent;
    }

    struct AgentSpendFlow {
        address dealCell;
        address treasuryAddr;
        address destination;
        uint160 totalAllowance;
        uint160 singleTxAmount;
        uint48 duration;
        CapitalState capital;
    }

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);
    }

    function testFuzz_trancheSpendReturnAndForceReturn_preserveCapitalAccounting(
        uint96 rawTranche1,
        uint96 rawTranche2,
        uint96 rawSpend1,
        uint96 rawSpend2,
        uint96 rawReturn1,
        uint96 rawReturn2
    ) public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        address destination1 = makeAddr("destination-1");
        address destination2 = makeAddr("destination-2");

        _enableEarlyReturns(handle);

        CapitalState memory state = CapitalState({
            trackedStart: _trackedBalance(treasuryAddr, destination1, destination2),
            invested: IDealCell(handle.dealCell).getInvestedCapital(address(usdc)),
            returned: IDealCell(handle.dealCell).getReturnedCapital(address(usdc)),
            spent: 0
        });

        uint256 tranche1 = _boundToAvailable(rawTranche1, usdc.balanceOf(dac.getAssetController()));
        if (tranche1 > 0) {
            _requestAndApproveTranche(handle, tranche1);
            state.invested += tranche1;
            _assertCapitalState(handle.dealCell, treasuryAddr, destination1, destination2, state);
        }

        uint256 spend1 = _boundToAvailable(rawSpend1, usdc.balanceOf(treasuryAddr));
        if (spend1 > 0) {
            _directSpend(handle, destination1, spend1);
            state.spent += spend1;
            _assertCapitalState(handle.dealCell, treasuryAddr, destination1, destination2, state);
        }

        uint256 return1 = _boundToAvailable(rawReturn1, usdc.balanceOf(treasuryAddr));
        if (return1 > 0) {
            _returnCapital(handle, return1);
            state.returned += return1;
            _assertCapitalState(handle.dealCell, treasuryAddr, destination1, destination2, state);
        }

        uint256 tranche2 = _boundToAvailable(rawTranche2, usdc.balanceOf(dac.getAssetController()));
        if (tranche2 > 0) {
            _requestAndApproveTranche(handle, tranche2);
            state.invested += tranche2;
            _assertCapitalState(handle.dealCell, treasuryAddr, destination1, destination2, state);
        }

        uint256 spend2 = _boundToAvailable(rawSpend2, usdc.balanceOf(treasuryAddr));
        if (spend2 > 0) {
            _directSpend(handle, destination2, spend2);
            state.spent += spend2;
            _assertCapitalState(handle.dealCell, treasuryAddr, destination1, destination2, state);
        }

        uint256 return2 = _boundToAvailable(rawReturn2, usdc.balanceOf(treasuryAddr));
        if (return2 > 0) {
            _returnCapital(handle, return2);
            state.returned += return2;
            _assertCapitalState(handle.dealCell, treasuryAddr, destination1, destination2, state);
        }

        vm.warp(block.timestamp + 31 days);
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(handle.dealId);

        state.returned = state.invested - state.spent;

        assertEq(usdc.balanceOf(treasuryAddr), 0);
        assertEq(IDealCell(handle.dealCell).getReturnedCapital(address(usdc)), state.returned);
        assertEq(usdc.balanceOf(dac.getAssetController()), state.trackedStart - state.spent);
        assertEq(_trackedBalance(treasuryAddr, destination1, destination2), state.trackedStart);
    }

    function testFuzz_agentSpendAndForceReturn_preserveCapitalAccounting(
        uint96 rawTranche,
        uint96 rawAllowance,
        uint96 rawSingleTx,
        uint96 rawSpend1,
        uint96 rawSpend2,
        uint96 rawSpend3,
        uint32 rawDuration
    ) public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        address destination = makeAddr("agent-destination");

        AgentSpendFlow memory flow = AgentSpendFlow({
            dealCell: handle.dealCell,
            treasuryAddr: treasuryAddr,
            destination: destination,
            totalAllowance: 0,
            singleTxAmount: 0,
            duration: 0,
            capital: CapitalState({
                trackedStart: _trackedBalance(treasuryAddr, destination, address(0)),
                invested: IDealCell(handle.dealCell).getInvestedCapital(address(usdc)),
                returned: 0,
                spent: 0
            })
        });

        uint256 tranche = _boundToAvailable(rawTranche, usdc.balanceOf(dac.getAssetController()));
        if (tranche > 0) {
            _requestAndApproveTranche(handle, tranche);
            flow.capital.invested += tranche;
        }

        uint256 treasuryBalance = usdc.balanceOf(treasuryAddr);
        flow.totalAllowance = uint160(bound(rawAllowance, 1, treasuryBalance));
        flow.singleTxAmount = uint160(bound(rawSingleTx, 1, flow.totalAllowance));
        flow.duration = uint48(bound(rawDuration, 1 hours, 7 days));

        _approveAgentSpend(handle, agent1, destination, flow.totalAllowance, flow.singleTxAmount, flow.duration);
        uint96[3] memory rawSpends = [rawSpend1, rawSpend2, rawSpend3];
        flow = _runAgentSpendFlow(flow, rawSpends);

        vm.warp(block.timestamp + 31 days);
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(handle.dealId);

        flow.capital.returned = flow.capital.invested - flow.capital.spent;

        assertEq(usdc.balanceOf(treasuryAddr), 0);
        assertEq(IDealCell(handle.dealCell).getReturnedCapital(address(usdc)), flow.capital.returned);
        assertEq(usdc.balanceOf(dac.getAssetController()), flow.capital.trackedStart - flow.capital.spent);
        assertEq(_trackedBalance(treasuryAddr, destination, address(0)), flow.capital.trackedStart);
    }

    function _runAgentSpendFlow(
        AgentSpendFlow memory flow,
        uint96[3] memory rawSpends
    ) internal returns (AgentSpendFlow memory) {
        for (uint256 i = 0; i < rawSpends.length; i++) {
            if (i > 0) {
                vm.warp(block.timestamp + flow.duration + 1);
            }

            uint256 spendAmount = _boundToAvailable(
                rawSpends[i],
                _min3(
                    uint256(flow.totalAllowance),
                    uint256(flow.singleTxAmount),
                    usdc.balanceOf(flow.treasuryAddr)
                )
            );

            if (spendAmount > 0) {
                _executeAgentSpend(flow.treasuryAddr, flow.destination, spendAmount);
                flow.capital.spent += spendAmount;
                flow.totalAllowance -= uint160(spendAmount);
                _assertCapitalState(
                    flow.dealCell,
                    flow.treasuryAddr,
                    flow.destination,
                    address(0),
                    flow.capital
                );
            }
        }

        return flow;
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

    function _requestAndApproveTranche(DealHandle memory handle, uint256 amount) internal {
        vm.startPrank(agent1);
        uint256 trancheRequestId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: address(usdc),
                i: bytes32(amount),
                data: abi.encode(uint256(0))
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

        Tranche memory tranche = IDealCell(handle.dealCell).fundingTranche(trancheRequestId);
        assertEq(tranche.amount, amount);

        vm.warp(block.timestamp + 1);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(dacProposalId)).vote(true);
        dac.executeDACProposal(dacProposalId);
        vm.stopPrank();
    }

    function _enableEarlyReturns(DealHandle memory handle) internal {
        vm.startPrank(agent1);
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
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
    }

    function _directSpend(DealHandle memory handle, address destination, uint256 amount) internal {
        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_DIRECT_SPEND,
                target: address(usdc),
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

    function _returnCapital(DealHandle memory handle, uint256 amount) internal {
        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.RETURN_CAPITAL_TO_DAC,
                target: address(usdc),
                i: 0,
                data: abi.encode(amount)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
    }

    function _approveAgentSpend(
        DealHandle memory handle,
        address agent,
        address destination,
        uint160 totalAmount,
        uint160 singleTxAmount,
        uint48 duration
    ) internal {
        TreasurySpendAllowance memory allowance = TreasurySpendAllowance({
            totalAmount: totalAmount,
            singleTxAmount: singleTxAmount,
            clockLimit: 0,
            duration: duration
        });

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_AGENT_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(agent, destination, allowance)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
    }

    function _executeAgentSpend(address treasuryAddr, address destination, uint256 amount) internal {
        vm.prank(agent1);
        Permit2Treasury(treasuryAddr).executeAgentSpend(
            address(usdc),
            destination,
            uint160(amount)
        );
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
                return uint256(logs[i].topics[3]);
            }
        }

        revert("proposal id not found");
    }

    function _assertCapitalState(
        address dealCell,
        address treasuryAddr,
        address destination1,
        address destination2,
        CapitalState memory state
    ) internal {
        assertEq(IDealCell(dealCell).getInvestedCapital(address(usdc)), state.invested);
        assertEq(IDealCell(dealCell).getReturnedCapital(address(usdc)), state.returned);
        assertLe(state.returned, state.invested);
        assertEq(usdc.balanceOf(treasuryAddr), state.invested - state.returned - state.spent);
        assertEq(_trackedBalance(treasuryAddr, destination1, destination2), state.trackedStart);
    }

    function _trackedBalance(address treasuryAddr, address destination1, address destination2) internal view returns (uint256) {
        return
            usdc.balanceOf(dac.getAssetController()) +
            usdc.balanceOf(treasuryAddr) +
            usdc.balanceOf(destination1) +
            usdc.balanceOf(destination2);
    }

    function _boundToAvailable(uint256 rawAmount, uint256 available) internal pure returns (uint256) {
        if (available == 0) {
            return 0;
        }

        return bound(rawAmount, 0, available);
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 minValue = a < b ? a : b;
        return minValue < c ? minValue : c;
    }
}
