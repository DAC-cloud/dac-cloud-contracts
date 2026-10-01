// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACEventsLib} from "../src/interfaces/DACEventsLib.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {ProposalParams} from "../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig, ProposalPhase} from "../src/interfaces/GovernanceStructs.sol";
import {BasicGovernanceOracle} from "../src/kernel/governance/BasicGovernanceOracle.sol";
import {WrappedMainToken} from "../src/kernel/tokens/WrappedMainToken.sol";
import {HybridDACManagementProposal} from "../src/kernel/governance/HybridDACManagementProposal.sol";
import {UUPSProxy} from "../src/kernel/proxies/UUPSProxy.sol";
import {TestUUPSProxy} from "./base/TestUUPSProxy.sol";

contract MockHybridUnderlyingToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HybridDACManagementProposalTest is Test {
    uint256 internal constant WARMUP_BLOCKS = 10;

    MockHybridUnderlyingToken internal underlying;
    WrappedMainToken internal wrapped;
    BasicGovernanceOracle internal oracle;
    HybridDACManagementProposal internal proposal;

    address internal publisher = makeAddr("publisher");
    address internal wrappedHolder = makeAddr("wrapped-holder");
    address internal underlyingHolder = makeAddr("underlying-holder");
    address internal fallbackHolder = makeAddr("fallback-holder");
    address internal mockAssetController = makeAddr("assetController");

    function setUp() external {
        underlying = new MockHybridUnderlyingToken();
        wrapped = WrappedMainToken(
            address(
                new UUPSProxy(
                    address(new WrappedMainToken()),
                    abi.encodeWithSelector(
                        WrappedMainToken.initialize.selector,
                        address(underlying),
                        "Wrapped DAC",
                        "wDAC",
                        address(this)
                    )
                )
            )
        );
        oracle = BasicGovernanceOracle(
            address(
                new UUPSProxy(
                    address(new BasicGovernanceOracle()),
                    abi.encodeWithSelector(BasicGovernanceOracle.initialize.selector, address(this), publisher)
                )
            )
        );
        proposal = HybridDACManagementProposal(
            address(new TestUUPSProxy(address(new HybridDACManagementProposal()), bytes("")))
        );

        // Mock asset controller: no controlled balances (returns 0 for any block)
        vm.mockCall(mockAssetController, abi.encodeWithSelector(bytes4(keccak256("getPastControlledBalance(uint256)"))), abi.encode(uint256(0)));

        underlying.mint(wrappedHolder, 1_000e18);
        underlying.mint(fallbackHolder, 1_000e18);

        vm.prank(wrappedHolder);
        underlying.approve(address(wrapped), type(uint256).max);

        vm.prank(fallbackHolder);
        underlying.approve(address(wrapped), type(uint256).max);
    }

    function test_primaryVoting_combinesWrappedAndMerkleVotes() external {
        vm.roll(10);

        vm.prank(wrappedHolder);
        wrapped.wrap(100e18);

        vm.roll(11);

        _init(1, bytes4(keccak256("TEST")), _strategyConfig(), false, false);

        assertEq(proposal.primarySnapshotBlock(), 10);
        assertEq(proposal.fallbackSnapshotBlock(), 0);
        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.AwaitingOracleSnapshot));

        bytes32 root = keccak256(abi.encodePacked(uint256(0), underlyingHolder, uint256(200e18)));

        vm.prank(publisher);
        oracle.publishSnapshot(address(this), 1, 10, root, 200e18);

        proposal.activatePrimaryVoting();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.PrimaryVoting));
        assertEq(proposal.totalVotingPower(), 300e18);

        vm.prank(wrappedHolder);
        proposal.voteWrapped(true);

        assertEq(proposal.yesVotes(), 100e18);

        vm.prank(underlyingHolder);
        proposal.voteMerkle(true, 0, 200e18, new bytes32[](0));

        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.Resolved));
        assertEq(proposal.yesVotes(), 300e18);
    }

    function test_oracleMiss_transitionsThroughFallbackWarmupAndVoting() external {
        vm.roll(20);

        _init(2, bytes4(keccak256("TEST_FALLBACK")), _strategyConfig(), false, false);

        vm.warp(block.timestamp + 2 days + 1);
        proposal.beginFallbackWarmup();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackWarmup));
        // Snapshot fixed the moment fallback is triggered: last block of warmup.
        assertEq(proposal.fallbackSnapshotBlock(), 20 + WARMUP_BLOCKS);
        assertEq(proposal.phaseEndTime(), 0);

        // Holders can wrap in response to the proposal during warmup.
        vm.roll(25);
        vm.prank(fallbackHolder);
        wrapped.wrap(80e18);

        // Not activatable until the snapshot block has passed.
        vm.roll(20 + WARMUP_BLOCKS);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        proposal.activateFallbackVoting();

        vm.roll(21 + WARMUP_BLOCKS);
        proposal.activateFallbackVoting();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackVoting));
        assertEq(proposal.totalVotingPower(), 80e18);

        vm.prank(fallbackHolder);
        proposal.vote(true);

        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
        assertEq(proposal.yesVotes(), 80e18);
    }

    function test_wrappedOnlyBootstrap_startsInWarmupThenVotesWithWrappedToken() external {
        vm.roll(24);

        _init(21, bytes4(keccak256("TEST_WRAPPED_BOOTSTRAP")), _wrappedOnlyStrategyConfig(), true, true);

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackWarmup));
        assertEq(proposal.fallbackSnapshotBlock(), 24 + WARMUP_BLOCKS);

        vm.roll(30);
        vm.prank(fallbackHolder);
        wrapped.wrap(90e18);

        vm.roll(25 + WARMUP_BLOCKS);
        proposal.activateFallbackVoting();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackVoting));
        assertEq(proposal.blockingEnabled(), true);
        assertEq(proposal.totalVotingPower(), 90e18);

        vm.prank(fallbackHolder);
        proposal.vote(true);

        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
    }

    /// H-1 regression: the snapshot block is fixed when warmup begins, so an actor
    /// cannot wrap right before activating and have that weight count. Whoever
    /// activates, and whenever, the snapshot stays at the warmup's last block.
    function test_fallbackSnapshot_fixedAtWarmupStart_wrapAfterSnapshotDoesNotCount() external {
        vm.roll(40);
        vm.prank(wrappedHolder);
        wrapped.wrap(100e18);

        vm.roll(41);
        _init(41, bytes4(keccak256("TEST_LATE_WRAP")), _wrappedOnlyStrategyConfig(), false, false);
        uint256 snapshot = 41 + WARMUP_BLOCKS;
        assertEq(proposal.fallbackSnapshotBlock(), snapshot);

        // Attacker waits for the snapshot block to pass, then wraps 9x the circulating
        // supply and activates in the very next block.
        vm.roll(snapshot + 1);
        vm.prank(fallbackHolder);
        wrapped.wrap(900e18);

        vm.roll(snapshot + 2);
        vm.prank(fallbackHolder);
        proposal.activateFallbackVoting();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackVoting));
        assertEq(proposal.fallbackSnapshotBlock(), snapshot);
        assertEq(proposal.totalVotingPower(), 100e18);

        vm.prank(fallbackHolder);
        vm.expectRevert(DACErrorsLib.NoVotingPower.selector);
        proposal.vote(true);
        assertFalse(proposal.isResolved());

        vm.prank(wrappedHolder);
        proposal.vote(true);
        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
        assertEq(proposal.yesVotes(), 100e18);
    }

    /// Opportunistic activation through vote() uses the same fixed snapshot.
    function test_fallbackVote_opportunisticActivationUsesFixedSnapshot() external {
        vm.roll(60);
        _init(60, bytes4(keccak256("TEST_OPPORTUNISTIC")), _wrappedOnlyStrategyConfig(), false, false);
        uint256 snapshot = 60 + WARMUP_BLOCKS;

        vm.roll(65);
        vm.prank(fallbackHolder);
        wrapped.wrap(50e18);

        // Before the snapshot block, vote() cannot activate.
        vm.roll(snapshot);
        vm.prank(fallbackHolder);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        proposal.vote(true);

        vm.roll(snapshot + 3);
        vm.prank(fallbackHolder);
        proposal.vote(true);

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.Resolved));
        assertEq(proposal.totalVotingPower(), 50e18);
        assertEq(proposal.yesVotes(), 50e18);
    }

    /// With no votable supply at the snapshot nobody can vote, so the proposal resolves
    /// as rejected instead of passing vacuously (0 >= quorum 0) or staying dormant
    /// forever (which would freeze anything gated on its resolution, e.g. a veto hold).
    function test_fallbackActivation_withoutVotableSupplyResolvesRejected() external {
        vm.roll(50);
        _init(50, bytes4(keccak256("TEST_ZERO_SUPPLY")), _wrappedOnlyStrategyConfig(), false, false);
        uint256 snapshot = 50 + WARMUP_BLOCKS;

        vm.roll(snapshot + 1);
        vm.prank(fallbackHolder);
        wrapped.wrap(90e18); // too late: after the snapshot block

        // Any state read finalizes the rejection lazily.
        assertTrue(proposal.isResolved());
        assertFalse(proposal.outcome());
        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.Resolved));
        assertFalse(proposal.isExecutableNow());

        vm.prank(fallbackHolder);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        proposal.vote(true);
    }

    /// Dust-level supply must not pass with zero votes: quorum rounds up.
    function test_fallbackQuorum_roundsUpForDustSupply() external {
        vm.roll(70);
        vm.prank(fallbackHolder);
        wrapped.wrap(3); // 3 wei votable

        vm.roll(71);
        _init(71, bytes4(keccak256("TEST_DUST")), _wrappedOnlyStrategyConfig(), false, false);

        vm.roll(71 + WARMUP_BLOCKS + 1);
        proposal.activateFallbackVoting();

        assertEq(proposal.totalVotingPower(), 3);
        assertEq(proposal.quorum(), 2); // ceil(3 * 50%)
        assertFalse(proposal.isResolved());

        vm.prank(fallbackHolder);
        proposal.vote(true);
        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
    }

    /// outcome() has no answer before a voting phase exists.
    function test_outcome_revertsBeforeActivation() external {
        vm.roll(80);
        vm.prank(fallbackHolder);
        wrapped.wrap(10e18);

        vm.roll(81);
        _init(81, bytes4(keccak256("TEST_PRE_OUTCOME")), _wrappedOnlyStrategyConfig(), false, false);

        vm.expectRevert(DACErrorsLib.NotResolved.selector);
        proposal.outcome();
    }

    /// An expired-by-time primary vote is finalized, not wiped, by an emergency fallback.
    function test_emergencyFallback_finalizesExpiredPrimaryVote() external {
        vm.roll(90);
        vm.prank(wrappedHolder);
        wrapped.wrap(100e18);

        vm.roll(91);
        _init(91, bytes4(keccak256("TEST_EXPIRED_PRIMARY")), _strategyConfig(), false, false);

        vm.prank(publisher);
        oracle.publishSnapshot(address(this), 91, 90, keccak256(abi.encodePacked(uint256(0), underlyingHolder, uint256(50e18))), 50e18);
        proposal.activatePrimaryVoting();

        vm.prank(wrappedHolder);
        proposal.voteWrapped(true); // 100 of 150: above 50% quorum, not an early resolution

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(publisher);
        oracle.deactivate(address(this));

        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        proposal.triggerEmergencyFallback();

        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
        assertEq(proposal.yesVotes(), 100e18);
    }

    function test_blockingFlags_enableHighQuorumBlocking() external {
        vm.roll(10);

        vm.prank(wrappedHolder);
        wrapped.wrap(100e18);

        vm.roll(11);

        _init(5, bytes4(keccak256("TEST_BLOCKING_ON")), _strategyConfigWithFlags(false, true, true), true, true);

        assertEq(proposal.highQuorum(), true);
        assertEq(proposal.blockingEnabled(), true);
    }

    function test_blockingFlags_canDisableHighQuorumBlocking() external {
        vm.roll(10);

        vm.prank(wrappedHolder);
        wrapped.wrap(100e18);

        vm.roll(11);

        _init(6, bytes4(keccak256("TEST_BLOCKING_OFF")), _strategyConfigWithFlags(false, false, true), true, false);

        assertEq(proposal.highQuorum(), true);
        assertEq(proposal.blockingEnabled(), false);
    }

    function test_oraclePublisherAccessControl() external {
        vm.expectRevert();
        oracle.publishSnapshot(address(this), 999, 1, keccak256("root"), 1);

        vm.prank(publisher);
        oracle.publishSnapshot(address(this), 999, 1, keccak256("root"), 1);
    }

    function test_oraclePublisherUpdate_emitsEvent() external {
        address nextPublisher = makeAddr("next-publisher");

        vm.expectEmit(true, true, false, true, address(oracle));
        emit DACEventsLib.GovernanceOraclePublisherUpdated(address(oracle), nextPublisher, true);
        oracle.setPublisher(nextPublisher, true);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit DACEventsLib.GovernanceOraclePublisherUpdated(address(oracle), nextPublisher, false);
        oracle.setPublisher(nextPublisher, false);
    }

    function test_oracleDeactivation_resetsPrimaryFlowIntoFallbackWarmup() external {
        vm.roll(30);

        vm.prank(wrappedHolder);
        wrapped.wrap(100e18);

        vm.roll(31);

        _init(3, bytes4(keccak256("TEST_EMERGENCY")), _strategyConfig(), false, false);

        vm.prank(publisher);
        oracle.publishSnapshot(address(this), 3, 30, keccak256(abi.encodePacked(uint256(0), underlyingHolder, uint256(200e18))), 200e18);

        proposal.activatePrimaryVoting();

        vm.prank(wrappedHolder);
        proposal.voteWrapped(true);
        assertEq(proposal.yesVotes(), 100e18);

        vm.prank(publisher);
        oracle.deactivate(address(this));

        vm.roll(33);
        proposal.triggerEmergencyFallback();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackWarmup));
        assertEq(proposal.yesVotes(), 0);
        assertEq(proposal.noVotes(), 0);
        assertEq(proposal.totalVotingPower(), 0);
        // Fresh snapshot fixed at the emergency transition, not at creation or activation.
        assertEq(proposal.fallbackSnapshotBlock(), 33 + WARMUP_BLOCKS);

        // Wrapping during warmup counts; wrapping after the snapshot does not.
        vm.roll(36);
        vm.prank(fallbackHolder);
        wrapped.wrap(500e18);

        vm.roll(33 + WARMUP_BLOCKS + 1);
        vm.prank(fallbackHolder);
        wrapped.wrap(400e18);

        proposal.activateFallbackVoting();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackVoting));
        assertEq(proposal.totalVotingPower(), 600e18);

        vm.prank(wrappedHolder);
        proposal.voteWrapped(true);
        assertFalse(proposal.isResolved());

        vm.prank(fallbackHolder);
        proposal.voteWrapped(true);
        assertEq(proposal.yesVotes(), 600e18);
        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
    }

    function _init(
        uint256 id,
        bytes4 typ,
        GovernanceStrategyConfig memory config,
        bool highQuorum,
        bool blockingEnabled
    ) internal {
        proposal.initialize(
            id,
            address(this),
            address(this),
            address(wrapped),
            address(oracle),
            mockAssetController,
            ProposalParams({typ: typ, target: address(0), i: bytes32(0), data: bytes("")}),
            config,
            highQuorum,
            blockingEnabled
        );
    }

    function _strategyConfig() internal pure returns (GovernanceStrategyConfig memory config) {
        config = _strategyConfigWithFlags(false, true, true);
    }

    function _wrappedOnlyStrategyConfig() internal pure returns (GovernanceStrategyConfig memory config) {
        config = _strategyConfigWithFlags(false, true, false);
    }

    function _strategyConfigWithFlags(
        bool blockingOnAllProposals,
        bool blockingOnHighQuorum,
        bool oraclePrimaryEnabled
    ) internal pure returns (GovernanceStrategyConfig memory config) {
        config = GovernanceStrategyConfig({
            quorumPercent: 5e17,
            highQuorumPercent: 8e17,
            blockingPercent: 2e17,
            duration: 7 days,
            qualification: 0,
            executionValidityDuration: 1 days,
            oraclePublishDeadline: oraclePrimaryEnabled ? 2 days : 0,
            fallbackWarmupBlocks: WARMUP_BLOCKS,
            fallbackDuration: 3 days,
            blockingOnAllProposals: blockingOnAllProposals,
            blockingOnHighQuorum: blockingOnHighQuorum,
            oraclePrimaryEnabled: oraclePrimaryEnabled
        });
    }
}
