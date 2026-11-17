// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Existing-token (hybrid) governance.
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.
//   test_NOTE_*    intended behaviour that audit.md documents as an operating note.
//   test_CONTROL_* the baseline a scenario is measured against.

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {ExistingDACConfig, ProposalParams, CapitalCall} from "../../../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig, ProposalPhase, OracleSnapshot} from "../../../src/interfaces/GovernanceStructs.sol";
import {IGovernanceSchema} from "../../../src/interfaces/IGovernanceSchema.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";
import {DACCell} from "../../../src/kernel/DACCell.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {WrappedMainToken} from "../../../src/kernel/tokens/WrappedMainToken.sol";
import {BasicGovernanceOracle} from "../../../src/kernel/governance/BasicGovernanceOracle.sol";
import {HybridDACManagementProposal} from "../../../src/kernel/governance/HybridDACManagementProposal.sol";
import {HybridGovernanceSchema} from "../../../src/kernel/governance/HybridGovernanceSchema.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {ExistingTokenAssetController} from "../../../src/kernel/controllers/ExistingTokenAssetController.sol";

contract HybridUnderlying is ERC20 {
    constructor() ERC20("Existing Token", "EXT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Existing-token (hybrid) DACs, driven end to end through DACFactory.deployExistingTokenDAC
/// with the default seed configuration (quorum 50%, high quorum 75%, blocking 20% on
/// high-quorum proposals, qualification 0, oracle deadline 1 day, warmup 4 hours,
/// fallback 3 days) and a chosen vote-retention setting.
contract HybridGovernanceHardening is DACTestBase {
    HybridUnderlying internal underlying;
    DACCell internal hdac;
    WrappedMainToken internal wrapped;
    ExistingTokenAssetController internal hController;
    BasicGovernanceOracle internal oracle;

    address internal seeder = makeAddr("existing-dac-deployer");
    address internal oracleAdmin = makeAddr("oracle-admin");
    address internal publisher = makeAddr("oracle-publisher");
    address internal honestWrapped = makeAddr("honest-wrapped-holder");
    address internal honestUnderlying = makeAddr("honest-underlying-holder");
    address internal lender = makeAddr("lending-market");
    address internal whale = makeAddr("borrowing-voter");
    address internal friend = makeAddr("delegator");

    uint256 internal constant SEED = 100_000e18;

    function setUp() public {
        setUpBase();
        vm.warp(1_800_000_000);
    }

    function _strategy(bool oraclePrimary, uint256 retention, uint256 lock)
        internal
        pure
        returns (GovernanceStrategyConfig memory)
    {
        return GovernanceStrategyConfig({
            quorumPercent: 5e17,
            highQuorumPercent: 75e16,
            blockingPercent: 2e17,
            duration: 7 days,
            qualification: 0,
            executionValidityDuration: 1 days,
            oraclePublishDeadline: 1 days,
            fallbackWarmupDuration: 4 hours,
            fallbackDuration: 3 days,
            blockingOnAllProposals: false,
            blockingOnHighQuorum: true,
            oraclePrimaryEnabled: oraclePrimary,
            voteRetentionPercent: retention,
            voteLockDuration: lock
        });
    }

    function _deployHybrid(bool oraclePrimary, uint256 retention, uint256 lock) internal {
        underlying = new HybridUnderlying();
        underlying.mint(seeder, SEED);
        underlying.mint(honestUnderlying, 800_000e18); // unwrapped majority: votes by Merkle in primary mode
        underlying.mint(lender, 5_000_000e18); // borrowable float
        underlying.mint(whale, 1e18); // a small position bought on the market

        address oracleAddr = address(0);
        if (oraclePrimary) {
            oracleAddr = dacFactory.deployGovernanceOracle(oracleAdmin, publisher);
            oracle = BasicGovernanceOracle(oracleAddr);
        }

        ExistingDACConfig memory cfg = ExistingDACConfig({
            symbol: "EDAC",
            name: "Existing DAC",
            description: "hybrid governance",
            underlyingToken: address(underlying),
            treasurySeedAmount: SEED,
            governanceOracle: oracleAddr,
            dividendsEnabled: false,
            governanceStrategy: _strategy(oraclePrimary, retention, lock)
        });

        vm.startPrank(seeder);
        underlying.approve(address(dacFactory), SEED);
        (address d, address w,) = dacFactory.deployExistingTokenDAC(abi.encode(cfg), keccak256("hybrid"));
        vm.stopPrank();

        hdac = DACCell(d);
        wrapped = WrappedMainToken(w);
        hController = ExistingTokenAssetController(hdac.getAssetController());

        assertEq(hController.treasuryBalance(address(wrapped)), SEED);
    }

    function _wrap(address who, uint256 amount) internal {
        vm.startPrank(who);
        underlying.approve(address(wrapped), amount);
        wrapped.wrap(amount);
        vm.stopPrank();
    }

    function _borrowAndWrap(address who, uint256 amount) internal {
        vm.prank(lender);
        underlying.transfer(who, amount);
        _wrap(who, amount);
    }

    // CAPITAL_CALL in existing-token mode sells treasury-held wrapped tokens to the
    // recipient for `cashAmount`. With cashAmount == 0 it is a plain transfer out: the
    // most sensitive thing a hybrid proposal can do, so the tests use it as the subject.
    function _treasuryOutProposal(address proposer, uint256 amount) internal returns (uint256 id) {
        vm.prank(proposer);
        id = hdac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.CAPITAL_CALL,
                target: proposer,
                i: bytes32(amount),
                data: abi.encode(address(underlying), uint256(0), block.timestamp + 30 days)
            })
        );
    }

    function _takeFromTreasury(uint256 id, address recipient, uint256 amount) internal {
        hdac.executeDACProposal(id);
        hdac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(underlying),
                nonce: id,
                tokenRecipient: recipient,
                tokenAmount: amount,
                cashAmount: 0
            })
        );
    }

    // ------------------------------------------------------------------
    // H-01. A snapshot the oracle published in time counts, whether or not anyone
    //    called activatePrimaryVoting() before the deadline.
    // ------------------------------------------------------------------
    function test_REG_H01_timelySnapshotIsHonouredWithoutAnyActivationCall() public {
        _deployHybrid(true, 0, 0);

        // 800k underlying held unwrapped (the Merkle electorate), 10k wrapped.
        underlying.mint(honestWrapped, 10_000e18);
        _wrap(honestWrapped, 10_000e18);
        _wrap(whale, 1e18); // enough to create proposals at qualification 0

        vm.warp(block.timestamp + 2);
        uint256 t0 = block.timestamp;
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        // The publisher does its job one hour later. Nobody touches the proposal.
        vm.warp(t0 + 1 hours);
        bytes32 root = keccak256(abi.encodePacked(uint256(0), honestUnderlying, uint256(800_000e18)));
        uint256 snapT = p.primarySnapshotTime();
        vm.prank(publisher);
        oracle.publishSnapshot(address(hdac), id, snapT, root, 800_000e18);

        // After the deadline the proposal cannot be pushed into the wrapped-only fallback...
        vm.warp(t0 + 1 days + 1);
        assertEq(uint8(p.phase()), uint8(ProposalPhase.AwaitingOracleSnapshot));
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        p.beginFallbackWarmup();

        // ...and a large wrap now changes nothing: the first interaction enters primary
        // voting on the published snapshot, on the schedule the publication fixed.
        _borrowAndWrap(whale, 45_000e18);
        vm.warp(block.timestamp + 2);
        vm.prank(whale);
        p.vote(true);

        assertEq(uint8(p.phase()), uint8(ProposalPhase.PrimaryVoting));
        assertEq(p.totalVotingPower(), 800_000e18 + 10_000e18 + 1e18);
        assertEq(p.yesVotes(), 1e18, "weight is what was wrapped at the primary snapshot");
        assertEq(p.phaseStartTime(), t0 + 1 hours, "primary voting starts at publication");
        assertEq(p.phaseEndTime(), t0 + 1 hours + 7 days);

        // The underlying electorate votes by Merkle proof and decides.
        vm.prank(honestUnderlying);
        p.voteMerkle(false, 0, 800_000e18, new bytes32[](0));
        assertTrue(p.isResolved());
        assertFalse(p.outcome());
        assertEq(hController.treasuryBalance(address(wrapped)), SEED);
    }

    // The snapshot stays binding when the oracle is switched off afterwards. Leaving primary
    // then takes the explicit emergency fallback, which starts a fresh and public warmup:
    // a proposal is never moved onto a fallback snapshot that already lies in the past.
    function test_REG_H01_timelySnapshotSurvivesOracleDeactivation_untilEmergencyFallback() public {
        _deployHybrid(true, 0, 0);
        underlying.mint(honestWrapped, 10_000e18);
        _wrap(honestWrapped, 10_000e18);
        _wrap(whale, 1e18);

        vm.warp(block.timestamp + 2);
        uint256 t0 = block.timestamp;
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        vm.warp(t0 + 1 hours);
        bytes32 root = keccak256(abi.encodePacked(uint256(0), honestUnderlying, uint256(800_000e18)));
        uint256 snapT = p.primarySnapshotTime();
        vm.prank(publisher);
        oracle.publishSnapshot(address(hdac), id, snapT, root, 800_000e18);

        // Two days in, past the deadline and past what a fallback snapshot counted from it
        // would have been, the oracle is switched off for this DAC.
        vm.warp(t0 + 2 days);
        vm.prank(publisher);
        oracle.deactivate(address(hdac));

        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        p.beginFallbackWarmup();

        // Untouched until now, the proposal is in primary voting on the published snapshot.
        vm.prank(whale);
        p.vote(true);
        assertEq(uint8(p.phase()), uint8(ProposalPhase.PrimaryVoting));
        assertEq(p.totalVotingPower(), 800_000e18 + 10_000e18 + 1e18);

        // Anyone can take it out of primary now that the oracle is off: votes are wiped and
        // the fallback snapshot lies a full warmup ahead.
        p.triggerEmergencyFallback();
        assertEq(uint8(p.phase()), uint8(ProposalPhase.FallbackWarmup));
        assertEq(p.yesVotes(), 0);
        assertEq(p.fallbackSnapshotTime(), block.timestamp + 4 hours);
    }

    // An oracle that stops answering (reverts, burns its gas, returns garbage) reads as an
    // oracle without a snapshot. The proposal takes the fallback path at its deadline;
    // nothing that waits on it is frozen.
    function test_REG_H01_brokenOracleCannotFreezeAProposal() public {
        _deployHybrid(true, 0, 0);
        underlying.mint(honestWrapped, 10_000e18);
        _wrap(honestWrapped, 10_000e18);

        vm.warp(block.timestamp + 2);
        uint256 t0 = block.timestamp;
        uint256 id = _treasuryOutProposal(honestWrapped, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        // The oracle's code is replaced by a single INVALID opcode: every call to it fails
        // and consumes all the gas it was given.
        vm.etch(address(oracle), hex"fe");

        // Before the deadline the proposal waits: reading it does not revert.
        vm.warp(t0 + 1 hours);
        assertFalse(p.isResolved());
        assertEq(uint8(p.phase()), uint8(ProposalPhase.AwaitingOracleSnapshot));

        // After it, any interaction applies the scheduled fallback.
        vm.warp(t0 + 1 days + 4 hours + 2);
        vm.prank(honestWrapped);
        p.vote(true);
        assertEq(p.fallbackSnapshotTime(), t0 + 1 days + 4 hours);
        assertEq(p.totalVotingPower(), 10_000e18);
        assertTrue(p.isResolved());
        assertTrue(p.outcome());
    }

    // Control: an explicit activation gives the same electorate and the same schedule.
    function test_CONTROL_H01_explicitActivationGivesTheSameSchedule() public {
        _deployHybrid(true, 0, 0);
        underlying.mint(honestWrapped, 10_000e18);
        _wrap(honestWrapped, 10_000e18);
        _wrap(whale, 1e18);

        vm.warp(block.timestamp + 2);
        uint256 t0 = block.timestamp;
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        vm.warp(t0 + 1 hours);
        bytes32 root = keccak256(abi.encodePacked(uint256(0), honestUnderlying, uint256(800_000e18)));
        uint256 snapT = p.primarySnapshotTime();
        vm.prank(publisher);
        oracle.publishSnapshot(address(hdac), id, snapT, root, 800_000e18);

        vm.warp(t0 + 5 hours);
        p.activatePrimaryVoting();
        assertEq(p.totalVotingPower(), 800_000e18 + 10_000e18 + 1e18);
        assertEq(p.phaseStartTime(), t0 + 1 hours);
        assertEq(p.phaseEndTime(), t0 + 1 hours + 7 days);

        vm.prank(whale);
        p.vote(true);
        vm.warp(t0 + 1 hours + 7 days + 1);
        assertTrue(p.isResolved());
        assertFalse(p.outcome());
    }

    // ------------------------------------------------------------------
    // M-02 (hybrid). Phases follow the configured durations: a proposal nobody touches
    //    does not keep its vote for later.
    // ------------------------------------------------------------------
    function test_REG_M02_untouchedFallbackProposal_expiresOnSchedule() public {
        _deployHybrid(false, 0, 0);
        _wrap(whale, 1e18);

        vm.warp(block.timestamp + 2);
        uint256 t0 = block.timestamp;
        uint256 id = _treasuryOutProposal(whale, 5 * SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));
        uint256 snapshotSecond = p.fallbackSnapshotTime();
        assertEq(snapshotSecond, t0 + 4 hours);

        // At the snapshot the proposer is the whole wrapped electorate, and then leaves.
        vm.warp(snapshotSecond + 2);
        vm.prank(whale);
        wrapped.unwrap(1e18);

        // A year passes. The community wraps, the treasury grows.
        vm.warp(t0 + 365 days);
        underlying.mint(honestWrapped, 2_000_000e18);
        _wrap(honestWrapped, 2_000_000e18);
        vm.prank(honestWrapped);
        wrapped.transfer(address(hdac), 4 * SEED);
        hdac.recoverERC20(address(wrapped));
        assertEq(hController.treasuryBalance(address(wrapped)), 5 * SEED);

        // The old proposal's voting ended three days after its snapshot.
        vm.prank(whale);
        vm.expectRevert(DACErrorsLib.VotingEnded.selector);
        p.vote(true);

        assertTrue(p.isResolved());
        assertFalse(p.outcome());
        assertEq(p.resolutionTime(), snapshotSecond + 3 days, "stamped with the end of fallback voting");
        assertEq(hController.treasuryBalance(address(wrapped)), 5 * SEED);
    }

    // ------------------------------------------------------------------
    // C-01. Vote retention: the DAC sets what share of a wrapped vote's weight must still
    //    be delegated to the voter when it votes, and for how long that share then stays
    //    locked. Voting capital is exposed to the outcome instead of leaving next block.
    // ------------------------------------------------------------------

    // Wrap for the snapshot second, leave, vote later: the vote is refused.
    function test_REG_C01_retention_voteNeedsTheCapitalStillWrapped() public {
        _deployHybrid(false, MathLib.SCALE, 30 days);

        underlying.mint(honestWrapped, 100_000e18);
        _wrap(honestWrapped, 100_000e18);
        _wrap(whale, 1e18);

        vm.warp(block.timestamp + 2);
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));
        uint256 snapshotSecond = p.fallbackSnapshotTime();

        vm.warp(snapshotSecond);
        _borrowAndWrap(whale, 400_000e18);

        vm.warp(snapshotSecond + 2);
        vm.startPrank(whale);
        wrapped.unwrap(400_000e18);
        underlying.transfer(lender, 400_000e18); // loan repaid before voting

        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        p.vote(true);
        vm.stopPrank();

        assertEq(p.yesVotes(), 0);

        // The electorate still carries the 400k that left, so the holders who stayed cannot
        // reach the blocking threshold on their own; they do not need to. Without the
        // departed votes the proposal never reaches quorum and fails when voting ends.
        vm.prank(honestWrapped);
        p.vote(false);
        assertFalse(p.isResolved());

        vm.warp(p.phaseEndTime() + 1);
        assertTrue(p.isResolved());
        assertFalse(p.outcome());
        assertEq(hController.treasuryBalance(address(wrapped)), SEED);
    }

    // Stay wrapped and vote: the vote counts, and the capital behind it stays locked.
    function test_REG_C01_voteLock_capitalBehindAVoteCannotLeave() public {
        _deployHybrid(false, MathLib.SCALE, 30 days);

        underlying.mint(honestWrapped, 100_000e18);
        _wrap(honestWrapped, 100_000e18);
        _wrap(whale, 1e18);

        vm.warp(block.timestamp + 2);
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));
        uint256 snapshotSecond = p.fallbackSnapshotTime();

        vm.warp(snapshotSecond);
        _borrowAndWrap(whale, 400_000e18);

        vm.warp(snapshotSecond + 2);
        uint256 votedAt = block.timestamp;
        vm.prank(whale);
        p.vote(true);
        assertTrue(p.isResolved());
        assertTrue(p.outcome(), "80% of the wrapped electorate, held through the vote, decides");

        (uint256 locked, uint256 until) = wrapped.lockedVotes(whale);
        assertEq(locked, 400_001e18);
        assertEq(until, votedAt + 30 days);

        // Whatever the proposal does, the 400k behind the vote stay where they are: no
        // unwrap, no transfer, no moving the votes to another delegate.
        vm.startPrank(whale);
        _takeFromTreasury(id, whale, SEED);

        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.unwrap(400_000e18);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.transfer(lender, 400_000e18);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.delegate(friend);

        // What it holds above the locked amount is free.
        wrapped.unwrap(SEED);

        // One second short of the lock period: still locked.
        vm.warp(until);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.unwrap(1);

        // After it the loan can finally be repaid, thirty days of exposure later.
        vm.warp(until + 1);
        wrapped.unwrap(400_000e18);
        underlying.transfer(lender, 400_000e18);
        vm.stopPrank();

        (locked,) = wrapped.lockedVotes(whale);
        assertEq(locked, 0);
    }

    // A partial share: that part of the weight is what must be there and what gets locked.
    function test_REG_C01_partialRetention_locksThatShareOfTheWeight() public {
        _deployHybrid(false, MathLib.atScale(25), 7 days);

        _wrap(whale, 1e18);
        _borrowAndWrap(whale, 399_999e18); // 400k wrapped in total

        vm.warp(block.timestamp + 2);
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        vm.warp(p.fallbackSnapshotTime() + 2);

        // Three quarters leave before the vote: the remaining quarter is exactly enough.
        vm.startPrank(whale);
        wrapped.unwrap(300_000e18);
        p.vote(true);
        assertEq(p.yesVotes(), 400_000e18);

        (uint256 locked,) = wrapped.lockedVotes(whale);
        assertEq(locked, 100_000e18);

        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.unwrap(1);
        vm.stopPrank();
    }

    // Votes lent to a delegate are locked with the delegate's vote.
    function test_REG_C01_delegatorsShareTheirDelegatesLock() public {
        _deployHybrid(false, MathLib.SCALE, 30 days);

        _wrap(whale, 1e18);
        underlying.mint(friend, 50_000e18);
        _wrap(friend, 50_000e18);
        vm.prank(friend);
        wrapped.delegate(whale);

        vm.warp(block.timestamp + 2);
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        vm.warp(p.fallbackSnapshotTime() + 2);
        vm.prank(whale);
        p.vote(true);
        assertEq(p.yesVotes(), 50_001e18);

        // The delegator cannot pull the voting power it lent, by any route.
        vm.startPrank(friend);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.unwrap(1);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.transfer(lender, 1);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        wrapped.delegate(friend);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(friend);
        wrapped.unwrap(50_000e18);
    }

    // Nobody but the DAC's own proposals can lock votes.
    function test_REG_C01_onlyTheSchemasProposalsCanLock() public {
        _deployHybrid(false, MathLib.SCALE, 30 days);
        _wrap(whale, 1e18);
        address schema = hdac.getGovernanceSchema();

        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        wrapped.lockVotes(whale, 1e18, block.timestamp + 365 days);

        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        HybridGovernanceSchema(schema).lockVotes(whale, 1e18, block.timestamp + 365 days);
    }

    function test_REG_C01_retentionSettingsAreValidated() public {
        _deployHybrid(false, 0, 0);
        _wrap(whale, 1e18);
        vm.warp(block.timestamp + 2);

        GovernanceStrategyConfig memory s = _strategy(false, MathLib.SCALE + 1, 1 days);
        _expectInvalidStrategy(s);

        s = _strategy(false, MathLib.SCALE, 366 days);
        _expectInvalidStrategy(s);

        s = _strategy(false, 0, 1 days); // a lock with nothing to lock
        _expectInvalidStrategy(s);

        // A share with no lock is accepted: it only has to be there in the block of the vote.
        s = _strategy(false, MathLib.atScale(50), 0);
        vm.prank(whale);
        hdac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_GOVERNANCE_STRATEGY, target: address(0), i: 0, data: abi.encode(s)
            })
        );
    }

    function _expectInvalidStrategy(GovernanceStrategyConfig memory s) internal {
        vm.prank(whale);
        vm.expectRevert(DACErrorsLib.InvalidVotingConfig.selector);
        hdac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_GOVERNANCE_STRATEGY, target: address(0), i: 0, data: abi.encode(s)
            })
        );
    }

    // ------------------------------------------------------------------
    // C-01 (operating notes). What the settings do not do, and what holders do instead.
    // ------------------------------------------------------------------

    // With retention switched off (the permissive default) a fallback vote belongs to
    // whoever is wrapped in the snapshot second, for that second only.
    function test_NOTE_C01_noRetention_snapshotSecondBalanceDecidesAFallbackVote() public {
        _deployHybrid(false, 0, 0);

        underlying.mint(honestWrapped, 100_000e18);
        _wrap(honestWrapped, 100_000e18);
        _wrap(whale, 1e18);

        vm.warp(block.timestamp + 2);
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));
        uint256 snapshotSecond = p.fallbackSnapshotTime();
        assertEq(snapshotSecond, block.timestamp + 4 hours);

        vm.warp(snapshotSecond);
        _borrowAndWrap(whale, 400_000e18);

        vm.warp(snapshotSecond + 2);
        vm.startPrank(whale);
        wrapped.unwrap(400_000e18);
        underlying.transfer(lender, 400_000e18);
        p.vote(true);
        vm.stopPrank();

        assertEq(p.totalVotingPower(), 500_001e18);
        assertTrue(p.isResolved());
        assertTrue(p.outcome());
    }

    // An oracle-primary DAC whose holders never wrap has no fallback electorate of its
    // own: if the oracle misses, the vote belongs to whoever is wrapped.
    function test_NOTE_C01_oracleMiss_fallbackElectorateIsTheWrappedFloat() public {
        _deployHybrid(true, 0, 0);

        vm.startPrank(whale);
        underlying.approve(address(wrapped), 1);
        wrapped.wrap(1); // 1 wei
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        uint256 t0 = block.timestamp;
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        // The oracle publishes nothing. Nobody reacts during the warmup.
        vm.warp(t0 + 1 days + 4 hours + 2);
        vm.prank(whale);
        p.vote(true);
        assertEq(p.fallbackSnapshotTime(), t0 + 1 days + 4 hours, "warmup ran from the oracle deadline");
        assertEq(p.totalVotingPower(), 1);
        assertTrue(p.isResolved());
        assertTrue(p.outcome());
    }

    // The defence is the warmup: the fallback snapshot is public for its whole length,
    // and one holder wrapping before it is an electorate that can say no.
    function test_NOTE_C01_warmupIsTheDefenceWindow_oneHolderWrappingBlocks() public {
        _deployHybrid(true, 0, 0);

        vm.startPrank(whale);
        underlying.approve(address(wrapped), 1);
        wrapped.wrap(1);
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        uint256 t0 = block.timestamp;
        uint256 id = _treasuryOutProposal(whale, SEED);
        HybridDACManagementProposal p = HybridDACManagementProposal(hdac.getProposalVoting(id));

        // The oracle misses its deadline. A holder notices the pending proposal and wraps
        // inside the four-hour warmup.
        vm.warp(t0 + 1 days + 1 hours);
        underlying.mint(honestWrapped, 10_000e18);
        _wrap(honestWrapped, 10_000e18);

        vm.warp(t0 + 1 days + 4 hours + 2);
        vm.prank(whale);
        p.vote(true);
        assertFalse(p.isResolved());

        vm.prank(honestWrapped);
        p.vote(false);
        assertTrue(p.isResolved());
        assertFalse(p.outcome());
        assertEq(hController.treasuryBalance(address(wrapped)), SEED);
    }
}
