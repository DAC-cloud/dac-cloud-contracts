// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACEventsLib} from "../src/interfaces/DACEventsLib.sol";
import {ProposalParams} from "../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig, ProposalPhase} from "../src/interfaces/GovernanceStructs.sol";
import {GovernanceOracle} from "../src/kernel/governance/GovernanceOracle.sol";
import {WrappedMainToken} from "../src/kernel/tokens/WrappedMainToken.sol";
import {HybridDACManagementProposal} from "../src/kernel/governance/HybridDACManagementProposal.sol";
import {UUPSProxy} from "../src/kernel/proxies/UUPSProxy.sol";

contract MockHybridUnderlyingToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HybridDACManagementProposalTest is Test {
    MockHybridUnderlyingToken internal underlying;
    WrappedMainToken internal wrapped;
    GovernanceOracle internal oracle;
    HybridDACManagementProposal internal proposal;

    address internal publisher = makeAddr("publisher");
    address internal wrappedHolder = makeAddr("wrapped-holder");
    address internal underlyingHolder = makeAddr("underlying-holder");
    address internal fallbackHolder = makeAddr("fallback-holder");

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
        oracle = GovernanceOracle(
            address(
                new UUPSProxy(
                    address(new GovernanceOracle()),
                    abi.encodeWithSelector(GovernanceOracle.initialize.selector, address(this), publisher)
                )
            )
        );
        proposal = HybridDACManagementProposal(
            address(new UUPSProxy(address(new HybridDACManagementProposal()), bytes("")))
        );

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

        proposal.initialize(
            1,
            address(this),
            address(wrapped),
            address(oracle),
            ProposalParams({
                typ: bytes4(keccak256("TEST")),
                target: address(0),
                i: bytes32(0),
                data: bytes("")
            }),
            _strategyConfig(),
            false,
            false
        );

        assertEq(proposal.primarySnapshotBlock(), 10);
        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.AwaitingOracleSnapshot));

        bytes32 root = keccak256(abi.encodePacked(uint256(0), underlyingHolder, uint256(200e18)));

        vm.prank(publisher);
        oracle.publishSnapshot(1, 10, root, 200e18);

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

        proposal.initialize(
            2,
            address(this),
            address(wrapped),
            address(oracle),
            ProposalParams({
                typ: bytes4(keccak256("TEST_FALLBACK")),
                target: address(0),
                i: bytes32(0),
                data: bytes("")
            }),
            _strategyConfig(),
            false,
            false
        );

        vm.warp(block.timestamp + 2 days + 1);
        proposal.beginFallbackWarmup();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackWarmup));

        vm.roll(21);
        vm.prank(fallbackHolder);
        wrapped.wrap(80e18);

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(22);
        proposal.activateFallbackVoting();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackVoting));
        assertEq(proposal.fallbackSnapshotBlock(), 21);
        assertEq(proposal.totalVotingPower(), 80e18);

        vm.prank(fallbackHolder);
        proposal.vote(true);

        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
        assertEq(proposal.yesVotes(), 80e18);
    }

    function test_wrappedOnlyBootstrap_startsInWarmupThenVotesWithWrappedToken() external {
        vm.roll(24);

        proposal.initialize(
            21,
            address(this),
            address(wrapped),
            address(oracle),
            ProposalParams({
                typ: bytes4(keccak256("TEST_WRAPPED_BOOTSTRAP")),
                target: address(0),
                i: bytes32(0),
                data: bytes("")
            }),
            _wrappedOnlyStrategyConfig(),
            true,
            true
        );

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackWarmup));

        vm.prank(fallbackHolder);
        wrapped.wrap(90e18);

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(25);
        proposal.activateFallbackVoting();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackVoting));
        assertEq(proposal.blockingEnabled(), true);

        vm.prank(fallbackHolder);
        proposal.vote(true);

        assertTrue(proposal.isResolved());
        assertTrue(proposal.outcome());
    }

    function test_blockingFlags_enableHighQuorumBlocking() external {
        vm.roll(26);

        proposal.initialize(
            22,
            address(this),
            address(wrapped),
            address(oracle),
            ProposalParams({
                typ: bytes4(keccak256("TEST_BLOCKING_FLAGS")),
                target: address(0),
                i: bytes32(0),
                data: bytes("")
            }),
            _strategyConfig(),
            true,
            true
        );

        assertTrue(proposal.highQuorum());
        assertTrue(proposal.blockingEnabled());
    }

    function test_blockingFlags_canDisableHighQuorumBlocking() external {
        vm.roll(27);

        proposal.initialize(
            23,
            address(this),
            address(wrapped),
            address(oracle),
            ProposalParams({
                typ: bytes4(keccak256("TEST_BLOCKING_DISABLED")),
                target: address(0),
                i: bytes32(0),
                data: bytes("")
            }),
            _strategyConfigWithFlags(false, false, true),
            true,
            false
        );

        assertTrue(proposal.highQuorum());
        assertFalse(proposal.blockingEnabled());
    }

    function test_oraclePublisherAccessControl() external {
        vm.expectRevert();
        oracle.publishSnapshot(999, 1, keccak256("root"), 1);

        vm.prank(publisher);
        oracle.publishSnapshot(999, 1, keccak256("root"), 1);
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

        proposal.initialize(
            3,
            address(this),
            address(wrapped),
            address(oracle),
            ProposalParams({
                typ: bytes4(keccak256("TEST_EMERGENCY")),
                target: address(0),
                i: bytes32(0),
                data: bytes("")
            }),
            _strategyConfig(),
            false,
            false
        );

        vm.prank(publisher);
        oracle.publishSnapshot(3, 30, keccak256(abi.encodePacked(uint256(0), underlyingHolder, uint256(200e18))), 200e18);

        proposal.activatePrimaryVoting();

        vm.prank(wrappedHolder);
        proposal.voteWrapped(true);
        assertEq(proposal.yesVotes(), 100e18);

        vm.prank(publisher);
        oracle.deactivate();

        proposal.triggerEmergencyFallback();

        assertEq(uint8(proposal.phase()), uint8(ProposalPhase.FallbackWarmup));
        assertEq(proposal.yesVotes(), 0);
        assertEq(proposal.noVotes(), 0);
        assertEq(proposal.totalVotingPower(), 0);
    }

    function _strategyConfig() internal pure returns (GovernanceStrategyConfig memory config) {
        config = GovernanceStrategyConfig({
            quorumPercent: 5e17,
            highQuorumPercent: 8e17,
            blockingPercent: 2e17,
            duration: 7 days,
            qualification: 0,
            executionValidityDuration: 1 days,
            oraclePublishDeadline: 2 days,
            fallbackWarmupDuration: 1 days,
            fallbackDuration: 3 days,
            blockingOnAllProposals: false,
            blockingOnHighQuorum: true,
            oraclePrimaryEnabled: true
        });
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
            fallbackWarmupDuration: 1 days,
            fallbackDuration: 3 days,
            blockingOnAllProposals: blockingOnAllProposals,
            blockingOnHighQuorum: blockingOnHighQuorum,
            oraclePrimaryEnabled: oraclePrimaryEnabled
        });
    }
}
