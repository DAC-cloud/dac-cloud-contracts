// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NativeHandler, NativeBase} from "./NativeHandler.sol";
import {InvToken} from "./InvMocks.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {Deal} from "../../src/kernel/Deal.sol";
import {DealManager} from "../../src/kernel/DealManager.sol";
import {MainToken} from "../../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../../src/kernel/tokens/StakedAgent.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {IAssetController} from "../../src/interfaces/IAssetController.sol";
import {IExecutableProposal} from "../../src/interfaces/IExecutableProposal.sol";
import {IDealManagerAdapter} from "../../src/kernel/interfaces/IDealManagerAdapter.sol";
import {DealState} from "../../src/kernel/interfaces/Structs.sol";
import {CapitalCall} from "../../src/interfaces/Structs.sol";
import {Proposal} from "../../src/kernel/governance/Proposal.sol";
import {DACErrorsLib} from "../../src/interfaces/DACErrorsLib.sol";
import {TreasuryDeal} from "../../src/modules/core/deals/TreasuryDeal.sol";
import {DACDeal} from "../../src/modules/core/deals/DACDeal.sol";

/// Stateful invariant suite for a native DAC with treasury deals (mock, milestone and
/// revenue evaluators) and a DAC deal owning a child DAC. Written during the 2026-11 audit
/// (see audit.md, section 11).
///
/// Two entry points share the same properties:
///
///   NativeInvariants          smoke campaign, always on, sized by inline config
///                             (16 runs x 80 calls, about five seconds in a plain `forge test`)
///   NativeInvariantsCampaign  full campaign, skipped unless INV_CAMPAIGN=true, sized by the
///                             environment:
///
///     INV_CAMPAIGN=true FOUNDRY_INVARIANT_RUNS=200 FOUNDRY_INVARIANT_DEPTH=250 \
///       FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_FUZZ_SEED=0x01 \
///       forge test --match-contract NativeInvariantsCampaign
///
/// Environment switches:
///   INV_STATS=true         append per-run handler statistics to INV_STATS_FILE
///                          (default invariant-out/native-stats.csv). Needs an fs_permissions
///                          entry with write access to that path in foundry.toml.
///   INV_CHECK_F1=false     skip the check that a proposal's recorded electorate covers the votes
///                          existing at its snapshot (on by default: weights and base are read
///                          at one past timepoint).
///
/// The harness reads private storage by slot (NativeAssetController slots 5, 6, 7, 9, 10, 11
/// and DealCell slots 24, 28). Re-check them with `forge inspect <Contract> storage-layout`
/// whenever those layouts change.
abstract contract NativeInvariantChecks is Test {
    NativeHandler internal h;

    DACCell internal dac;
    MainToken internal mainToken;
    AgentToken internal agentToken;
    DealManager internal dealManager;
    address internal controller;
    address internal usdc;
    address internal tok2;
    address internal founder;
    bool internal checkF1;

    function _setUpSuite() internal {
        h = new NativeHandler();
        h.init();

        dac = h.dac();
        mainToken = h.mainToken();
        agentToken = h.agentToken();
        dealManager = h.dealManager();
        controller = h.controller();
        usdc = address(h.usdc());
        tok2 = address(h.tok2());
        founder = h.founder();
        checkF1 = vm.envOr("INV_CHECK_F1", true);

        bytes4[] memory a = h.handlerSelectors();
        bytes4[] memory b = h.handlerSelectorsB();
        bytes4[] memory all = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            all[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            all[a.length + i] = b[i];
        }
        targetSelector(FuzzSelector({addr: address(h), selectors: all}));
        targetContract(address(h));
    }

    // ------------------------------------------------------------------ //
    // helpers                                                              //
    // ------------------------------------------------------------------ //
    function _tokens3() internal view returns (address[3] memory t) {
        t = [usdc, tok2, address(mainToken)];
    }

    function _state(address cell) internal returns (DealState memory) {
        return IDealManagerAdapter(address(dealManager)).state(cell);
    }

    /// Every property, checked after every handler call.
    function _all() internal {
        _chk_Z1_noArithmeticPanics();
        _chk_Z2_livenessExpectations();
        _chk_Z3_soundnessExpectations();
        _chk_A1_treasuryBackedAndCommitmentsExact();
        _chk_A2_treasuryLedgerMatchesDeals();
        _chk_A3_cashConservation();
        _chk_A4_investedEqualsSettledTranches();
        _chk_A5_dividendClaimsCapped();
        _chk_B1_rewardBoundsAndClaimables();
        _chk_B2_obligationsExactAndMintable();
        _chk_B3_mainSupplyLedger();
        _chk_C1_stakeBackedAndAttributed();
        _chk_D1_votableSupply();
        _chk_E1_proposalsExecuteAtMostOnce();
        _chk_E2_closedAndApprovedAreFinal();
        _chk_G1_noBystanderLoss();
        _chk_G2_noResidueInTransitContracts();
        _chk_H1_childDacSane();
        _chk_V1_locksCoveredByVotes();
        if (checkF1) _chk_F1_tallyWithinElectorate();
    }

    /// A live vote lock is always covered: no sequence of transfers, burns or
    /// re-delegations leaves an account with fewer votes than it has locked.
    function _chk_V1_locksCoveredByVotes() internal view {
        uint256 n = h.actorCount();
        for (uint256 i = 0; i <= n; i++) {
            address a = i == n ? founder : h.actors(i);
            (uint256 locked,) = mainToken.lockedVotes(a);
            if (locked == 0) continue;
            assertGe(mainToken.getVotes(a), locked, "votes below the locked amount");
        }
    }

    /// A handler call never debits an account that did not take part in it.
    function _chk_G1_noBystanderLoss() internal view {
        (bool lost, address who, address token, uint256 beforeBal, uint256 afterBal) = h.bystanderLoss();
        if (lost) {
            revert(
                string(
                    abi.encodePacked(
                        "bystander debited in ",
                        _b32(h.currentHandler()),
                        ": ",
                        vm.toString(who),
                        " token ",
                        vm.toString(token),
                        " ",
                        vm.toString(beforeBal),
                        " -> ",
                        vm.toString(afterBal)
                    )
                )
            );
        }
    }

    /// DealManager and DealCells only forward balances: whatever sits there was
    /// pushed from outside the protocol flows.
    function _chk_G2_noResidueInTransitContracts() internal view {
        address[3] memory t = _tokens3();
        uint256 n = h.dealCount();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                IERC20(t[i]).balanceOf(address(dealManager)),
                h.donatedTo(address(dealManager), t[i]),
                "protocol flow left funds on the DealManager"
            );
            for (uint256 d = 0; d < n; d++) {
                address cell = h.dealInfo(d).cell;
                assertLe(
                    IERC20(t[i]).balanceOf(cell), h.donatedTo(cell, t[i]), "protocol flow left funds on a DealCell"
                );
            }
        }
    }

    /// Child DACs created by DAC deals keep their own treasury backed.
    function _chk_H1_childDacSane() internal view {
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            if (info.childDac == address(0)) continue;
            address[2] memory t = [usdc, tok2];
            for (uint256 i = 0; i < 2; i++) {
                uint256 recorded = uint256(vm.load(info.childController, keccak256(abi.encode(t[i], uint256(5)))));
                assertGe(IERC20(t[i]).balanceOf(info.childController), recorded, "child treasury not backed");
            }
            MainToken childMain = MainToken(info.childMain);
            assertLe(childMain.totalSupply(), childMain.maxSupply(), "child supply above cap");
            // must not revert
            DealManager(DACCell(info.childDac).getDealManager()).totalReleasedVotable();
        }
    }

    // ------------------------------------------------------------------ //
    // 1. Solvency / conservation                                           //
    // ------------------------------------------------------------------ //

    /// balance(controller) >= treasuryBalances >= committedBalances, and the
    /// commitment equals the dividends still owed.
    function _chk_A1_treasuryBackedAndCommitmentsExact() internal view {
        address[3] memory t = _tokens3();
        for (uint256 i = 0; i < 3; i++) {
            uint256 bal = IERC20(t[i]).balanceOf(controller);
            uint256 treasury = h.ctrlTreasury(t[i]);
            uint256 committed = h.ctrlCommitted(t[i]);
            assertGe(bal, treasury, "controller balance below recorded treasury");
            assertGe(treasury, committed, "treasury below commitments");
            assertEq(
                committed,
                h.ghostDividendsCommitted(t[i]) - h.ghostDividendsClaimed(t[i]) - h.ghostDividendsSwept(t[i]),
                "commitments != dividends still owed"
            );
        }
    }

    /// The controller's ledger moves only by capital calls, recorded recoveries,
    /// dividends, treasury mint/burn and the deals' invested / returned capital.
    function _chk_A2_treasuryLedgerMatchesDeals() internal view {
        address[3] memory t = _tokens3();
        uint256 n = h.dealCount();
        for (uint256 i = 0; i < 3; i++) {
            int256 expected = h.ghostTreasuryCredits(t[i]);
            for (uint256 d = 0; d < n; d++) {
                IDealCell c = IDealCell(h.dealInfo(d).cell);
                expected += int256(c.getReturnedCapital(t[i]));
                expected -= int256(c.getInvestedCapital(t[i]));
            }
            assertEq(int256(h.ctrlTreasury(t[i])), expected, "treasury ledger drift");
        }
    }

    /// Cash leaves the protocol perimeter only through governed exits
    /// (dividends, treasury-deal spends).
    function _chk_A3_cashConservation() internal view {
        address[2] memory t = [usdc, tok2];
        uint256 n = h.perimeterCount();
        for (uint256 i = 0; i < 2; i++) {
            uint256 sum;
            for (uint256 p = 0; p < n; p++) {
                sum += IERC20(t[i]).balanceOf(h.perimeter(p));
            }
            assertEq(sum, h.ghostIn(t[i]) - h.ghostOut(t[i]), "cash left the perimeter through an ungoverned path");
        }
    }

    /// Invested capital per deal and token equals the settled tranches.
    function _chk_A4_investedEqualsSettledTranches() internal view {
        address[3] memory t = _tokens3();
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            IDealCell c = IDealCell(h.dealInfo(d).cell);
            for (uint256 i = 0; i < 3; i++) {
                assertEq(c.getInvestedCapital(t[i]), h.ghostInvested(d, t[i]), "invested != settled tranches");
            }
        }
    }

    /// Dividend claims never exceed the committed payout, and the controller's
    /// counter matches what receivers actually got.
    function _chk_A5_dividendClaimsCapped() internal view {
        uint256 n = h.payoutCount();
        for (uint256 i = 0; i < n; i++) {
            NativeBase.Payout memory po = h.payoutInfo(i);
            if (!po.active) continue;
            assertLe(po.claimed + po.swept, po.total, "dividend claims exceed the payout");
            bytes32 base = keccak256(abi.encode(po.pid, uint256(7)));
            uint256 claimedOnChain = uint256(vm.load(controller, bytes32(uint256(base) + 2)));
            // A sweep closes the payout by counting its unclaimed remainder as settled.
            assertEq(claimedOnChain, po.claimed + po.swept, "claimedPayout drift");
        }
    }

    // ------------------------------------------------------------------ //
    // 2. Rewards                                                           //
    // ------------------------------------------------------------------ //

    /// paid <= unlocked <= limit; the cell's and the manager's limit agree; the
    /// claimable balances are exactly unlocked - paid.
    function _chk_B1_rewardBoundsAndClaimables() internal {
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            DealState memory st = _state(info.cell);
            assertLe(st.rewardsPaid, st.rewardsUnlocked, "paid > unlocked");
            assertLe(st.rewardsUnlocked, st.rewardsLimit, "unlocked > limit");

            if (IDealCell(info.cell).isApproved()) {
                assertEq(IDealCell(info.cell).getMainRewardsLimit(), st.rewardsLimit, "cell/manager limit drift");
            }

            address[] memory stakers = h.stakersOf(d);
            uint256 claimable = h.cellClaimable(info.cell, info.deal);
            for (uint256 s = 0; s < stakers.length; s++) {
                claimable += h.cellClaimable(info.cell, stakers[s]);
            }
            assertEq(claimable, st.rewardsUnlocked - st.rewardsPaid, "claimables != unlocked - paid");
        }
    }

    /// The controller's reservation is exactly what deals can still claim, it
    /// always fits under the supply cap, and both views agree.
    function _chk_B2_obligationsExactAndMintable() internal {
        uint256 n = h.dealCount();
        uint256 expected;
        for (uint256 d = 0; d < n; d++) {
            DealState memory st = _state(h.dealInfo(d).cell);
            expected += st.active ? st.rewardsLimit - st.rewardsPaid : st.rewardsUnlocked - st.rewardsPaid;
        }
        uint256 obligations = h.ctrlObligations();
        assertEq(obligations, expected, "reward reservation drift");
        assertEq(dealManager.mainTokenObligations(), obligations, "obligation views disagree");
        assertLe(mainToken.totalSupply() + obligations, mainToken.maxSupply(), "promised rewards no longer mintable");
    }

    /// Every main token in existence came from a capital call, a treasury mint
    /// or a reward claim.
    function _chk_B3_mainSupplyLedger() internal {
        uint256 n = h.dealCount();
        uint256 paid;
        for (uint256 d = 0; d < n; d++) {
            paid += _state(h.dealInfo(d).cell).rewardsPaid;
        }
        assertEq(
            mainToken.totalSupply(),
            h.ghostMainMintedByCalls() + h.ghostMainTreasuryMinted() + paid - h.ghostMainBurned(),
            "unexplained main-token supply"
        );
    }

    // ------------------------------------------------------------------ //
    // 3. Staking                                                           //
    // ------------------------------------------------------------------ //

    /// Stake supply is backed 1:1 by escrowed agent tokens (liquidator stake is
    /// the only unbacked part) and is fully attributed to known stakers.
    function _chk_C1_stakeBackedAndAttributed() internal view {
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            StakedAgent st = StakedAgent(info.stake);
            assertEq(st.totalSupply(), agentToken.balanceOf(info.cell) + info.unbacked, "stake not backed by escrow");

            address[] memory stakers = h.stakersOf(d);
            uint256 sum;
            for (uint256 s = 0; s < stakers.length; s++) {
                sum += st.balanceOf(stakers[s]);
            }
            assertEq(sum, st.totalSupply(), "stake held by unknown accounts");
        }
    }

    // ------------------------------------------------------------------ //
    // 4. Voting supply                                                     //
    // ------------------------------------------------------------------ //

    /// totalReleasedVotable never underflows, follows the controller's own
    /// bookkeeping exactly, and always covers the votes that exist.
    function _chk_D1_votableSupply() internal view {
        uint256 votable = dealManager.totalReleasedVotable();
        uint256 supply = mainToken.totalSupply();

        uint256 n = h.controlledCount();
        uint256 lockedSum;
        uint256 lockedOthers;
        uint256 controlledBal;
        for (uint256 i = 0; i < n; i++) {
            address c = h.controlledList(i);
            assertTrue(IAssetController(controller).isControlledAddress(c), "harness controlled list out of sync");
            uint256 locked = h.ctrlLocked(c);
            uint256 bal = mainToken.balanceOf(c);
            assertLe(locked, bal, "locked main tokens exceed the balance");
            lockedSum += locked;
            controlledBal += bal;
            if (c != address(dac) && c != controller) lockedOthers += locked;
        }
        assertEq(lockedSum, h.ctrlUnreleased(), "unreleased != sum of locked");
        assertEq(
            votable,
            supply - mainToken.balanceOf(address(dac)) - mainToken.balanceOf(controller) - lockedOthers,
            "votable supply formula drift"
        );
        // Never below the true free float (donations to controlled addresses only raise it).
        assertGe(votable, supply - controlledBal, "votable supply below the free float");

        uint256 votes = mainToken.getVotes(founder);
        uint256 actors = h.actorCount();
        for (uint256 i = 0; i < actors; i++) {
            votes += mainToken.getVotes(h.actors(i));
        }
        assertLe(votes, votable, "live votes exceed the votable supply");
    }

    // ------------------------------------------------------------------ //
    // 5. State machine                                                     //
    // ------------------------------------------------------------------ //

    function _chk_E1_proposalsExecuteAtMostOnce() internal view {
        uint256 high = h.dacPidHigh();
        for (uint256 pid = 1; pid <= high; pid++) {
            uint256 count = h.dacExecCount(pid);
            assertLe(count, 1, "DAC proposal executed twice");
            assertEq(
                IExecutableProposal(dac.getProposalVoting(pid)).isExecuted(), count == 1, "DAC executed flag drift"
            );
        }
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            Deal deal = Deal(h.dealInfo(d).deal);
            uint256 dh = h.dealPropHigh(d);
            for (uint256 pid = 1; pid <= dh; pid++) {
                uint256 count = h.dealPropExecCount(d, pid);
                assertLe(count, 1, "deal proposal executed twice");
                assertEq(
                    IExecutableProposal(deal.getProposal(pid)).isExecuted(), count == 1, "deal executed flag drift"
                );
            }
        }
    }

    function _chk_E2_closedAndApprovedAreFinal() internal {
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            IDealCell c = IDealCell(info.cell);
            if (info.everApproved) assertTrue(c.isApproved(), "approved deal became unapproved");
            if (info.everClosed) assertTrue(c.isClosed(), "closed deal reopened");
            DealState memory st = _state(info.cell);
            if (c.isClosed()) assertFalse(st.active, "closed deal still active in the manager");
            if (st.active) assertTrue(c.isApproved() && !c.isClosed(), "active deal not open");
        }
    }

    /// The electorate a proposal recorded covers every vote that exists at its
    /// snapshot (and therefore every vote that can be cast on it).
    function _chk_F1_tallyWithinElectorate() internal view {
        uint256 high = h.dacPidHigh();
        uint256 from = high > 8 ? high - 8 : 1;
        uint256 actors = h.actorCount();
        for (uint256 pid = from; pid <= high; pid++) {
            Proposal p = Proposal(dac.getProposalVoting(pid));
            assertLe(p.yesVotes() + p.noVotes(), p.totalVotingPower(), "DAC tally exceeds recorded electorate");
            uint256 snap = p.snapshotTime();
            if (snap >= block.timestamp) continue;
            uint256 votes = mainToken.getPastVotes(founder, snap);
            for (uint256 i = 0; i < actors; i++) {
                votes += mainToken.getPastVotes(h.actors(i), snap);
            }
            assertLe(votes, p.totalVotingPower(), "DAC snapshot votes exceed recorded electorate");
        }
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            Deal deal = Deal(info.deal);
            uint256 dh = h.dealPropHigh(d);
            uint256 dfrom = dh > 4 ? dh - 4 : 1;
            address[] memory stakers = h.stakersOf(d);
            for (uint256 pid = dfrom; pid <= dh; pid++) {
                Proposal p = Proposal(deal.getProposal(pid));
                assertLe(p.yesVotes() + p.noVotes(), p.totalVotingPower(), "deal tally exceeds recorded electorate");
                uint256 snap = p.snapshotTime();
                if (snap >= block.timestamp) continue;
                uint256 votes;
                for (uint256 i = 0; i < stakers.length; i++) {
                    votes += StakedAgent(info.stake).getPastVotes(stakers[i], snap);
                }
                assertLe(votes, p.totalVotingPower(), "deal snapshot votes exceed recorded electorate");
            }
        }
    }

    // ------------------------------------------------------------------ //
    // Run-time expectations collected by the handler                       //
    // ------------------------------------------------------------------ //
    function _chk_Z1_noArithmeticPanics() internal view {
        assertEq(h.panicCount(), 0, _panicMsg());
    }

    function _chk_Z2_livenessExpectations() internal view {
        assertEq(h.strictFailures(), 0, _strictMsg());
    }

    function _chk_Z3_soundnessExpectations() internal view {
        assertEq(h.soundnessFailures(), 0, string(abi.encodePacked("must-fail call succeeded: ", h.lastSoundnessTag())));
    }

    function _panicMsg() internal view returns (string memory) {
        return string(
            abi.encodePacked("panic in handler ", _b32(h.lastPanicHandler()), " code ", vm.toString(h.lastPanicCode()))
        );
    }

    function _strictMsg() internal view returns (string memory) {
        return string(
            abi.encodePacked(
                "must-succeed call reverted in ",
                _b32(h.lastStrictHandler()),
                " selector ",
                vm.toString(bytes32(h.lastStrictSelector())),
                " data ",
                vm.toString(h.lastStrictData())
            )
        );
    }

    function _b32(bytes32 b) internal pure returns (string memory) {
        uint256 len;
        while (len < 32 && b[len] != 0) len++;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[i];
        }
        return string(out);
    }

    // ------------------------------------------------------------------ //
    // 6. Liveness probes from the reached state + statistics               //
    // ------------------------------------------------------------------ //
    function _afterRun() internal {
        _dumpStats();
        _probeClaims();
        _probeClawback();
        _probeUnstakeAfterClose();
        _probeDividends();
    }

    /// Every unlocked reward is claimable by its owner.
    function _probeClaims() internal {
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            address[] memory stakers = h.stakersOf(d);
            address live;
            for (uint256 s = 0; s < stakers.length; s++) {
                uint256 claimable = h.cellClaimable(info.cell, stakers[s]);
                if (StakedAgent(info.stake).balanceOf(stakers[s]) > 0) live = stakers[s];
                if (claimable == 0) continue;
                uint256 before = mainToken.balanceOf(stakers[s]);
                vm.prank(stakers[s]);
                IDealCell(info.cell).claimMainToken(0);
                assertEq(mainToken.balanceOf(stakers[s]), before + claimable, "probe: claim paid a wrong amount");
            }
            if (live != address(0) && h.cellClaimable(info.cell, info.deal) > 0) {
                vm.prank(live);
                if (info.kind == 0) TreasuryDeal(info.deal).claimDealRewardPool(0);
                else DACDeal(info.deal).claimDealRewardPool(0);
                assertEq(h.cellClaimable(info.cell, info.deal), 0, "probe: pool not claimed");
            }
        }
    }

    /// Past its deadline every deal hands all funding-token balances back.
    function _probeClawback() internal {
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            IDealCell c = IDealCell(info.cell);
            uint256 deadline = c.dealDeadline();
            if (block.timestamp <= deadline) vm.warp(deadline + 1);

            vm.prank(founder);
            dealManager.forceReturnCapital(info.id);

            address[] memory funding = c.fundingTokens();
            for (uint256 i = 0; i < funding.length; i++) {
                assertEq(IERC20(funding[i]).balanceOf(info.cell), 0, "probe: capital left on the cell");
                assertEq(IERC20(funding[i]).balanceOf(info.deal), 0, "probe: capital left on the deal");
                if (info.treasury != address(0)) {
                    assertEq(IERC20(funding[i]).balanceOf(info.treasury), 0, "probe: capital left in the treasury");
                }
            }
        }
    }

    /// After close (and outside recovery) every staker recovers the full stake.
    function _probeUnstakeAfterClose() internal {
        uint256 n = h.dealCount();
        for (uint256 d = 0; d < n; d++) {
            NativeBase.DealInfo memory info = h.dealInfo(d);
            IDealCell c = IDealCell(info.cell);
            if (!c.isClosed()) continue;
            bool recovery = (uint256(vm.load(info.cell, bytes32(uint256(24)))) >> 16) & 0xff != 0;
            if (recovery) continue;
            address[] memory stakers = h.stakersOf(d);
            for (uint256 s = 0; s < stakers.length; s++) {
                uint256 stake = StakedAgent(info.stake).balanceOf(stakers[s]);
                if (stake == 0) continue;
                uint256 before = agentToken.balanceOf(stakers[s]);
                vm.prank(stakers[s]);
                c.unstake();
                assertEq(agentToken.balanceOf(stakers[s]), before + stake, "probe: stake not returned");
            }
            assertEq(StakedAgent(info.stake).totalSupply(), 0, "probe: stake left after everyone exited");
            assertEq(agentToken.balanceOf(info.cell), 0, "probe: agent tokens stranded on the cell");
        }
    }

    /// Every remaining leaf of a well-formed payout is payable.
    function _probeDividends() internal {
        uint256 n = h.payoutCount();
        for (uint256 i = 0; i < n; i++) {
            NativeBase.Payout memory po = h.payoutInfo(i);
            if (!po.active || !po.exactSum) continue;
            for (uint256 leaf = 0; leaf < 4; leaf++) {
                if (po.leafClaimed[leaf]) continue;
                h.x_probeDividend(i, leaf);
            }
        }
    }

    function _dumpStats() internal {
        if (!vm.envOr("INV_STATS", false)) return;
        string memory path = vm.envOr("INV_STATS_FILE", string("invariant-out/native-stats.csv"));
        uint256 n = h.statCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 name = h.statNames(i);
            (uint256 calls, uint256 ok, uint256 skipped, uint256 reverted) = h.stats(name);
            vm.writeLine(
                path,
                string(
                    abi.encodePacked(
                        "STAT,",
                        _b32(name),
                        ",",
                        vm.toString(calls),
                        ",",
                        vm.toString(ok),
                        ",",
                        vm.toString(skipped),
                        ",",
                        vm.toString(reverted)
                    )
                )
            );
        }
        uint256 r = h.revertKeyCount();
        for (uint256 i = 0; i < r; i++) {
            bytes32 key = h.revertKeys(i);
            vm.writeLine(
                path,
                string(
                    abi.encodePacked(
                        "REV,",
                        _b32(h.revertKeyName(key)),
                        ",",
                        vm.toString(bytes32(h.revertKeySel(key))),
                        ",",
                        vm.toString(h.revertCount(key))
                    )
                )
            );
        }
        vm.writeLine(
            path,
            string(
                abi.encodePacked("RUN,deals,", vm.toString(h.dealCount()), ",dacProps,", vm.toString(h.dacPidHigh()))
            )
        );
        // Main tokens parked on controlled addresses that still count as votable (accepted I-05).
        uint256 controlledBal;
        uint256 cn = h.controlledCount();
        for (uint256 i = 0; i < cn; i++) {
            controlledBal += mainToken.balanceOf(h.controlledList(i));
        }
        uint256 drift = dealManager.totalReleasedVotable() - (mainToken.totalSupply() - controlledBal);
        vm.writeLine(path, string(abi.encodePacked("DRIFT,", vm.toString(drift))));
    }
}

/// Always-on smoke campaign.
contract NativeInvariants is NativeInvariantChecks {
    function setUp() public {
        _setUpSuite();
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_all() public {
        _all();
    }

    function afterInvariant() public {
        _afterRun();
    }
}

/// Full campaign: size comes from the active profile / FOUNDRY_INVARIANT_* variables.
contract NativeInvariantsCampaign is NativeInvariantChecks {
    function setUp() public {
        if (!vm.envOr("INV_CAMPAIGN", false)) {
            vm.skip(true);
            return;
        }
        _setUpSuite();
    }

    function invariant_all() public {
        _all();
    }

    function afterInvariant() public {
        _afterRun();
    }
}
