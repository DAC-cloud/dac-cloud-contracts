// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {DACConfig, CapitalCall, DealParams, ProposalParams} from "../src/interfaces/Structs.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {IDACCell} from "../src/interfaces/IDACCell.sol";
import {IAssetController} from "../src/interfaces/IAssetController.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {DACCell} from "../src/kernel/DACCell.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {IVotes} from "../src/lib/IVotes.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../src/kernel/governance/AbstractDealManagementProposals.sol";
import {CoreDealType, CoreEvaluatorType} from "../src/modules/core/CoreModuleDeals.sol";
import {CoreDealManagementType} from "../src/modules/core/governance/CoreDealManagementProposals.sol";
import {AgentDeal} from "../src/modules/core/deals/AgentDeal.sol";
import {MilestoneBasedEvaluator} from "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {Milestone} from "../src/modules/core/interfaces/Structs.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";

/// @notice End-to-end coverage for AgentDeal: a home DAC acting as an agent
///         inside a separate host DAC (stake, originate/participate in host
///         deals, route earned assets home).
contract AgentDealTest is DACTestBase {
    address public agent1 = makeAddr("home-agent-1");
    address public agent2 = makeAddr("home-agent-2");

    // Host DAC context.
    address public hostFounder = makeAddr("host-founder");
    DACCell public hostDac;
    MainToken public hostMainToken;
    AgentToken public hostAgentToken;
    address public hostDealManager;

    uint256 constant HOME_STAKE = 20_000;
    uint256 constant HOST_AGENT_MINT = 100_000;
    uint256 constant HOST_STAKE_AMOUNT = 50_000;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);
        _deployHostDac();
    }

    // --------------------------------------------------------------------- //
    //                              Binding                                   //
    // --------------------------------------------------------------------- //

    function test_agentDeal_bindsHostDac() public {
        DealHandle memory handle = _createAgentDeal(agent1);

        AgentDeal agentDeal = AgentDeal(handle.dealAddr);
        assertEq(agentDeal.managedEntity(), address(hostDac), "host DAC not bound");

        (address boundAgentToken, address boundMainToken) = agentDeal.hostDNA();
        assertEq(boundAgentToken, address(hostAgentToken), "host agent token DNA mismatch");
        assertEq(boundMainToken, address(hostMainToken), "host main token DNA mismatch");
    }

    function test_agentDeal_revertsWithoutHostTarget() public {
        // dealTarget == address(0) must be rejected at initialization.
        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        IDealManager(dealManager).createDealProposal(_agentDealParams(agent1, address(0)));
    }

    // --------------------------------------------------------------------- //
    //               Originate + stake + participate (headline)              //
    // --------------------------------------------------------------------- //

    function test_agentDeal_originatesStakesAndGovernsHostDeal() public {
        (DealHandle memory handle, address hostDealCell) = _setupStakedAgentDealInHost();

        // HOST_STAKE minted host StakedAgent to the deal and self-delegated it.
        StakedAgent hostStake = StakedAgent(IDealCell(hostDealCell).stakeToken());
        assertEq(hostStake.balanceOf(handle.dealAddr), HOST_STAKE_AMOUNT, "host stake not minted to deal");
        assertEq(hostStake.delegates(handle.dealAddr), handle.dealAddr, "deal did not self-delegate host stake");
        assertGt(hostStake.getVotes(handle.dealAddr), 0, "deal has no host voting power");

        // HOST_CREATE_PROPOSAL: the agent-deal proposes inside the host deal.
        ProposalParams memory hostProposal = ProposalParams({
            typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS,
            target: address(0),
            i: 0,
            data: abi.encode(true)
        });
        Vm.Log[] memory logs = _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.HOST_CREATE_PROPOSAL,
                target: address(0),
                i: 0,
                data: abi.encode(hostDealCell, hostProposal)
            })
        );
        uint256 hostProposalId = uint256(_findTopic(logs, keccak256("HostProposalCreated(address,uint256,bytes4)"), 2));

        // HOST_VOTE: the agent-deal votes its host stake on that proposal.
        _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.HOST_VOTE,
                target: address(0),
                i: 0,
                data: abi.encode(hostDealCell, hostProposalId, true)
            })
        );

        // Anyone can execute the now-resolved host proposal.
        vm.warp(block.timestamp + 1);
        Deal(address(IDealCell(hostDealCell).deal())).executeStakedAgentProposal(hostProposalId);

        assertTrue(IDealCell(hostDealCell).allowEarlyReturns(), "host proposal not executed via agent-deal");
    }

    // --------------------------------------------------------------------- //
    //                       Reward routing back home                        //
    // --------------------------------------------------------------------- //

    function test_agentDeal_returnsEarnedAssetToHomeTreasury() public {
        DealHandle memory handle = _createAgentDeal(agent1);
        _activateAgentDeal(handle, agent1);

        // Simulate host incentives earned by the deal (a foreign asset to home).
        uint256 earned = 1_000e18;
        vm.prank(hostFounder);
        hostMainToken.transfer(handle.dealAddr, earned);

        address treasuryHolder = IAssetController(dac.getAssetController()).treasuryHolder();
        uint256 treasuryBefore = hostMainToken.balanceOf(treasuryHolder);

        _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.RETURN_ASSET_TO_DAC,
                target: address(hostMainToken),
                i: 0,
                data: abi.encode(earned)
            })
        );

        assertEq(hostMainToken.balanceOf(handle.dealAddr), 0, "asset not routed out of deal");
        assertEq(
            hostMainToken.balanceOf(treasuryHolder),
            treasuryBefore + earned,
            "earned asset did not reach home treasury"
        );
    }

    function test_agentDeal_cannotReturnHomeMainToken() public {
        DealHandle memory handle = _createAgentDeal(agent1);
        _activateAgentDeal(handle, agent1);

        // Give the deal some home main token (founder holds the allocation).
        vm.prank(founder);
        mainToken.transfer(handle.dealAddr, 1e18);

        vm.prank(agent1);
        uint256 pid = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.RETURN_ASSET_TO_DAC,
                target: address(mainToken),
                i: 0,
                data: abi.encode(uint256(1e18))
            })
        );
        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, pid, agent1, true);
        vm.warp(block.timestamp + 1);

        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);
    }

    function test_agentDeal_claimRewardDispatchesToHost() public {
        (DealHandle memory handle, address hostDealCell) = _setupStakedAgentDealInHost();

        // No host evaluation happened, so the host claim must revert through to us.
        vm.prank(agent1);
        uint256 pid = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.HOST_CLAIM_REWARD,
                target: address(0),
                i: 0,
                data: abi.encode(hostDealCell, uint256(0))
            })
        );
        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, pid, agent1, true);
        vm.warp(block.timestamp + 1);

        vm.expectRevert(DACErrorsLib.NoClaimableRewards.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);
    }

    // --------------------------------------------------------------------- //
    //                                Unstake                                 //
    // --------------------------------------------------------------------- //

    function test_agentDeal_unstakesFromHostDeal() public {
        (DealHandle memory handle, address hostDealCell) = _setupStakedAgentDealInHost();

        uint256 agentTokensBefore = hostAgentToken.balanceOf(handle.dealAddr);

        // Host deal is unapproved; unstake is permitted once its approve deadline passes.
        vm.warp(block.timestamp + 2 days);

        _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.HOST_UNSTAKE,
                target: address(0),
                i: 0,
                data: abi.encode(hostDealCell)
            })
        );

        assertEq(
            StakedAgent(IDealCell(hostDealCell).stakeToken()).balanceOf(handle.dealAddr),
            0,
            "host stake not released"
        );
        assertEq(
            hostAgentToken.balanceOf(handle.dealAddr),
            agentTokensBefore + HOST_STAKE_AMOUNT,
            "host agent tokens not returned"
        );
    }

    // --------------------------------------------------------------------- //
    //                              Negatives                                 //
    // --------------------------------------------------------------------- //

    function test_agentDeal_rejectsForeignHostDeal() public {
        DealHandle memory handle = _createAgentDeal(agent1);
        _activateAgentDeal(handle, agent1);

        // A deal cell registered in the HOME DAC is not part of the bound host DAC.
        DealHandle memory homeTreasury = createTreasuryDeal(agent2);

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.InvalidDealAddress.selector);
        Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.HOST_STAKE,
                target: address(0),
                i: 0,
                data: abi.encode(homeTreasury.dealCell, HOST_STAKE_AMOUNT)
            })
        );
    }

    function test_agentDeal_rejectsUnsupportedProposal() public {
        DealHandle memory handle = _createAgentDeal(agent1);
        _activateAgentDeal(handle, agent1);

        // REINVEST_PROFITS belongs to DACDeal, not AgentDeal.
        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.ProposalNotSupported.selector);
        Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.REINVEST_PROFITS,
                target: address(usdc),
                i: 0,
                data: abi.encode(uint256(1), bytes32(0))
            })
        );
    }

    function test_agentDeal_nonStakerCannotPropose() public {
        DealHandle memory handle = _createAgentDeal(agent1);
        _activateAgentDeal(handle, agent1);

        // agent2 never staked into the agent-deal. RETURN_ASSET_TO_DAC has no
        // host pre-validation, so the staker check is what rejects the call.
        vm.prank(agent2);
        vm.expectRevert(DACErrorsLib.NotStakedAgent.selector);
        Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.RETURN_ASSET_TO_DAC,
                target: address(hostMainToken),
                i: 0,
                data: abi.encode(uint256(1))
            })
        );
    }

    // --------------------------------------------------------------------- //
    //                 Audit 2026-10: invites, approve-stake, self-host       //
    // --------------------------------------------------------------------- //

    function test_agentDeal_rejectsSelfHosting() public {
        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        IDealManager(dealManager).createDealProposal(_agentDealParams(agent1, address(dac)));
    }

    /// The agent-deal is the sole initial inviter of host deals it originates; without
    /// HOST_INVITE a whitelist-only host deal could never be staffed.
    function test_agentDeal_invitesIntoOriginatedHostDeal() public {
        (DealHandle memory handle, address hostDealCell) = _setupStakedAgentDealInHost();

        address hostAgent = makeAddr("host-agent");
        _mintHostAgentTokens(hostAgent, 10_000);

        vm.prank(hostAgent);
        vm.expectRevert(DACErrorsLib.NotWhitelistedAgent.selector);
        hostAgentToken.stakeToDeal(hostDealCell, 10_000);

        _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.HOST_INVITE,
                target: address(0),
                i: 0,
                data: abi.encode(hostDealCell, hostAgent, false)
            })
        );

        vm.prank(hostAgent);
        hostAgentToken.stakeToDeal(hostDealCell, 10_000);
        assertEq(StakedAgent(IDealCell(hostDealCell).stakeToken()).balanceOf(hostAgent), 10_000);
    }

    /// Joining an already-approved host deal (originated by someone else) goes through
    /// HOST_APPROVE_STAKE + the host's ADD_STAKE. The position must carry voting power,
    /// so delegation is set up front, before any stake exists.
    function test_agentDeal_approveStakeSelfDelegatesHostStake() public {
        DealHandle memory handle = _createAgentDeal(agent1);
        _activateAgentDeal(handle, agent1);
        _mintHostAgentTokens(handle.dealAddr, HOST_AGENT_MINT);

        // A native host agent originates and stakes a host deal, inviting the agent-deal.
        address hostAgent = makeAddr("host-agent");
        _mintHostAgentTokens(hostAgent, 50_000);

        DealParams memory hostParams = _hostTreasuryDealParams();
        hostParams.proposer = hostAgent;

        vm.recordLogs();
        vm.prank(hostAgent);
        (, address hostDealCell,,) = IDealManager(hostDealManager).createDealProposal(hostParams);
        uint256 hostApproveId = uint256(
            _findTopic(vm.getRecordedLogs(), keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)"), 3)
        );

        vm.warp(block.timestamp + 1);
        vm.startPrank(hostAgent);
        IDealCell(hostDealCell).invite(handle.dealAddr, false);
        hostAgentToken.stakeToDeal(hostDealCell, 20_000);
        vm.stopPrank();

        vm.startPrank(hostFounder);
        IVoting(hostDac.getProposalVoting(hostApproveId)).vote(true);
        hostDac.executeDACProposal(hostApproveId);
        vm.stopPrank();
        assertTrue(IDealCell(hostDealCell).isApproved());

        StakedAgent hostStake = StakedAgent(IDealCell(hostDealCell).stakeToken());
        assertEq(hostStake.balanceOf(handle.dealAddr), 0);
        assertEq(hostStake.delegates(handle.dealAddr), address(0));

        _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.HOST_APPROVE_STAKE,
                target: address(0),
                i: 0,
                data: abi.encode(hostDealCell, HOST_STAKE_AMOUNT)
            })
        );

        assertEq(hostAgentToken.allowance(handle.dealAddr, hostDealCell), HOST_STAKE_AMOUNT);
        assertEq(hostStake.delegates(handle.dealAddr), handle.dealAddr, "approve-stake did not self-delegate");
    }

    // --------------------------------------------------------------------- //
    //                              Helpers                                   //
    // --------------------------------------------------------------------- //

    function _setupStakedAgentDealInHost()
        internal
        returns (DealHandle memory handle, address hostDealCell)
    {
        handle = _createAgentDeal(agent1);
        _activateAgentDeal(handle, agent1);

        // Host DAC recognises the agent-deal as an agent.
        _mintHostAgentTokens(handle.dealAddr, HOST_AGENT_MINT);

        // The agent-deal originates a new host deal (proposer is forced to itself,
        // so it is auto-whitelisted and can immediately stake into it).
        Vm.Log[] memory createLogs = _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.HOST_CREATE_DEAL,
                target: address(0),
                i: 0,
                data: abi.encode(_hostTreasuryDealParams())
            })
        );
        hostDealCell = address(uint160(uint256(
            _findTopic(createLogs, keccak256("HostDealCreated(address,uint256)"), 1)
        )));
        assertTrue(hostDealCell != address(0), "host deal not created");

        // Stake into the freshly originated host deal.
        _passAgentProposal(
            handle,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.HOST_STAKE,
                target: address(0),
                i: 0,
                data: abi.encode(hostDealCell, HOST_STAKE_AMOUNT)
            })
        );
    }

    function _deployHostDac() internal {
        usdc.mint(hostFounder, 100_000e6);

        vm.startPrank(hostFounder);

        DACConfig memory config = DACConfig({
            symbol: "FARM",
            name: "Farmland Field DAC",
            description: "owns the field",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: hostFounder,
            founderAllocation: 200_000_000e18,
            treasuryToken: address(usdc),
            founderCommitment: 20_000e6,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("HostDAC-v1", block.timestamp));
        (address dacAddress, address mainTokenAddress, address agentTokenAddress) =
            dacFactory.deployDAC(config, salt, address(0));

        hostDac = DACCell(dacAddress);
        hostMainToken = MainToken(mainTokenAddress);
        hostAgentToken = AgentToken(agentTokenAddress);

        usdc.approve(hostDac.getAssetController(), 20_000e6);
        hostDac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: 0,
                tokenRecipient: hostFounder,
                tokenAmount: 200_000_000e18,
                cashAmount: 20_000e6
            })
        );
        hostMainToken.delegate(hostFounder);

        vm.stopPrank();

        hostDealManager = hostDac.getDealManager();
    }

    function _mintHostAgentTokens(address to, uint256 amount) internal {
        vm.startPrank(hostFounder);
        uint256 propId = hostDac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.MINT_AGENT_TOKENS,
                target: to,
                i: bytes32(amount),
                data: bytes("")
            })
        );
        vm.warp(block.timestamp + 1);
        IVoting(hostDac.getProposalVoting(propId)).vote(true);
        hostDac.executeDACProposal(propId);
        vm.stopPrank();
    }

    function _createAgentDeal(address agent) internal returns (DealHandle memory handle) {
        vm.recordLogs();
        vm.prank(agent);
        (handle.dealId, handle.dealCell, handle.dealAddr, handle.evaluatorAddr) =
            IDealManager(dealManager).createDealProposal(_agentDealParams(agent, address(hostDac)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }

    function _activateAgentDeal(DealHandle memory handle, address agent) internal {
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent, handle.dealCell, HOME_STAKE);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
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

    function _passAgentProposal(DealHandle memory handle, address voter, ProposalParams memory params)
        internal
        returns (Vm.Log[] memory logs)
    {
        vm.prank(voter);
        uint256 pid = Deal(handle.dealAddr).createStakedAgentProposal(params);

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, pid, voter, true);

        vm.warp(block.timestamp + 1);
        vm.recordLogs();
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);
        logs = vm.getRecordedLogs();
    }

    function _agentDealParams(address agent, address hostTarget) internal view returns (DealParams memory params) {
        params = DealParams({
            dealKind: CoreDealType.AGENT_DEAL,
            name: "Drone Service Agent",
            description: "acts as an agent inside the field DAC",
            linkHash: "0x00112233",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: hostTarget,
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 0,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode("agent deal"),
            evaluatorConfig: _milestoneEvaluatorConfig(),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });
    }

    function _hostTreasuryDealParams() internal view returns (DealParams memory params) {
        params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Field Fertilizer Deal",
            description: "host deal originated by the drone agent",
            linkHash: "0x00112233",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: address(0), // overwritten to the agent-deal on execution
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 0,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode("host deal"),
            evaluatorConfig: _milestoneEvaluatorConfig(),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });
    }

    function _milestoneEvaluatorConfig() internal view returns (bytes memory) {
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
            extension: 0,
            excludePrincipal: false
        });
        milestones[0].rewardCurve[0] = 1e18;
        milestones[0].penaltyCurve[0] = 1e18;

        return abi.encode(MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones));
    }

    function _findTopic(Vm.Log[] memory logs, bytes32 sig, uint256 topicIndex) internal pure returns (bytes32) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                return logs[i].topics[topicIndex];
            }
        }
        revert("event not found");
    }
}
