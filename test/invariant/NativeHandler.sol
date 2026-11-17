// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./NativeSetup.sol";
import {Permit2Treasury} from "../../src/modules/core/deals/Permit2Treasury.sol";
import {DACErrorsLib} from "../../src/interfaces/DACErrorsLib.sol";
import {VotingConfig} from "../../src/interfaces/Structs.sol";

/// Fuzz entry points (`h_*`) for the native-DAC campaign. Every protocol
/// interaction runs inside an external self-call (`x_*`) wrapped in try/catch so
/// a revert never escapes, ghost state stays atomic with the protocol state, and
/// every revert selector is counted per handler.
contract NativeHandler is NativeSetup {
    // ================================================================== //
    // Time                                                                //
    // ================================================================== //
    function h_warp(uint256 secs) external {
        bytes32 n = "warp";
        _begin(n);
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
        _ok(n);
    }

    function h_warpLong(uint256 secs) external {
        bytes32 n = "warpLong";
        _begin(n);
        vm.warp(block.timestamp + bound(secs, 2 days, 25 days));
        _ok(n);
    }

    // ================================================================== //
    // Main token: transfers, delegation, burns, donations                 //
    // ================================================================== //
    function h_mainTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        bytes32 n = "mainTransfer";
        _begin(n);
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 bal = mainToken.balanceOf(from);
        if (bal == 0 || from == to) return _skip(n);
        // The founder keeps most of its stake so governance fast paths stay alive.
        amount = bound(amount, 1, from == founder ? bal / 20 + 1 : bal);
        try this.x_mainTransfer(from, to, amount) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            _strict(n, err);
        }
    }

    function x_mainTransfer(address from, address to, uint256 amount) external onlySelf {
        _allowLoss(from);
        if (inPerimeter[to]) donatedTo[to][address(mainToken)] += amount;
        vm.prank(from);
        mainToken.transfer(to, amount);
    }

    function h_mainDelegate(uint256 fromSeed, uint256 toSeed) external {
        bytes32 n = "mainDelegate";
        _begin(n);
        address from = _actor(fromSeed);
        // delegate to an actor, the founder, or back to self; never to zero (keeps electorate alive)
        address to = toSeed % 4 == 0 ? from : _holder(toSeed);
        try this.x_mainDelegate(from, to) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            _strict(n, err);
        }
    }

    function x_mainDelegate(address from, address to) external onlySelf {
        vm.prank(from);
        mainToken.delegate(to);
    }

    function h_mainBurn(uint256 seed, uint256 amount) external {
        bytes32 n = "mainBurn";
        _begin(n);
        address from = _actor(seed);
        uint256 bal = mainToken.balanceOf(from);
        if (bal == 0) return _skip(n);
        amount = bound(amount, 1, bal / 10 + 1);
        try this.x_mainBurn(from, amount) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            _strict(n, err);
        }
    }

    function x_mainBurn(address from, uint256 amount) external onlySelf {
        _allowLoss(from);
        vm.prank(from);
        mainToken.burn(amount);
        ghostMainBurned += amount;
    }

    function _donationTarget(uint256 seed) internal view returns (address) {
        uint256 roll = seed % 6;
        if (roll == 0) return address(dac);
        if (roll == 1) return controller;
        if (roll == 2) return address(dealManager);
        return perimeter[(seed / 6) % perimeter.length];
    }

    function h_donateCash(uint256 tokSeed, uint256 targetSeed, uint256 amount) external {
        bytes32 n = "donateCash";
        _begin(n);
        address token = _cash(tokSeed);
        address target = _donationTarget(targetSeed);
        amount = bound(amount, 1, token == address(usdc) ? 50_000e6 : 50_000e18);
        InvToken(token).mint(target, amount);
        ghostIn[token] += amount;
        donatedTo[target][token] += amount;
        _ok(n);
    }

    // Business revenue landing on the deal's working address (treasury / DAC deal).
    function h_profit(uint256 dealSeed, uint256 tokSeed, uint256 amount) external {
        bytes32 n = "profit";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 4);
        if (!found) return _skip(n);
        address token = _cash(tokSeed);
        DealInfo storage d = _deals[di];
        address target = d.kind == KIND_TREASURY ? d.treasury : d.deal;
        amount = bound(amount, 1, token == address(usdc) ? 30_000e6 : 30_000e18);
        InvToken(token).mint(target, amount);
        ghostIn[token] += amount;
        _ok(n);
    }

    function h_donateMain(uint256 fromSeed, uint256 targetSeed, uint256 amount) external {
        bytes32 n = "donateMain";
        _begin(n);
        address from = _holder(fromSeed);
        address target = _donationTarget(targetSeed);
        uint256 bal = mainToken.balanceOf(from);
        if (bal == 0 || target == address(mainToken)) return _skip(n);
        amount = bound(amount, 1, bal / 100 + 1);
        try this.x_mainTransfer(from, target, amount) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            _strict(n, err);
        }
    }

    function h_setPrice(uint256 tokSeed, uint256 price) external {
        bytes32 n = "setPrice";
        _begin(n);
        oracle.setPrice(_cash(tokSeed), bound(price, 1e15, 1e21));
        _ok(n);
    }

    // ================================================================== //
    // DAC governance: capital calls, mints, burns, agents                 //
    // ================================================================== //
    function h_capitalCallCreate(uint256 recipientSeed, uint256 tokSeed, uint256 tokenAmount, uint256 cash, bool pend)
        external
    {
        bytes32 n = "capitalCallCreate";
        _begin(n);
        address token = _cash(tokSeed);
        tokenAmount = bound(tokenAmount, 1, 20_000_000e18);
        cash = bound(cash, 0, token == address(usdc) ? 500_000e6 : 500_000e18);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.CAPITAL_CALL,
            target: _holder(recipientSeed),
            i: bytes32(tokenAmount),
            data: abi.encode(token, cash, CALL_EXPIRY)
        });
        if (pend) {
            // left for the vote / execute handlers; no time passes here
            try this.x_createDac(p, _holder(recipientSeed >> 8)) {
                _ok(n);
            } catch (bytes memory err) {
                _fail(n, err);
            }
            return;
        }
        try this.x_passDac(p, founder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_createDac(ProposalParams memory p, address creator) external onlySelf returns (uint256 pid) {
        vm.prank(creator);
        pid = dac.createManagementProposal(p);
        _syncDacPids();
    }

    function x_passDac(ProposalParams memory p, address creator) external onlySelf returns (uint256) {
        return _passDac(p, creator);
    }

    function h_capitalCallFulfil(uint256 idxSeed) external {
        bytes32 n = "capitalCallFulfil";
        _begin(n);
        uint256 len = _calls.length;
        if (len == 0) return _skip(n);
        uint256 ci = type(uint256).max;
        for (uint256 k = 0; k < len; k++) {
            uint256 c = (idxSeed % len + k) % len;
            if (!_calls[c].fulfilled) {
                ci = c;
                break;
            }
        }
        if (ci == type(uint256).max) return _skip(n);
        try this.x_fulfil(ci) {
            _ok(n);
        } catch (bytes memory err) {
            bytes4 sel = _fail(n, err);
            // Only the mint-headroom guard may refuse a pending call.
            if (sel != DACErrorsLib.MaxSupplyExceeded.selector) _strict(n, err);
        }
    }

    function x_fulfil(uint256 ci) external onlySelf {
        _fulfil(ci);
    }

    // A fulfilled (or never-created) call must never be payable again.
    function h_capitalCallReplay(uint256 idxSeed, uint256 mutateSeed) external {
        bytes32 n = "capitalCallReplay";
        _begin(n);
        uint256 len = _calls.length;
        if (len == 0) return _skip(n);
        CallInfo memory c = _calls[idxSeed % len];
        CapitalCall memory call = c.call;
        if (!c.fulfilled) {
            // mutate one field of a live call: the hash no longer matches
            uint256 m = mutateSeed % 3;
            if (m == 0) call.cashAmount = call.cashAmount / 2;
            else if (m == 1) call.tokenAmount = call.tokenAmount + 1;
            else call.tokenRecipient = _holder(mutateSeed / 3);
            if (keccak256(abi.encode(call)) == keccak256(abi.encode(c.call))) return _skip(n);
        }
        try this.x_fulfilRaw(call) {
            soundnessFailures += 1;
            lastSoundnessTag = "capitalCallReplay";
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_fulfilRaw(CapitalCall memory call) external onlySelf {
        _allowLoss(call.tokenRecipient);
        InvToken(call.treasuryToken).mint(call.tokenRecipient, call.cashAmount);
        vm.prank(call.tokenRecipient);
        InvToken(call.treasuryToken).approve(controller, call.cashAmount);
        dac.fulfillCapitalCall(call);
    }

    function h_mintAgent(uint256 actorSeed, uint256 amount) external {
        bytes32 n = "mintAgent";
        _begin(n);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.MINT_AGENT_TOKENS,
            target: _actor(actorSeed),
            i: bytes32(bound(amount, 1, 200_000)),
            data: bytes("")
        });
        try this.x_passDac(p, founder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function h_revokeAgent(uint256 actorSeed, uint256 amount) external {
        bytes32 n = "revokeAgent";
        _begin(n);
        address a = _actor(actorSeed);
        uint256 bal = agentToken.balanceOf(a);
        if (bal == 0) return _skip(n);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.REVOKE_AGENT_TOKENS,
            target: a,
            i: bytes32(bound(amount, 1, bal / 4 + 1)),
            data: bytes("")
        });
        try this.x_passDac(p, founder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    // REVOKE_AGENT_TOKENS aimed at escrowed stake must never burn it.
    function h_revokeFromCell(uint256 dealSeed, uint256 amount) external {
        bytes32 n = "revokeFromCell";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found) return _skip(n);
        address cell = _deals[di].cell;
        uint256 bal = agentToken.balanceOf(cell);
        if (bal == 0) return _skip(n);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.REVOKE_AGENT_TOKENS,
            target: cell,
            i: bytes32(bound(amount, 1, bal)),
            data: bytes("")
        });
        try this.x_passDac(p, founder) {
            soundnessFailures += 1;
            lastSoundnessTag = "revokeFromCell";
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function h_treasuryMintMain(uint256 amount) external {
        bytes32 n = "treasuryMintMain";
        _begin(n);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.MINT_MAIN_TOKENS,
            target: address(0),
            i: bytes32(bound(amount, 1, 5_000_000e18)),
            data: bytes("")
        });
        try this.x_passDac(p, founder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function h_treasuryBurnMain(uint256 amount) external {
        bytes32 n = "treasuryBurnMain";
        _begin(n);
        uint256 free = ctrlFree(address(mainToken));
        if (free == 0) return _skip(n);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.BURN_MAIN_TOKENS,
            target: address(0),
            i: bytes32(bound(amount, 1, free)),
            data: bytes("")
        });
        try this.x_passDac(p, founder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    // ================================================================== //
    // Pending DAC proposals: random votes, plain execution, fast path     //
    // ================================================================== //
    // Prefers a not-yet-executed proposal among the most recent ones.
    function _recentDacPid(uint256 seed) internal view returns (uint256) {
        if (dacPidHigh == 0) return 0;
        uint256 window = dacPidHigh < 10 ? dacPidHigh : 10;
        uint256 first = dacPidHigh - (seed % window);
        for (uint256 k = 0; k < window; k++) {
            uint256 pid = dacPidHigh - ((seed % window + k) % window);
            if (!IExecutableProposal(dac.getProposalVoting(pid)).isExecuted()) return pid;
        }
        return first;
    }

    function h_voteDac(uint256 pidSeed, uint256 voterSeed, bool support) external {
        bytes32 n = "voteDac";
        _begin(n);
        uint256 pid = _recentDacPid(pidSeed);
        if (pid == 0) return _skip(n);
        address voter = _holder(voterSeed);
        try this.x_voteDac(pid, voter, support) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_voteDac(uint256 pid, address voter, bool support) external onlySelf {
        address prop = dac.getProposalVoting(pid);
        vm.prank(voter);
        IVoting(prop).vote(support);
    }

    function h_execDac(uint256 pidSeed) external {
        bytes32 n = "execDac";
        _begin(n);
        uint256 pid = _recentDacPid(pidSeed);
        if (pid == 0) return _skip(n);
        try this.x_execDacNow(pid) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_execDacNow(uint256 pid) external onlySelf {
        _execDacNow(pid);
    }

    function h_passDacPending(uint256 pidSeed) external {
        bytes32 n = "passDacPending";
        _begin(n);
        uint256 pid = _recentDacPid(pidSeed);
        if (pid == 0) return _skip(n);
        if (IExecutableProposal(dac.getProposalVoting(pid)).isExecuted()) return _skip(n);
        try this.x_passDacPending(pid) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_passDacPending(uint256 pid) external onlySelf {
        _voteDacAll(dac.getProposalVoting(pid));
        _execDac(pid);
    }

    // ================================================================== //
    // Dividends                                                           //
    // ================================================================== //
    function h_dividendCreate(uint256 tokSeed, uint256 total, uint256 s1, uint256 s2, uint256 s3, bool malformed)
        external
    {
        bytes32 n = "dividendCreate";
        _begin(n);
        address token = _token3(tokSeed);
        uint256 free = ctrlFree(token);
        if (free < 8) return _skip(n);
        total = bound(total, 4, free / 2);

        address[4] memory r = [actors[0], actors[1], actors[2], actors[3]];
        uint256[4] memory a;
        a[0] = bound(s1, 0, total);
        a[1] = bound(s2, 0, total - a[0]);
        a[2] = bound(s3, 0, total - a[0] - a[1]);
        a[3] = total - a[0] - a[1] - a[2];
        if (malformed) a[3] += total / 3 + 1; // leaves over-allocate the committed amount

        try this.x_dividendCreate(token, total, r, a, !malformed) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_dividendCreate(address token, uint256 total, address[4] memory r, uint256[4] memory a, bool exact)
        external
        onlySelf
    {
        bytes32 root = _root(r, a);
        vm.prank(founder);
        uint256 pid = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.DIVIDEND_PAYOUT,
                target: address(0),
                i: 0,
                data: abi.encode(token, total, root)
            })
        );
        _syncDacPids();

        _payouts.push();
        Payout storage po = _payouts[_payouts.length - 1];
        po.pid = pid;
        po.token = token;
        po.total = total;
        po.root = root;
        po.exactSum = exact;
        po.receivers = r;
        po.amounts = a;
        _payoutIdxPlus1[pid] = _payouts.length;

        _voteDacAll(dac.getProposalVoting(pid));
        _execDac(pid);
    }

    function h_dividendClaim(uint256 payoutSeed, uint256 leafSeed) external {
        bytes32 n = "dividendClaim";
        _begin(n);
        uint256 len = _payouts.length;
        if (len == 0) return _skip(n);
        uint256 pi = payoutSeed % len;
        Payout storage po = _payouts[pi];
        if (!po.active) return _skip(n);
        uint256 leaf = leafSeed % 4;
        bool already = po.leafClaimed[leaf];
        bool windowClosed = block.timestamp > IAssetController(controller).dividendClaimDeadline(po.pid);
        try this.x_dividendClaim(pi, leaf) {
            _ok(n);
            if (already) {
                soundnessFailures += 1;
                lastSoundnessTag = "dividendDoubleClaim";
            }
            if (windowClosed) {
                soundnessFailures += 1;
                lastSoundnessTag = "dividendClaimAfterWindow";
            }
        } catch (bytes memory err) {
            bytes4 sel = _fail(n, err);
            if (windowClosed) return;
            // Inside the claim window an unclaimed leaf of a well-formed payout must be payable.
            if (!already && po.exactSum) _strict(n, err);
            if (!already && !po.exactSum && sel != DACErrorsLib.DividendPayoutExceeded.selector) _strict(n, err);
        }
    }

    // After the claim window anyone releases the unclaimed remainder back to the free
    // treasury; before it, nobody can.
    function h_dividendSweep(uint256 payoutSeed) external {
        bytes32 n = "dividendSweep";
        _begin(n);
        uint256 len = _payouts.length;
        if (len == 0) return _skip(n);
        Payout storage po = _payouts[payoutSeed % len];
        if (!po.active) return _skip(n);

        bool windowClosed = block.timestamp > IAssetController(controller).dividendClaimDeadline(po.pid);
        uint256 unclaimed = po.total - po.claimed - po.swept;
        try dac.sweepDividend(po.pid) {
            _ok(n);
            if (!windowClosed || unclaimed == 0) {
                soundnessFailures += 1;
                lastSoundnessTag = "dividendSweptEarlyOrEmpty";
            }
            po.swept += unclaimed;
            ghostDividendsSwept[po.token] += unclaimed;
        } catch (bytes memory err) {
            _fail(n, err);
            if (windowClosed && unclaimed > 0) _strict(n, err);
        }
    }

    function x_dividendClaim(uint256 pi, uint256 leaf) external onlySelf {
        Payout storage po = _payouts[pi];
        address receiver = po.receivers[leaf];
        uint256 amount = po.amounts[leaf];
        uint256 before = IERC20(po.token).balanceOf(receiver);

        dac.claimDividend(po.pid, leaf, receiver, amount, _proof(po.receivers, po.amounts, leaf));

        require(IERC20(po.token).balanceOf(receiver) == before + amount, "harness: dividend not received");
        po.leafClaimed[leaf] = true;
        po.claimed += amount;
        ghostDividendsClaimed[po.token] += amount;
        ghostTreasuryCredits[po.token] -= int256(amount);
        if (!inPerimeter[receiver]) ghostOut[po.token] += amount;
    }

    // End-of-run probe entry point (not a fuzz target).
    function x_probeDividend(uint256 pi, uint256 leaf) external {
        this.x_dividendClaim(pi, leaf);
    }

    // Forged leaf (wrong amount or receiver) must never pay.
    function h_dividendClaimForged(uint256 payoutSeed, uint256 leafSeed, uint256 amount, uint256 whoSeed) external {
        bytes32 n = "dividendClaimForged";
        _begin(n);
        uint256 len = _payouts.length;
        if (len == 0) return _skip(n);
        Payout storage po = _payouts[payoutSeed % len];
        if (!po.active) return _skip(n);
        uint256 leaf = leafSeed % 4;
        address receiver = whoSeed % 2 == 0 ? po.receivers[leaf] : actors[4];
        amount = bound(amount, 1, po.total);
        if (receiver == po.receivers[leaf] && amount == po.amounts[leaf]) return _skip(n);
        try dac.claimDividend(po.pid, leaf, receiver, amount, _proof(po.receivers, po.amounts, leaf)) {
            soundnessFailures += 1;
            lastSoundnessTag = "dividendForged";
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    // ================================================================== //
    // Treasury recovery / sync                                            //
    // ================================================================== //
    function h_recoverTreasury(uint256 tokSeed, uint256 callerSeed) external {
        bytes32 n = "recoverTreasury";
        _begin(n);
        address token = _token3(tokSeed);
        address caller = _holder(callerSeed);
        // the sync is gated by the DAC's proposal qualification, measured like a proposal's:
        // past votes against the votable supply of the same past second
        uint256 snapshot = block.timestamp - 1;
        uint256 needed = MathLib.mul(
            IAssetController(controller).getPastVotableSupply(snapshot), dac.getVotingConfig().qualification
        );
        if (mainToken.balanceOf(caller) == 0 || mainToken.getPastVotes(caller, snapshot) <= needed) return _skip(n);
        try this.x_recoverTreasury(token, caller) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            _strict(n, err);
        }
    }

    function x_recoverTreasury(address token, address caller) external onlySelf {
        uint256 before = ctrlTreasury(token);
        vm.prank(caller);
        dac.recoverTreasury(token);
        uint256 afterBal = ctrlTreasury(token);
        ghostTreasuryCredits[token] += int256(afterBal) - int256(before);
    }

    function h_recoverERC20(uint256 tokSeed, uint256 callerSeed) external {
        bytes32 n = "recoverERC20";
        _begin(n);
        address token = _token3(tokSeed);
        uint256 onCell = IERC20(token).balanceOf(address(dac));
        if (onCell == 0) return _skip(n);
        // fully permissionless: the caller holds nothing
        address caller = sinks[callerSeed % sinks.length];
        try this.x_recoverERC20(token, caller, onCell) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            _strict(n, err);
        }
    }

    function x_recoverERC20(address token, address caller, uint256 onCell) external onlySelf {
        uint256 ctrlBefore = IERC20(token).balanceOf(controller);
        uint256 callerBefore = IERC20(token).balanceOf(caller);
        vm.prank(caller);
        dac.recoverERC20(token);
        require(
            IERC20(token).balanceOf(controller) == ctrlBefore + onCell, "harness: recover did not credit controller"
        );
        require(IERC20(token).balanceOf(caller) == callerBefore, "harness: caller gained from recover");
        ghostTreasuryCredits[token] += int256(onCell);
    }

    // ================================================================== //
    // Deal creation, staking, approval                                    //
    // ================================================================== //
    struct CreateSeeds {
        uint256 agentSeed;
        uint256 kindSeed;
        uint256 evalSeed;
        uint256 funding;
        uint256 rewards;
        uint256 misc;
        uint256 curveSeed;
    }

    function h_createDeal(
        uint256 agentSeed,
        uint256 kindSeed,
        uint256 evalSeed,
        uint256 funding,
        uint256 rewards,
        uint256 misc,
        uint256 curveSeed
    ) external {
        bytes32 n = "createDeal";
        _begin(n);
        if (_deals.length >= MAX_DEALS) return _skip(n);
        CreateSeeds memory s = CreateSeeds(agentSeed, kindSeed, evalSeed, funding, rewards, misc, curveSeed);
        try this.x_createDeal(s) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_createDeal(CreateSeeds memory s) external onlySelf {
        address agent = actors[s.agentSeed % 4];
        uint8 kind = s.kindSeed % 10 < 7 ? KIND_TREASURY : KIND_DAC;
        uint8 evalKind = uint8(s.evalSeed % 4);
        if (evalKind == 3) evalKind = EVAL_MOCK;

        address fundingToken = _cash(s.misc);
        uint256 free = ctrlFree(fundingToken);
        uint256 funding = free == 0 ? 0 : bound(s.funding, 0, free / 4);
        if (kind == KIND_DAC && funding == 0) funding = 1;

        DealParams memory p = DealParams({
            dealKind: kind == KIND_DAC ? CoreDealType.DAC_DEAL : CoreDealType.PERMIT2_TREASURY,
            name: "Fuzz deal",
            description: "fuzz",
            linkHash: "",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGov),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: (s.misc >> 8) % 3 == 0,
            fundingToken: fundingToken,
            fundingAmount: funding,
            rewardsLimit: (s.misc >> 16) % 5 == 0 ? 0 : bound(s.rewards, 1, 5_000_000e18),
            dealRewardPoolPercent: (s.misc >> 24) % 2 == 0 ? 0 : bound(s.rewards >> 64, 1, 1e18),
            approveDeadline: block.timestamp + bound(s.misc >> 32, 1 hours, 8 days),
            evaluationDeadline: block.timestamp + bound(s.misc >> 64, 0, 20 days),
            dealDeadline: block.timestamp + bound(s.misc >> 96, 1 days, 50 days),
            dealConfig: kind == KIND_DAC
                ? _childDealConfig(fundingToken, funding, bound(s.rewards >> 128, 1, 10_000_000e18))
                : abi.encode("cfg"),
            evaluatorSelector: bytes4(0),
            evaluatorConfig: bytes(""),
            evaluatorModuleFactory: address(0),
            agentsLimit: (s.misc >> 128) % 4,
            minimalStake: (s.misc >> 136) % 3 == 0 ? 0 : ((s.misc >> 136) % 3 == 1 ? 100 : 5_000)
        });

        bytes memory realCfg;
        if (evalKind == EVAL_MILESTONE) realCfg = _fuzzMilestoneConfig(fundingToken, s.curveSeed);
        else if (evalKind == EVAL_REVENUE) realCfg = _fuzzRevenueConfig(fundingToken, s.curveSeed);
        _setEvaluator(p, evalKind, realCfg);

        _createDeal(p, kind, evalKind);
    }

    function _coeffs(uint256 seed, int256 lo, int256 hi) internal pure returns (int256[] memory c) {
        uint256 len = 1 + (seed % 3);
        c = new int256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // forge-lint: disable-next-line(unsafe-typecast)
            c[i] = lo + int256(r % uint256(hi - lo + 1));
        }
    }

    function _fuzzMilestoneConfig(address fundingToken, uint256 seed) internal view returns (bytes memory) {
        uint256 count = 1 + (seed % 2);
        Milestone[] memory ms = new Milestone[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, "ms", i)));
            Milestone memory m;
            m.milestoneType = uint8(r % 2);
            m.token = (r >> 8) % 4 == 0 ? (fundingToken == address(usdc) ? address(tok2) : address(usdc)) : fundingToken;
            uint256 modeRoll = (r >> 16) % 10;
            m.valuationMode = modeRoll < 8 ? 0 : (modeRoll == 8 ? 1 : 2);
            m.oracle = (m.valuationMode != 0 || (r >> 24) % 3 == 0) ? address(oracle) : address(0);
            if (m.valuationMode == 0) {
                uint256 ftRoll = (r >> 32) % 3;
                if (ftRoll == 0) {
                    m.fundingToken = address(0);
                    m.expectedReturn = 1 + ((r >> 40) % (m.token == address(usdc) ? 20_000e6 : 20_000e18));
                } else if (ftRoll == 1) {
                    m.fundingToken = m.token;
                    m.expectedReturn = 1e17 + ((r >> 40) % 3e18);
                } else {
                    m.fundingToken = m.token == address(usdc) ? address(tok2) : address(usdc);
                    m.oracle = address(oracle);
                    m.expectedReturn = 1e17 + ((r >> 40) % 3e18);
                }
            } else if (m.valuationMode == 1) {
                m.expectedReturn = 1e18 + ((r >> 40) % 1e30);
            } else {
                m.expectedReturn = 5e17 + ((r >> 40) % 3e18);
            }
            m.timestamp = block.timestamp + 1 hours + ((r >> 104) % 30 days);
            m.rewardPercentage = (r >> 128) % (1e18 + 1);
            m.rewardCurve = _coeffs(r >> 3, -2e18, 2e18);
            m.penaltyCurve = _coeffs(r >> 5, -2e18, 2e18);
            m.minPercentGrace = (r >> 160) % (1e18 + 1);
            m.extension = (r >> 192) % 2 == 0 ? 0 : 1 hours + ((r >> 200) % 10 days);
            m.excludePrincipal = (r >> 224) % 2 == 0;
            ms[i] = m;
        }
        return abi.encode(MilestoneBasedEvaluator.Config((seed >> 200) % (1e18 + 1), ms));
    }

    function _fuzzRevenueConfig(address fundingToken, uint256 seed) internal view returns (bytes memory) {
        uint256 r = uint256(keccak256(abi.encode(seed, "rev")));
        RevenueSchedule memory s;
        s.token = r % 4 == 0 ? (fundingToken == address(usdc) ? address(tok2) : address(usdc)) : fundingToken;
        s.duration = 1 hours + ((r >> 8) % 10 days);
        s.revenueProjectionMode = uint8((r >> 40) % 2);
        s.revenueProjection = s.revenueProjectionMode == 0
            ? 1 + ((r >> 48) % (s.token == address(usdc) ? 10_000e6 : 10_000e18))
            : 1 + ((r >> 48) % 50);
        s.curveCoeffs = _coeffs(r >> 2, -2e18, 2e18);
        s.requirementCurveCoeffs = _coeffs(r >> 4, -1e18, 2e18);
        s.maxCycleUnlockPercent = (r >> 112) % (1e18 + 1);
        s.minCycleRevenuePercent = (r >> 144) % (1e18 + 1);
        s.graceCycles = (r >> 176) % 4;
        s.penaltyPerMiss = (r >> 184) % (1e18 + 1);
        s.evaluationStart = (r >> 216) % 3 == 0 ? block.timestamp + ((r >> 220) % 3 days) : 0;
        s.autoClose = (r >> 240) % 2 == 0;
        s.excludePrincipal = (r >> 248) % 2 == 0;
        return abi.encode(RevenueBasedEvaluator.Config((seed >> 200) % (1e18 + 1), s));
    }

    function h_invite(uint256 dealSeed, uint256 inviterSeed, uint256 inviteeSeed, bool grant) external {
        bytes32 n = "invite";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 1);
        if (!found) return _skip(n);
        try this.x_invite(di, actors[inviterSeed % 4], actors[inviteeSeed % 4], grant) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_invite(uint256 di, address inviter, address invitee, bool grant) external onlySelf {
        vm.prank(inviter);
        IDealCell(_deals[di].cell).invite(invitee, grant);
    }

    function h_stake(uint256 dealSeed, uint256 actorSeed, uint256 amount) external {
        bytes32 n = "stake";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 1);
        if (!found) return _skip(n);
        address a = actors[actorSeed % 4];
        uint256 bal = agentToken.balanceOf(a);
        if (bal == 0) return _skip(n);
        amount = bound(amount, 1, bal < 60_000 ? bal : 60_000);
        try this.x_stake(di, a, amount) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_stake(uint256 di, address a, uint256 amount) external onlySelf {
        _allowLoss(a);
        vm.prank(a);
        agentToken.stakeToDeal(_deals[di].cell, amount);
        _addStaker(di, a);
    }

    function h_approveDeal(uint256 dealSeed) external {
        bytes32 n = "approveDeal";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 1);
        if (!found) return _skip(n);
        try this.x_passDacPending(_deals[di].approvePid) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    // ================================================================== //
    // Deal proposals: generic vote / execute / fast path                  //
    // ================================================================== //
    function _recentDealPid(uint256 di, uint256 seed) internal view returns (uint256) {
        uint256 high = dealPropHigh[di];
        if (high == 0) return 0;
        uint256 window = high < 8 ? high : 8;
        uint256 first = high - (seed % window);
        Deal d = Deal(_deals[di].deal);
        for (uint256 k = 0; k < window; k++) {
            uint256 pid = high - ((seed % window + k) % window);
            if (!IExecutableProposal(d.getProposal(pid)).isExecuted()) return pid;
        }
        return first;
    }

    function h_voteDealProp(uint256 dealSeed, uint256 pidSeed, uint256 voterSeed, bool support) external {
        bytes32 n = "voteDealProp";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found) return _skip(n);
        uint256 pid = _recentDealPid(di, pidSeed);
        if (pid == 0 || _stakers[di].length == 0) return _skip(n);
        address voter = _stakers[di][voterSeed % _stakers[di].length];
        try this.x_voteDealProp(di, pid, voter, support) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_voteDealProp(uint256 di, uint256 pid, address voter, bool support) external onlySelf {
        address prop = Deal(_deals[di].deal).getProposal(pid);
        vm.prank(voter);
        IVoting(prop).vote(support);
    }

    function h_execDealProp(uint256 dealSeed, uint256 pidSeed) external {
        bytes32 n = "execDealProp";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found) return _skip(n);
        uint256 pid = _recentDealPid(di, pidSeed);
        if (pid == 0) return _skip(n);
        try this.x_execDealNow(di, pid) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_execDealNow(uint256 di, uint256 pid) external onlySelf {
        _execDealNow(di, pid);
    }

    function h_passDealPending(uint256 dealSeed, uint256 pidSeed) external {
        bytes32 n = "passDealPending";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found) return _skip(n);
        uint256 pid = _recentDealPid(di, pidSeed);
        if (pid == 0) return _skip(n);
        if (IExecutableProposal(Deal(_deals[di].deal).getProposal(pid)).isExecuted()) return _skip(n);
        try this.x_passDealPending(di, pid) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_passDealPending(uint256 di, uint256 pid) external onlySelf {
        _voteDealAll(di, Deal(_deals[di].deal).getProposal(pid));
        _execDeal(di, pid);
    }

    function x_passDeal(uint256 di, address proposer, ProposalParams memory p) external onlySelf returns (uint256) {
        return _passDeal(di, proposer, p);
    }

    function x_createDealProp(uint256 di, address proposer, ProposalParams memory p) external onlySelf {
        vm.prank(proposer);
        Deal(_deals[di].deal).createStakedAgentProposal(p);
        _syncDealProps(di);
    }

    // Shared wrapper: proposal by a live staker, voted by everyone, executed.
    // One time in six the proposal is only created and left to the generic handlers.
    function _dealGov(bytes32 n, uint256 di, uint256 proposerSeed, ProposalParams memory p) internal returns (bool ok) {
        address proposer = _liveStaker(di, proposerSeed);
        if (proposer == address(0)) {
            _skip(n);
            return false;
        }
        if ((proposerSeed >> 24) % 6 == 0) {
            try this.x_createDealProp(di, proposer, p) {
                _ok(n);
                return true;
            } catch (bytes memory err) {
                _fail(n, err);
                return false;
            }
        }
        try this.x_passDeal(di, proposer, p) {
            _ok(n);
            return true;
        } catch (bytes memory err) {
            _fail(n, err);
            return false;
        }
    }

    // DAC-side veto challenge against a recent challengeable deal proposal.
    function h_vetoDealProp(uint256 dealSeed, uint256 pidSeed, uint256 creatorSeed) external {
        bytes32 n = "vetoDealProp";
        _begin(n);
        uint256 nd = _deals.length;
        for (uint256 k = 0; k < nd; k++) {
            uint256 di = (dealSeed % nd + k) % nd;
            uint256 high = dealPropHigh[di];
            uint256 window = high < 8 ? high : 8;
            for (uint256 j = 0; j < window; j++) {
                uint256 pid = high - ((pidSeed % window + j) % window);
                address prop = Deal(_deals[di].deal).getProposal(pid);
                if (!IChallengeable(prop).isChallengeable()) continue;
                if (IChallengeable(prop).dacChallengeProposal() != address(0)) continue;
                if (IExecutableProposal(prop).isExecuted()) continue;
                ProposalParams memory p = ProposalParams({
                    typ: DACManagementProposalType.CAST_VETO_DEAL,
                    target: address(0),
                    i: 0,
                    data: abi.encode(_deals[di].id, pid)
                });
                address creator = creatorSeed % 3 == 0 ? _holder(creatorSeed / 3) : founder;
                try this.x_createDac(p, creator) {
                    _ok(n);
                } catch (bytes memory err) {
                    _fail(n, err);
                }
                return;
            }
        }
        _skip(n);
    }

    // ================================================================== //
    // Voting configuration changes                                        //
    // ================================================================== //
    function _votingConfig(uint256 seed, bool forDac) internal pure returns (VotingConfig memory c) {
        uint256 r = uint256(keccak256(abi.encode(seed, forDac)));
        // Inside the kernel's sanity bounds: thresholds at or above 0.1%, high >= default,
        // blocking either off or at or above 0.1%.
        if (forDac) {
            // keep the DAC governable by the founder-led fast path
            c.quorumPercent = 1e17 + (r % 6e17);
            c.highQuorumPercent = c.quorumPercent + ((r >> 32) % (9e17 - c.quorumPercent + 1));
            c.blockingPercent = (r >> 64) % 4e17;
            c.qualification = (r >> 96) % 5e16;
        } else {
            c.quorumPercent = 1e15 + (r % (1e18 - 1e15 + 1));
            c.highQuorumPercent = c.quorumPercent + ((r >> 32) % (1e18 - c.quorumPercent + 1));
            c.blockingPercent = (r >> 64) % (1e18 + 1);
            c.qualification = (r >> 96) % (5e17 + 1);
        }
        if (c.blockingPercent != 0 && c.blockingPercent < 1e15) c.blockingPercent = 1e15;
        c.duration = 1 hours + ((r >> 128) % 10 days);
        c.executionValidityDuration = 1 hours + ((r >> 160) % 5 days);
    }

    function h_dealVotingConfig(uint256 dealSeed, uint256 cfgSeed, uint256 proposerSeed) external {
        bytes32 n = "dealVotingConfig";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found) return _skip(n);
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({
                typ: AbstractDealManagementType.UPDATE_VOTING_CONFIG,
                target: address(0),
                i: 0,
                data: abi.encode(_votingConfig(cfgSeed, false))
            })
        );
    }

    function h_dacVotingConfig(uint256 cfgSeed) external {
        bytes32 n = "dacVotingConfig";
        _begin(n);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.UPDATE_VOTING_CONFIG,
            target: address(0),
            i: 0,
            data: abi.encode(_votingConfig(cfgSeed, true))
        });
        try this.x_passDac(p, founder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    // Every staker of a closed deal leaves (opens the way to recovery).
    function h_exitAll(uint256 dealSeed) external {
        bytes32 n = "exitAll";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 3);
        if (!found || _inRecovery(_deals[di].cell)) return _skip(n);
        if (StakedAgent(_deals[di].stake).totalSupply() == 0) return _skip(n);
        try this.x_exitAll(di) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            _strict(n, err);
        }
    }

    function x_exitAll(uint256 di) external onlySelf {
        DealInfo storage d = _deals[di];
        address[] storage st = _stakers[di];
        for (uint256 i = 0; i < st.length; i++) {
            uint256 stake = StakedAgent(d.stake).balanceOf(st[i]);
            if (stake == 0) continue;
            uint256 before = agentToken.balanceOf(st[i]);
            vm.prank(st[i]);
            IDealCell(d.cell).unstake();
            require(agentToken.balanceOf(st[i]) == before + stake, "harness: exit did not return principal");
        }
        require(StakedAgent(d.stake).totalSupply() == 0, "harness: stake left after exit");
    }

    // ================================================================== //
    // Stake management                                                    //
    // ================================================================== //
    function h_unstake(uint256 dealSeed, uint256 actorSeed, bool passNow) external {
        bytes32 n = "unstake";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found || _stakers[di].length == 0) return _skip(n);
        address a = _stakers[di][actorSeed % _stakers[di].length];
        DealInfo storage d = _deals[di];
        IDealCell c = IDealCell(d.cell);
        uint256 stake = StakedAgent(d.stake).balanceOf(a);
        bool closed = c.isClosed();
        bool recovery = _inRecovery(d.cell);
        try this.x_unstake(di, a, passNow) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            // After close (no recovery) a staker must always get the principal back.
            if (closed && !recovery && stake > 0) _strict(n, err);
        }
    }

    function _inRecovery(address cell) internal view returns (bool) {
        // DealCell slot 24: approved | closed | recovery | vetoEnabled | earlyReturns | isWhitelistOnly
        return (uint256(vm.load(cell, bytes32(uint256(24)))) >> 16) & 0xff != 0;
    }

    function x_unstake(uint256 di, address a, bool passNow) external onlySelf {
        DealInfo storage d = _deals[di];
        IDealCell c = IDealCell(d.cell);
        bool viaProposal = c.isApproved() && !c.isClosed();
        uint256 stake = StakedAgent(d.stake).balanceOf(a);
        uint256 agentBefore = agentToken.balanceOf(a);

        vm.prank(a);
        c.unstake();

        if (viaProposal) {
            _syncDealProps(di);
            if (passNow) {
                uint256 pid = dealPropHigh[di];
                _voteDealAll(di, Deal(d.deal).getProposal(pid));
                _execDeal(di, pid);
            }
        } else {
            require(agentToken.balanceOf(a) == agentBefore + stake, "harness: unstake did not return principal");
        }
    }

    function h_addStake(uint256 dealSeed, uint256 actorSeed, uint256 amount, uint256 proposerSeed) external {
        bytes32 n = "addStake";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 2);
        if (!found) return _skip(n);
        address a = actors[actorSeed % 4];
        uint256 bal = agentToken.balanceOf(a);
        if (bal == 0) return _skip(n);
        amount = bound(amount, 1, bal < 40_000 ? bal : 40_000);
        try this.x_approveAgentToken(a, _deals[di].cell, amount) {}
        catch (bytes memory err) {
            _fail(n, err);
            return;
        }
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({typ: AbstractDealManagementType.ADD_STAKE, target: a, i: bytes32(amount), data: bytes("")})
        );
    }

    function x_approveAgentToken(address a, address cell, uint256 amount) external onlySelf {
        vm.prank(a);
        agentToken.approve(cell, amount);
    }

    function h_strikeOut(uint256 dealSeed, uint256 targetSeed, uint256 proposerSeed) external {
        bytes32 n = "strikeOut";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 2);
        if (!found || _stakers[di].length < 2) return _skip(n);
        address target = _stakers[di][targetSeed % _stakers[di].length];
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({typ: AbstractDealManagementType.STRIKE_OUT_AGENT, target: target, i: 0, data: bytes("")})
        );
    }

    function h_toggle(uint256 dealSeed, uint256 which, bool on, uint256 proposerSeed) external {
        bytes32 n = "toggle";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found) return _skip(n);
        uint256 w = which % 3;
        bytes4 typ = w == 0
            ? AbstractDealManagementType.TOGGLE_EARLY_RETURNS
            : (w == 1 ? AbstractDealManagementType.TOGGLE_WHITELIST : AbstractDealManagementType.ENABLE_VETO_RIGHT);
        _dealGov(n, di, proposerSeed, ProposalParams({typ: typ, target: address(0), i: 0, data: abi.encode(on)}));
    }

    // ================================================================== //
    // Tranches                                                            //
    // ================================================================== //
    function h_requestTranche(uint256 dealSeed, uint256 tokSeed, uint256 amount, uint256 rewards, uint256 proposerSeed)
        external
    {
        bytes32 n = "requestTranche";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 2, KIND_TREASURY);
        if (!found) return _skip(n);
        address token = _cash(tokSeed);
        uint256 free = ctrlFree(token);
        if (free == 0) return _skip(n);
        amount = bound(amount, 1, free / 5 + 1);
        rewards = proposerSeed % 3 == 0 ? 0 : bound(rewards, 1, 2_000_000e18);
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: token,
                i: bytes32(amount),
                data: abi.encode(rewards)
            })
        );
    }

    // Tranche whose token is the DAC's own main token (treasury-held main token as capital).
    function h_requestTrancheMain(uint256 dealSeed, uint256 amount, uint256 rewards, uint256 proposerSeed) external {
        bytes32 n = "requestTrancheMain";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 2, KIND_TREASURY);
        if (!found) return _skip(n);
        uint256 free = ctrlFree(address(mainToken));
        if (free == 0) return _skip(n);
        amount = bound(amount, 1, free / 3 + 1);
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: address(mainToken),
                i: bytes32(amount),
                data: abi.encode(bound(rewards, 0, 500_000e18))
            })
        );
    }

    // DAC-deal tranche: child capital call (created through the deal's own governance
    // over the child), then the tranche request bound to that call's hash.
    function h_dacDealTranche(uint256 dealSeed, uint256 cash, uint256 equity, uint256 rewards, uint256 proposerSeed)
        external
    {
        bytes32 n = "dacDealTranche";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 2, KIND_DAC);
        if (!found) return _skip(n);
        address proposer = _liveStaker(di, proposerSeed);
        if (proposer == address(0)) return _skip(n);
        address token = IDealCell(_deals[di].cell).fundingTranche(0).token;
        uint256 free = ctrlFree(token);
        if (free == 0) return _skip(n);
        cash = bound(cash, 1, free / 5 + 1);
        equity = bound(equity, 1, 5_000_000e18);
        rewards = proposerSeed % 3 == 0 ? 0 : bound(rewards, 1, 2_000_000e18);
        try this.x_dacDealTranche(di, proposer, token, cash, equity, rewards) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function _childCapitalCall(uint256 di, address proposer, address token, uint256 cash, uint256 equity)
        internal
        returns (bytes32 callHash)
    {
        DealInfo storage d = _deals[di];
        ProposalParams memory childProposal = ProposalParams({
            typ: DACManagementProposalType.CAPITAL_CALL,
            target: d.deal,
            i: bytes32(equity),
            data: abi.encode(token, cash, CALL_EXPIRY)
        });

        // 1. deal governance creates the child proposal (auto-creates the VOTE_DAC_PROPOSAL)
        _passDeal(
            di,
            proposer,
            ProposalParams({
                typ: CoreDealManagementType.CREATE_DAC_PROPOSAL,
                target: address(0),
                i: 0,
                data: abi.encode(childProposal)
            })
        );
        uint256 votePid = dealPropHigh[di];
        address voteProp = Deal(d.deal).getProposal(votePid);
        require(Proposal(voteProp).typ() == CoreDealManagementType.VOTE_DAC_PROPOSAL, "harness: vote prop missing");
        uint256 childPid = uint256(Proposal(voteProp).i());

        // 2. the child vote can only be cast once the child snapshot second has passed
        vm.warp(block.timestamp + 1);
        _voteDealAll(di, voteProp);
        _execDeal(di, votePid);

        // 3. execute the child proposal (permissionless)
        address childProp = IDACCell(d.childDac).getProposalVoting(childPid);
        if (!IExecutableProposal(childProp).isExecutableNow()) {
            uint256 endTime = Proposal(childProp).endTime();
            if (block.timestamp <= endTime) vm.warp(endTime + 1);
        }
        IDACCell(d.childDac).executeDACProposal(childPid);

        callHash = keccak256(
            abi.encode(
                CapitalCall({
                    treasuryToken: token, nonce: childPid, tokenRecipient: d.deal, tokenAmount: equity, cashAmount: cash
                })
            )
        );
    }

    function x_dacDealTranche(
        uint256 di,
        address proposer,
        address token,
        uint256 cash,
        uint256 equity,
        uint256 rewards
    ) external onlySelf {
        bytes32 callHash = _childCapitalCall(di, proposer, token, cash, equity);
        _passDeal(
            di,
            proposer,
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: token,
                i: bytes32(cash),
                data: abi.encode(rewards, callHash)
            })
        );
    }

    // ================================================================== //
    // Treasury deal: spends, allowances, returns                          //
    // ================================================================== //
    function _dest(uint256 seed) internal view returns (address) {
        // two thirds outside the protocol, one third back into protocol addresses
        if (seed % 3 != 0) return sinks[(seed / 3) % sinks.length];
        return perimeter[(seed / 3) % perimeter.length];
    }

    function h_directSpend(uint256 dealSeed, uint256 tokSeed, uint256 amount, uint256 destSeed, uint256 proposerSeed)
        external
    {
        bytes32 n = "directSpend";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 4, KIND_TREASURY);
        if (!found) return _skip(n);
        address token = _token3(tokSeed);
        uint256 bal = IERC20(token).balanceOf(_deals[di].treasury);
        if (bal == 0) return _skip(n);
        amount = bound(amount, 1, bal);
        address dest = _dest(destSeed);
        if (dest == address(mainToken)) return _skip(n);
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_DIRECT_SPEND,
                target: token,
                // forge-lint: disable-next-line(unsafe-typecast)
                data: abi.encode(dest, uint160(amount)),
                i: 0
            })
        );
    }

    function h_agentSpendApprove(
        uint256 dealSeed,
        uint256 agentSeed,
        uint256 tokSeed,
        uint256 destSeed,
        uint256 total,
        uint256 single,
        uint256 duration
    ) external {
        bytes32 n = "agentSpendApprove";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 4, KIND_TREASURY);
        if (!found) return _skip(n);
        _dealGov(n, di, agentSeed, _agentSpendParams(agentSeed, tokSeed, destSeed, total, single, duration));
    }

    function _agentSpendParams(
        uint256 agentSeed,
        uint256 tokSeed,
        uint256 destSeed,
        uint256 total,
        uint256 single,
        uint256 duration
    ) internal view returns (ProposalParams memory p) {
        address token = _cash(tokSeed);
        total = bound(total, 1, token == address(usdc) ? 20_000e6 : 20_000e18);
        TreasurySpendAllowance memory allowance = TreasurySpendAllowance({
            // forge-lint: disable-next-line(unsafe-typecast)
            totalAmount: uint160(total),
            // forge-lint: disable-next-line(unsafe-typecast)
            singleTxAmount: uint160(bound(single, 0, total)),
            clockLimit: 0,
            duration: bound(duration, 0, 3 days)
        });
        // wildcard destination one time in three
        address dest = destSeed % 3 == 0 ? address(0) : sinks[destSeed % sinks.length];
        p = ProposalParams({
            typ: CoreDealManagementType.APPROVE_AGENT_SPEND,
            target: token,
            i: 0,
            data: abi.encode(actors[agentSeed % 4], dest, allowance)
        });
    }

    function h_agentSpend(uint256 grantSeed, uint256 destSeed, uint256 amount) external {
        bytes32 n = "agentSpend";
        _begin(n);
        if (_spendGrants.length == 0) return _skip(n);
        Grant memory g = _spendGrants[grantSeed % _spendGrants.length];
        address treasury = _deals[g.di].treasury;
        uint256 bal = IERC20(g.token).balanceOf(treasury);
        if (bal == 0) return _skip(n);
        amount = bound(amount, 1, bal);
        address dest = g.counterparty == address(0) ? sinks[destSeed % sinks.length] : g.counterparty;
        try this.x_agentSpend(treasury, g.who, g.token, dest, amount) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_agentSpend(address treasury, address agent, address token, address dest, uint256 amount)
        external
        onlySelf
    {
        uint256 before = IERC20(token).balanceOf(treasury);
        vm.prank(agent);
        // forge-lint: disable-next-line(unsafe-typecast)
        Permit2Treasury(treasury).executeAgentSpend(token, dest, uint160(amount));
        require(IERC20(token).balanceOf(treasury) == before - amount, "harness: spend moved a wrong amount");
        if (!inPerimeter[dest]) ghostOut[token] += amount;
    }

    function h_permit2Approve(
        uint256 dealSeed,
        uint256 tokSeed,
        uint256 spenderSeed,
        uint256 amount,
        uint256 proposerSeed
    ) external {
        bytes32 n = "permit2Approve";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 4, KIND_TREASURY);
        if (!found) return _skip(n);
        _dealGov(n, di, proposerSeed, _permit2Params(di, tokSeed, spenderSeed, amount));
    }

    function _permit2Params(uint256 di, uint256 tokSeed, uint256 spenderSeed, uint256 amount)
        internal
        view
        returns (ProposalParams memory p)
    {
        address token = _cash(tokSeed);
        amount = bound(amount, 1, token == address(usdc) ? 20_000e6 : 20_000e18);
        uint256 expiration =
            block.timestamp + Deal(_deals[di].deal).votingConfig().duration + 2 days + (spenderSeed % 20 days);
        p = ProposalParams({
            typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
            target: token,
            i: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            data: abi.encode(sinks[spenderSeed % sinks.length], uint160(amount), uint48(expiration))
        });
    }

    function h_permit2Pull(uint256 grantSeed, uint256 amount) external {
        bytes32 n = "permit2Pull";
        _begin(n);
        if (_permitGrants.length == 0) return _skip(n);
        Grant memory g = _permitGrants[grantSeed % _permitGrants.length];
        address treasury = _deals[g.di].treasury;
        (uint160 allowed,) = permit2.allowance(treasury, g.token, g.who);
        uint256 bal = IERC20(g.token).balanceOf(treasury);
        if (allowed == 0 || bal == 0) return _skip(n);
        amount = bound(amount, 1, bal < allowed ? bal : allowed);
        try this.x_permit2Pull(treasury, g.token, g.who, amount) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_permit2Pull(address treasury, address token, address spender, uint256 amount) external onlySelf {
        vm.prank(spender);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.transferFrom(treasury, spender, uint160(amount), token);
        ghostOut[token] += amount;
    }

    function h_revokeSpender(uint256 dealSeed, uint256 tokSeed, uint256 whoSeed, uint256 proposerSeed) external {
        bytes32 n = "revokeSpender";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 4, KIND_TREASURY);
        if (!found) return _skip(n);
        address who = whoSeed % 2 == 0 ? sinks[whoSeed % sinks.length] : actors[whoSeed % 4];
        address counterparty = whoSeed % 3 == 0 ? address(0) : sinks[(whoSeed / 3) % sinks.length];
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({
                typ: CoreDealManagementType.REVOKE_AGENT,
                target: _cash(tokSeed),
                i: 0,
                data: abi.encode(who, counterparty)
            })
        );
    }

    function h_returnCapital(uint256 dealSeed, uint256 tokSeed, uint256 amount, uint256 proposerSeed) external {
        bytes32 n = "returnCapital";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 4, KIND_TREASURY);
        if (!found) return _skip(n);
        address token = _token3(tokSeed);
        uint256 bal = IERC20(token).balanceOf(_deals[di].treasury);
        if (bal == 0) return _skip(n);
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({
                typ: CoreDealManagementType.RETURN_CAPITAL_TO_DAC,
                target: token,
                i: 0,
                data: abi.encode(bound(amount, 1, bal))
            })
        );
    }

    function h_recoverProfits(uint256 dealSeed, uint256 tokSeed, uint256 agentSeed) external {
        bytes32 n = "recoverProfits";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 4, KIND_TREASURY);
        if (!found) return _skip(n);
        address agent = _liveStaker(di, agentSeed);
        if (agent == address(0)) return _skip(n);
        try this.x_recoverProfits(_deals[di].deal, agent, _token3(tokSeed)) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_recoverProfits(address deal, address agent, address token) external onlySelf {
        vm.prank(agent);
        TreasuryDeal(deal).recoverProfits(token);
    }

    // ================================================================== //
    // DAC deal: profits home, reinvest                                    //
    // ================================================================== //
    function h_dacReturnProfits(uint256 dealSeed, uint256 tokSeed, uint256 amount, uint256 proposerSeed) external {
        bytes32 n = "dacReturnProfits";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 4, KIND_DAC);
        if (!found) return _skip(n);
        DealInfo storage d = _deals[di];
        uint256 pick = tokSeed % 4;
        address token = pick == 3 ? d.childMain : _token3(pick);
        uint256 bal = IERC20(token).balanceOf(d.deal);
        if (bal == 0) return _skip(n);
        _dealGov(
            n,
            di,
            proposerSeed,
            ProposalParams({
                typ: CoreDealManagementType.RETURN_PROFITS, target: token, i: 0, data: abi.encode(bound(amount, 1, bal))
            })
        );
    }

    function h_dacReinvest(uint256 dealSeed, uint256 tokSeed, uint256 cash, uint256 equity, uint256 proposerSeed)
        external
    {
        bytes32 n = "dacReinvest";
        _begin(n);
        (bool found, uint256 di) = _pickDealKind(dealSeed, 2, KIND_DAC);
        if (!found) return _skip(n);
        address proposer = _liveStaker(di, proposerSeed);
        if (proposer == address(0)) return _skip(n);
        address token = _cash(tokSeed);
        uint256 bal = IERC20(token).balanceOf(_deals[di].deal);
        if (bal == 0) return _skip(n);
        cash = bound(cash, 1, bal);
        equity = bound(equity, 1, 5_000_000e18);
        try this.x_dacReinvest(di, proposer, token, cash, equity) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_dacReinvest(uint256 di, address proposer, address token, uint256 cash, uint256 equity)
        external
        onlySelf
    {
        bytes32 callHash = _childCapitalCall(di, proposer, token, cash, equity);
        _passDeal(
            di,
            proposer,
            ProposalParams({
                typ: CoreDealManagementType.REINVEST_PROFITS, target: token, i: 0, data: abi.encode(cash, callHash)
            })
        );
    }

    // ================================================================== //
    // Evaluation, rewards, close                                          //
    // ================================================================== //
    function _evalExpected(bytes4 sel) internal pure returns (bool) {
        return sel == DACErrorsLib.DealIsNotApproved.selector || sel == DACErrorsLib.NotAllowed.selector
            || sel == DACErrorsLib.NotAuthorized.selector || sel == DACErrorsLib.NotFound.selector;
    }

    function h_evaluateMock(
        uint256 dealSeed,
        uint256 callerSeed,
        uint256 shape,
        uint256 p1,
        uint256 p2,
        uint256 extendTo
    ) external {
        bytes32 n = "evaluateMock";
        _begin(n);
        uint256 nd = _deals.length;
        uint256 di = type(uint256).max;
        for (uint256 k = 0; k < nd; k++) {
            uint256 c = (dealSeed % nd + k) % nd;
            if (
                _mockEvaluators[c].length > 0 && IDealCell(_deals[c].cell).isApproved()
                    && !IDealCell(_deals[c].cell).isClosed()
            ) {
                di = c;
                break;
            }
        }
        if (di == type(uint256).max) return _skip(n);

        uint256 count = 1 + (shape % 3);
        EvaluationResult[] memory results = new EvaluationResult[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 r = uint256(keccak256(abi.encode(shape, i)));
            uint8 action = uint8(r % 8);
            // weights: convert 4/8, slash 2/8, extend 1/8, close 1/8
            if (action < 4) action = 1;
            else if (action < 6) action = 0;
            else if (action == 6) action = 2;
            else action = 3;
            uint256 pct = bound(i == 0 ? p1 : p2, 0, 12e17);
            if ((r >> 8) % 4 != 0) pct = pct / 8; // mostly small steps
            results[i] = EvaluationResult(action, pct, block.timestamp + bound(extendTo, 0, 120 days));
        }

        uint256 mockIdx = (shape >> 200) % _mockEvaluators[di].length;
        address mock = _mockEvaluators[di][mockIdx];
        // the id of the mock inside the deal's evaluator list
        uint256 evalId = _evaluatorId(di, mock);
        address caller = _holder(callerSeed);

        try this.x_evaluateMock(di, mock, evalId, caller, results) {
            _ok(n);
        } catch (bytes memory err) {
            bytes4 sel = _fail(n, err);
            if (!_evalExpected(sel)) _strict(n, err);
        }
    }

    function _evaluatorId(uint256 di, address evaluator) internal returns (uint256) {
        DealState memory st = _state(di);
        for (uint256 i = 0; i < st.evaluators.length; i++) {
            if (st.evaluators[i] == evaluator) return i;
        }
        return 0;
    }

    function x_evaluateMock(uint256 di, address mock, uint256 evalId, address caller, EvaluationResult[] memory results)
        external
        onlySelf
    {
        MockEvaluator(mock).setResults(results);
        _evaluate(di, evalId, caller);
    }

    function _evaluate(uint256 di, uint256 evalId, address caller) internal {
        DealInfo storage d = _deals[di];
        uint256 obligationsBefore = ctrlObligations();

        vm.prank(caller);
        dealManager.evaluateDeal(d.id, evalId);

        // If this evaluation closed the deal, exactly the unused reservation was released.
        if (!d.everClosed && IDealCell(d.cell).isClosed()) {
            DealState memory afterState = _state(di);
            uint256 unused = afterState.rewardsLimit - afterState.rewardsUnlocked;
            require(obligationsBefore - ctrlObligations() == unused, "harness: close released a wrong reservation");
            ghostReleasedAtClose[di] = unused;
        }
        _noteClosed(di);
    }

    function h_evaluate(uint256 dealSeed, uint256 callerSeed, uint256 evalIdSeed) external {
        bytes32 n = "evaluate";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 2);
        if (!found) return _skip(n);
        DealState memory st = _state(di);
        uint256 evalId = evalIdSeed % st.evaluators.length;
        address caller = _holder(callerSeed);
        try this.x_evaluate(di, evalId, caller) {
            _ok(n);
        } catch (bytes memory err) {
            bytes4 sel = _fail(n, err);
            if (!_evalExpected(sel)) _strict(n, err);
        }
    }

    function x_evaluate(uint256 di, uint256 evalId, address caller) external onlySelf {
        _evaluate(di, evalId, caller);
    }

    function h_claim(uint256 dealSeed, uint256 actorSeed) external {
        bytes32 n = "claim";
        _begin(n);
        uint256 nd = _deals.length;
        for (uint256 k = 0; k < nd; k++) {
            uint256 di = (dealSeed % nd + k) % nd;
            address[] storage st = _stakers[di];
            uint256 ns = st.length;
            for (uint256 j = 0; j < ns; j++) {
                address a = st[(actorSeed % ns + j) % ns];
                uint256 claimable = cellClaimable(_deals[di].cell, a);
                if (claimable == 0) continue;
                try this.x_claim(di, a, claimable) {
                    _ok(n);
                } catch (bytes memory err) {
                    _fail(n, err);
                    // Unlocked rewards must always be claimable.
                    _strict(n, err);
                }
                return;
            }
        }
        _skip(n);
    }

    function x_claim(uint256 di, address a, uint256 claimable) external onlySelf {
        uint256 before = mainToken.balanceOf(a);
        uint256 obligationsBefore = ctrlObligations();
        vm.prank(a);
        IDealCell(_deals[di].cell).claimMainToken(0);
        require(mainToken.balanceOf(a) == before + claimable, "harness: claim paid a wrong amount");
        require(obligationsBefore - ctrlObligations() == claimable, "harness: claim released a wrong obligation");
    }

    function h_claimPool(uint256 dealSeed, uint256 agentSeed) external {
        bytes32 n = "claimPool";
        _begin(n);
        uint256 nd = _deals.length;
        for (uint256 k = 0; k < nd; k++) {
            uint256 di = (dealSeed % nd + k) % nd;
            DealInfo storage d = _deals[di];
            if (cellClaimable(d.cell, d.deal) == 0) continue;
            address agent = _liveStaker(di, agentSeed);
            if (agent == address(0)) continue;
            try this.x_claimPool(di, agent) {
                _ok(n);
            } catch (bytes memory err) {
                _fail(n, err);
                _strict(n, err);
            }
            return;
        }
        _skip(n);
    }

    function x_claimPool(uint256 di, address agent) external onlySelf {
        DealInfo storage d = _deals[di];
        vm.prank(agent);
        if (d.kind == KIND_TREASURY) TreasuryDeal(d.deal).claimDealRewardPool(0);
        else DACDeal(d.deal).claimDealRewardPool(0);
    }

    function h_withdrawCapital(uint256 dealSeed, uint256 agentSeed) external {
        bytes32 n = "withdrawCapital";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 4);
        if (!found) return _skip(n);
        address agent = _liveStaker(di, agentSeed);
        if (agent == address(0)) return _skip(n);
        try this.x_withdrawCapital(di, agent) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_withdrawCapital(uint256 di, address agent) external onlySelf {
        vm.prank(agent);
        DealCellLike(_deals[di].cell).withdrawCapital();
    }

    function h_forceReturn(uint256 dealSeed, uint256 holderSeed) external {
        bytes32 n = "forceReturn";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 0);
        if (!found) return _skip(n);
        address holder = _holder(holderSeed);
        if (mainToken.balanceOf(holder) == 0) return _skip(n);
        bool pastDeadline = block.timestamp > IDealCell(_deals[di].cell).dealDeadline();
        try this.x_forceReturn(di, holder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
            // Past the deal deadline the DAC's clawback must always work.
            if (pastDeadline) _strict(n, err);
        }
    }

    function x_forceReturn(uint256 di, address holder) external onlySelf {
        vm.prank(holder);
        dealManager.forceReturnCapital(_deals[di].id);
    }

    function h_closeByAgent(uint256 dealSeed, uint256 agentSeed) external {
        bytes32 n = "closeByAgent";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 2);
        if (!found || _stakers[di].length == 0) return _skip(n);
        address a = _stakers[di][agentSeed % _stakers[di].length];
        try this.x_closeByAgent(di, a) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_closeByAgent(uint256 di, address a) external onlySelf {
        vm.prank(a);
        DealCellLike(_deals[di].cell).closeDeal();
        _noteClosed(di);
    }

    function h_recoverDeal(uint256 dealSeed, uint256 liquidatorSeed, uint256 stake) external {
        bytes32 n = "recoverDeal";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 3);
        if (!found) return _skip(n);
        ProposalParams memory p = ProposalParams({
            typ: DACManagementProposalType.RECOVER_DEAL,
            target: _actor(liquidatorSeed),
            i: bytes32(bound(stake, 1, 50_000)),
            data: abi.encode(_deals[di].id)
        });
        try this.x_passDac(p, founder) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    // ================================================================== //
    // Extra evaluators                                                    //
    // ================================================================== //
    function h_addMockEvaluator(uint256 dealSeed) external {
        bytes32 n = "addMockEvaluator";
        _begin(n);
        (bool found, uint256 di) = _pickDeal(dealSeed, 2);
        if (!found || _state(di).evaluators.length >= 3) return _skip(n);
        try this.x_addMockEvaluator(di) {
            _ok(n);
        } catch (bytes memory err) {
            _fail(n, err);
        }
    }

    function x_addMockEvaluator(uint256 di) external onlySelf {
        DealInfo storage d = _deals[di];
        bytes memory evaluatorConfig =
            abi.encode(MOCK_EVALUATOR_SELECTOR, abi.encode(address(this), new EvaluationResult[](0)));

        uint256 before = _state(di).evaluators.length;
        _passDac(
            ProposalParams({
                typ: DACManagementProposalType.ADD_EVALUATOR,
                target: address(0),
                i: 0,
                data: abi.encode(d.id, address(mockModule), evaluatorConfig)
            }),
            founder
        );

        // the kernel opened a PERMIT_EVALUATOR_ADD proposal for the agents to ratify
        _syncDealProps(di);
        uint256 pid = dealPropHigh[di];
        _voteDealAll(di, Deal(d.deal).getProposal(pid));
        _execDeal(di, pid);

        DealState memory st = _state(di);
        require(st.evaluators.length == before + 1, "harness: evaluator not added");
        _mockEvaluators[di].push(st.evaluators[before]);
        _addPerimeter(st.evaluators[before]);
    }

    // ================================================================== //
    // Selector list for the invariant runner                              //
    // ================================================================== //
    function handlerSelectors() external pure returns (bytes4[] memory s) {
        s = new bytes4[](53);
        uint256 i;
        s[i++] = this.h_warp.selector;
        s[i++] = this.h_warpLong.selector;
        s[i++] = this.h_mainTransfer.selector;
        s[i++] = this.h_mainDelegate.selector;
        s[i++] = this.h_mainBurn.selector;
        s[i++] = this.h_donateCash.selector;
        s[i++] = this.h_donateMain.selector;
        s[i++] = this.h_setPrice.selector;
        s[i++] = this.h_capitalCallCreate.selector;
        s[i++] = this.h_capitalCallFulfil.selector;
        s[i++] = this.h_capitalCallReplay.selector;
        s[i++] = this.h_mintAgent.selector;
        s[i++] = this.h_revokeAgent.selector;
        s[i++] = this.h_revokeFromCell.selector;
        s[i++] = this.h_treasuryMintMain.selector;
        s[i++] = this.h_treasuryBurnMain.selector;
        s[i++] = this.h_voteDac.selector;
        s[i++] = this.h_execDac.selector;
        s[i++] = this.h_passDacPending.selector;
        s[i++] = this.h_dividendCreate.selector;
        s[i++] = this.h_dividendClaim.selector;
        s[i++] = this.h_dividendClaimForged.selector;
        s[i++] = this.h_dividendSweep.selector;
        s[i++] = this.h_recoverTreasury.selector;
        s[i++] = this.h_recoverERC20.selector;
        s[i++] = this.h_createDeal.selector;
        s[i++] = this.h_invite.selector;
        s[i++] = this.h_stake.selector;
        s[i++] = this.h_approveDeal.selector;
        s[i++] = this.h_voteDealProp.selector;
        s[i++] = this.h_execDealProp.selector;
        s[i++] = this.h_passDealPending.selector;
        s[i++] = this.h_unstake.selector;
        s[i++] = this.h_addStake.selector;
        s[i++] = this.h_strikeOut.selector;
        s[i++] = this.h_toggle.selector;
        s[i++] = this.h_requestTranche.selector;
        s[i++] = this.h_requestTrancheMain.selector;
        s[i++] = this.h_dacDealTranche.selector;
        s[i++] = this.h_directSpend.selector;
        s[i++] = this.h_agentSpendApprove.selector;
        s[i++] = this.h_agentSpend.selector;
        s[i++] = this.h_permit2Approve.selector;
        s[i++] = this.h_permit2Pull.selector;
        s[i++] = this.h_revokeSpender.selector;
        s[i++] = this.h_returnCapital.selector;
        s[i++] = this.h_recoverProfits.selector;
        s[i++] = this.h_dacReturnProfits.selector;
        s[i++] = this.h_dacReinvest.selector;
        s[i++] = this.h_evaluateMock.selector;
        s[i++] = this.h_evaluate.selector;
        s[i++] = this.h_claim.selector;
        s[i++] = this.h_claimPool.selector;
        assembly {
            mstore(s, i)
        }
    }

    function handlerSelectorsB() external pure returns (bytes4[] memory s) {
        s = new bytes4[](16);
        uint256 i;
        s[i++] = this.h_withdrawCapital.selector;
        s[i++] = this.h_forceReturn.selector;
        s[i++] = this.h_closeByAgent.selector;
        s[i++] = this.h_recoverDeal.selector;
        s[i++] = this.h_addMockEvaluator.selector;
        s[i++] = this.h_profit.selector;
        s[i++] = this.h_vetoDealProp.selector;
        s[i++] = this.h_exitAll.selector;
        s[i++] = this.h_dealVotingConfig.selector;
        s[i++] = this.h_dacVotingConfig.selector;
        assembly {
            mstore(s, i)
        }
    }
}

interface IChallengeable {
    function isChallengeable() external view returns (bool);
    function dacChallengeProposal() external view returns (address);
}

interface DealCellLike {
    function closeDeal() external;
    function withdrawCapital() external;
}
