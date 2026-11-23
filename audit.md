# DAC Cloud Contracts — Security Review and Operating Guide

| | |
|---|---|
| **Date** | 17 November 2026 |
| **Revision** | Branch `develop`. The review started at `a8e80ee` and covers the tree this document is committed with. |
| **Scope** | `src/`: 92 Solidity files, 11,815 lines. Deployment scripts, configuration and CI reviewed for release readiness. |
| **Target** | Base mainnet; any Cancun-level EVM chain |
| **Toolchain** | solc 0.8.38, EVM `cancun`, optimizer on (1 run), legacy pipeline; Foundry 1.5.1; OpenZeppelin Contracts 5.7.0 |
| **Reviewer** | Claude Fable 5.2, automated review: one full read of `src/` and seven independent passes (governance economics, treasury accounting, deal lifecycle and evaluators, core module, existing-token path with a whole-codebase access-control sweep, release readiness, stateful fuzzing), followed by a hardening round on the same tree |
| **Tests** | `forge test`: 338 pass. 259 project tests, 78 review tests in `test/audit/pass-2026-11/`, and a stateful invariant suite in `test/invariant/`. |

---

## 1. Summary

The contracts were reviewed against an adversary who has capital and no role: someone who can buy, borrow, wrap and unwrap tokens, hold a position for exactly one block, deploy contracts, tokens and whole DACs, and order transactions inside a block. Agents, staked-agent majorities, capital-call recipients, module authors and the oracle publisher were each played as adversaries in turn.

**What the protocol guarantees** is set out in section 5. In short: no account without a governance mandate moves treasury assets, mints main tokens, or draws more reward than a deal's approved limit; every proposal measures vote weights and its quorum base at one past instant; every governance deadline follows from configured durations; capital used to open a proposal stays locked for the length of the vote; and no module, token or evaluator can stop a deal from being evaluated, closed and its capital returned.

**What the protocol leaves to its users** is set out in sections 6 to 8. A DAC is deliberately given few structural prohibitions and many parameters. It cannot pause or override a live deal, it does not force a minimum electorate, and it does not delay execution. In exchange it lets every DAC decide how much commitment governing costs and how much room agents get. Those choices have consequences that a DAC, its holders, its agents and its integrators should know before value depends on them. Section 6 states them as operating guidance, section 7 gives the measured limits behind them, and section 8 lists the design positions they follow from.

Section 9 is the record of the review itself: every scenario it reproduced, and whether the release answers it in code (with the regression test that pins it) or in this guide.

---

## 2. Scope

**Kernel** (`src/kernel/`): `DACFactory`, `DACCell`, `DealManager`, `DealCell`, `Deal`, `ModuleRegistry`, `ModuleFactory`; asset controllers (`NativeAssetController`, `ExistingTokenAssetController`); governance (`Proposal`, `DACManagementProposal`, `DealManagementProposal`, `HybridDACManagementProposal`, `NativeGovernanceSchema`, `HybridGovernanceSchema`, `BasicGovernanceOracle`); tokens (`MainToken`, `WrappedMainToken`, `AgentToken`, `StakedAgent`, the `VoteLock` mixin); linked libraries (`DACCellGovernanceLib`, `DealCellGovernanceLib`, `DACDeployment`, `VotingConfigLib`, `MathLib`); the ERC-1967 proxy and every factory.

**Core module** (`src/modules/core/`): `CoreModuleFactory`, `DACDeal`, `AgentDeal`, `TreasuryDeal`, `Permit2Treasury`, `MilestoneBasedEvaluator`, `RevenueBasedEvaluator`, the deal-proposal factory and all deal and evaluator factories.

**Release surface**: `script/`, `foundry.toml`, `foundry.lock`, `.github/workflows/test.yml`, `deployments/84532/`, and `docs/`.

**Out of scope**: OpenZeppelin and Uniswap Permit2 internals (Permit2 behaviour was exercised against the canonical runtime bytecode), off-chain services (oracle publisher, indexer, SDK, front end), and third-party modules.

---

## 3. Method

1. **Full read.** Every line of `src/`, including the libraries reached by `DELEGATECALL`, with `msg.sender` and `address(this)` resolved per call frame.
2. **Independent passes.** Seven separate reviews of the code, each from its own angle. Every scenario was re-derived from the source and reproduced by a test before it entered the record.
3. **Access-control enumeration.** Each state-mutating external function was listed from the compiled ABIs with its enforced gate and intended caller.
4. **Accounting map.** Each function that moves tokens or mints was mapped to the variable that bounds it, and each bucket (free, committed, obligations, invested, returned, reward limit / unlocked / paid) was attacked for conservation.
5. **Economic modelling.** Capital, holding time and ordering needed to pass, block or stall each proposal class under the default configuration, on every voting path.
6. **Reproduction, then regression.** Every scenario of consequence was reproduced by a Foundry test through the real factories. Where the release changes the behaviour, the test now replays the scenario and asserts that it fails; where the behaviour is intended, the test pins it as documented. Gas figures were measured with cold storage against the Base per-transaction limit.
7. **Fuzzing.** A handler-based invariant suite over a native DAC with deals and evaluators (section 11), and every fuzz test in the repository at 20,000 runs.
8. **End to end.** The full deployment and seed pipeline (`script/seed-all.sh`: protocol, native DAC, existing-token DAC, treasury deals, oracle-primary and fallback votes, child-DAC flows) was run against a local chain on the reviewed tree.

---

## 4. Trust model

| Actor | Can | Cannot |
|---|---|---|
| **Protocol deployer** | Nothing after deployment. Factories are ownerless and have no setters. | Upgrade, pause, or touch any DAC. |
| **DAC deployer** | Choose every parameter of a DAC, including, for existing-token DACs, the governance oracle. | Act on the DAC afterwards except as a holder. Take a DAC address another deployer computed. |
| **Founder** | Fulfil the root capital call and so be the first voter. | Anything a holder with the same balance cannot. |
| **Main-token holders** | Everything, by vote. Any holder may evaluate a deal after its evaluation deadline and return its capital after its deal deadline. | Stop, pause or close a live deal before its deadlines (by design). Vote with tokens acquired in or after a proposal's creation second. |
| **Agents** | Propose deals. Evaluate a deal they hold stake in at any time, and any deal after its evaluation deadline. | Receive funding or rewards without a DAC vote. |
| **Staked agents of a deal** | Control the deal's capital within the deal module's rules. Funding is at risk once approved (by design). | Draw rewards beyond the DAC-approved limit; mint. |
| **Module authors** | Define what their deals and evaluators do. Approved by high-quorum vote. | Act outside their own deals. Stop a deal from closing or its capital from being returned. Take an address that is not their deal out of the electorate. |
| **Oracle publisher** (existing-token, oracle-primary) | Decide the primary-phase electorate: Merkle weights and the total are not validated on-chain. Deactivate any DAC on a shared oracle, irreversibly. | Affect native DACs. |
| **Legal wrapper** | Be the required executor of `TOGGLE_DIVIDENDS`, `REMOVE_MODULE` and `RECOVER_DEAL` once set, and so withhold them. | Act without a passed proposal. |
| **Sequencer** | Shift `block.timestamp` within protocol tolerance and order transactions. Every snapshot and deadline is a timestamp. | Not modelled further. |

Tokens assumed: standard ERC-20 behaviour. What non-standard tokens do is covered in 6.5.

---

## 5. Security properties

Each property below was checked by reading, by test, or by both. Tests named `test_REG_*`, `test_VERIFY_*` and `test_CONTROL_*` are in `test/audit/pass-2026-11/`.

**Access control.** 310 state-mutating external functions across 46 deployable contracts, 25 public library entry points and 26 initializers were enumerated with their gates; none lacks the caller gate it should have. Every implementation disables initializers. All four proposal types bind `consumeExecution` to their executor. The cross-deal guards inside the linked libraries resolve correctly under `DELEGATECALL`. Wiring that is set once stays set: a token's manager and controller, a deal's cell, a cell's bootstrap (`test_REG_L15_*`).

**Roles after deployment.** `MainToken`: only the asset controller mints, and no admin exists. `AgentToken`: the `DACCell` mints, the `DACCell` and `DealManager` burn, no admin. `StakedAgent`: its `DealCell` only, no admin. `WrappedMainToken`: the admin is the `DACCell`, which has no path to use it after initialisation. `DACFactory` and `CoreModuleFactory` are ownerless.

**Custody and accounting.**
1. Each funding token is conserved hop by hop (controller → `DealManager` → cell → deal and back), with nothing left in transit contracts and recorded treasury equal to real balance.
2. `rewardsPaid ≤ rewardsUnlocked ≤ rewardsLimit` under random conversions and tranche rescales; evaluation never reverts on the clamp; after all claims obligations are zero.
3. Native mint headroom: `totalSupply + obligations ≤ maxSupply` across all four mint paths, so a reward claim cannot hit the cap.
4. Existing-token reserve: reward limits are committed from free balance, paid by transfer, released once at close; no other spender can draw on the committed part; the wrapper stays 1:1 backed.
5. `recoverERC20`, `recoverTreasury` and `syncTreasury` only add free balance.
6. Dividends: one root per proposal, leaves that cannot collide with inner nodes, cumulative claims capped at the committed amount, a fixed claim window, and a sweep that can only return the remainder to the free treasury (`test_REG_L14_*`).
7. Stake backing: a cell's agent-token balance equals its `StakedAgent` supply outside recovery; agent and stake tokens cannot enter treasury paths.
8. A dormant module cannot freeze claims, close or capital return.

**Voting.**
1. *One past timepoint.* A proposal reads vote weights and its quorum base at the second before its creation, on DAC proposals (native and hybrid primary) and on deal proposals. Nothing issued, released or staked in the creation second, before or after the proposal in that second, votes on it or counts in its base (`test_REG_H02_*`; invariant F1).
2. *No flash-loan governance.* All three vote tokens checkpoint by timestamp; a balance acquired and returned inside one transaction neither votes nor qualifies its holder to open a proposal or a challenge (`test_REG_M09_tokensHeldForOneCallDoNotQualify`).
3. *Capital behind a proposal stays.* The votes that qualify a creator are locked on it until the proposal's voting can no longer be running; for a deal challenge that is at least 0.1% of the votable supply (`test_REG_M09_*`). A locked amount cannot be transferred, burned, unwrapped or re-delegated, by the account or by its delegators, and a lock never exceeds the votes the account holds (invariant V1).
4. *Configured retention is enforced.* In an existing-token DAC, a wrapped vote counts only if the configured share of its weight is still delegated to the voter, and that share stays locked for the configured period (`test_REG_C01_*`).
5. *Fixed schedule.* Voting periods, the fallback snapshot and execution windows follow from configured durations and the oracle's publication time. A proposal that passes by timeout is executable for `executionValidityDuration` from the end of its voting and not after, whether or not anyone touched it (`test_REG_M02_*`). A snapshot the oracle published in time is honoured without any activation call, and stays binding if the oracle is switched off later: leaving primary voting then takes an explicit emergency fallback with a fresh, public warmup. An oracle that stops answering cannot freeze a proposal (`test_REG_H01_*`).
6. *No same-transaction governance.* Voting on a native or deal proposal opens the second after its creation, so creation, resolution and execution never share a transaction (`test_REG_H02_votingOpensTheSecondAfterCreation`).
7. Controlled addresses cannot delegate or be delegated to; a third-party `wrapTo` does not auto-delegate. An address is taken out of the electorate only if it is a never-delegated contract, and the deal a module names must be bound to the cell being created (`test_REG_M07_*`).
8. No double execution. Unknown proposal types are refused at creation, malformed data reverts at execution, configuration updates are validated at both, and every `VotingConfig` is held to sanity bounds wherever it is set (`test_REG_L13_*`). In-flight proposals are unaffected by later configuration or oracle changes. A phase with no electorate resolves rejected.

**Deal lifecycle.**
1. A stake is never zero and a deal's holder list has at most 100 entries, so slashing, reward allocation and close fit in one transaction with margin (`test_REG_H03_*`; section 7.2).
2. Before a deal's evaluation deadline only holders of stake in that deal can evaluate it; afterwards any holder or agent of the DAC can (`test_REG_M06_*`).
3. Evaluators measure from the deal's approval: no revenue cycle runs, and no price baseline is taken, while the DAC is still voting (`test_REG_M04_*`). The activation hook that takes those baselines has no fixed gas limit and cannot be left out by underfunding the approval: a hook that ran out of gas, directly or in a nested call, reverts the approval, while a hook that fails for a reason of its own is reported and skipped (`test_REG_activationHook_*`).
4. A module's close hook cannot stop a close: it runs with a guaranteed stipend and its failure is reported, not propagated (`test_REG_L04_*`).
5. Capital returns token by token: one funding token that reverts, or burns all the gas it is given, costs its own turn and nothing else (`test_REG_M08_*`).
6. A caller cannot make a hook or a token's turn fail by underfunding the transaction: where a call has a stipend the kernel guarantees it, and where it has none (evaluator activation) a failure for lack of gas reverts the whole transaction.

**Capital calls.** A governance capital call needs the high quorum, remains blockable, states an expiry, and can be neither read nor fulfilled after it (`test_REG_M03_*`, `test_REG_L03_*`).

**Deployment.** A DAC's address commits to its deployer; an address a deployer computed cannot be taken by anyone else (`test_REG_L01_*`). A deferred-birth cell rejects every value entry point until started, and `startDAC` is bound to the role, the cell and the configuration hash.

**Reentrancy.** Controller mutations are reachable only behind `DACCell`'s guard or `DealManager`'s `mintMain` and `onDealClosed`. Wrap and unwrap are guarded and use balance deltas. Every foreign-token site uses `SafeERC20`, `forceApprove`, or an isolated gas-capped call.

**Signatures.** `DACDeal.isValidSignature` returns the magic value only for a stored snapshot.org payload whose reconstruction matches the queried hash; the snapshot domain cannot equal a Permit2, EIP-2612, Seaport or CoW domain separator. `Permit2Treasury` exposes no ERC-1271, so Permit2 `permit` and `permitTransferFrom` against it revert, and `REVOKE_AGENT` zeroes the named spender's Permit2 allowance (`test_VERIFY_realPermit2_signaturePathsClosed_revokeEffective`).

---

## 6. Operating guide

### 6.1 Every DAC

**Quorum is a share of the votable supply, not of the votes cast.** Supply that sits undelegated or in contracts that do not vote (pools, bridges, exchange wallets) counts against every quorum. `MainToken` does not auto-delegate. A DAC whose delegated supply falls below its default quorum can pass nothing, including the change that would lower the quorum. Track delegated supply against quorum and treat a shrinking margin as an incident.

**A DAC proposal executes as soon as it resolves.** A vote that reaches the early-pass threshold makes the proposal executable in the same block. The protection against a surprise is the threshold itself: the high quorum, and blocking on the proposal types that carry it. Choose `blockingPercent` knowing that a proposal with blocking resolves early only when `yes ≥ 100% − blockingPercent` of the electorate.

**Qualification is a commitment, and zero means none.** With `qualification` at zero, any holder with one unit of delegated votes can open any proposal and nothing is locked. Every non-zero value both raises the bar and locks that share of the votable supply on the creator for the voting period. A DAC past its bootstrap should set it deliberately. Delegators share their delegate's locks: tokens delegated to an account that opens proposals (or, in an existing-token DAC, votes under retention) cannot always be withdrawn at once. That includes a DAC treasury or a deal treasury that delegates the governance token of another DAC it holds: choose such a delegate as carefully as a custodian.

**Execution validity is one day by default.** A passed proposal that is not executed within `executionValidityDuration` of its resolution expires. That is tight for executions that need the legal wrapper; a DAC that relies on one should lengthen it.

**Capital calls are options.** A capital call lets its recipient buy at a fixed price until the call's expiry, and the recipient chooses whether and when. Vote on the expiry as part of the price. Until it expires, a call is filled by whoever sends the transaction, with the recipient's funds: a recipient approves the asset controller for the exact amount when it means to pay, never as a standing allowance (`test_NOTE_M03_*`).

**Dividends expire.** A payout can be claimed for 365 days. After that anyone can release the remainder back to the free treasury, and late claims are refused. Publish the claim deadline with the payout.

**Proposal classes.** High quorum: `MINT_MAIN_TOKENS`, `CAPITAL_CALL`, the four `UPDATE_*` types, `UPDATE_LEGAL_WRAPPER`, `DIVIDEND_PAYOUT`, `ADD_MODULE`, `REMOVE_MODULE`, `TOGGLE_DIVIDENDS`. Blockable: `CAPITAL_CALL`, `APPROVE_OFFCHAIN_ACTION`, `REVOKE_AGENT_TOKENS`, `APPROVE_DEAL`, `APPROVE_TRANCHE`, `ADD_EVALUATOR`, `BURN_MAIN_TOKENS`, `DELEGATE_VOTE_RIGHTS`. Default quorum and not blockable: `MINT_AGENT_TOKENS`, `RECOVER_DEAL`, `DEAL_MESSAGE`, `CAST_VETO_DEAL`. In an existing-token DAC, `blockingOnHighQuorum` adds blocking to the high-quorum types and `blockingOnAllProposals` to everything.

### 6.2 Existing-token DACs

An existing-token DAC has two electorates. In the primary path the oracle's Merkle snapshot of the underlying token votes together with wrapped holders. In the fallback path (the oracle missed its deadline or was deactivated, or the DAC runs wrapped-only) **only wrapped tokens vote**, and the electorate is whoever is wrapped at one second that is public for the whole warmup.

**The wrapped float is the electorate that matters.** Let `W` be the honest wrapped supply and `A` the wrapped position of someone who acquires or borrows tokens for the snapshot. In a fallback vote with quorum `q` and blocking `b`:

- a proposal without blocking passes in the first block of voting when `A ≥ q/(1−q) × W` (with a 50% quorum: `A ≥ W`);
- a proposal with blocking passes at once only when `A ≥ (1−b)/b × W` (with 20% blocking: `A ≥ 4W`); below that it stays open for the whole fallback period and is rejected if the holders who vote no reach `b × (W + A)`.

A DAC with 2% of its supply wrapped, 12% of it in the treasury, and 5.5% of it available to borrow is exposed: the borrower is 73% of the fallback electorate. Proposals without blocking pass at once. Proposals with blocking do not, but they stay open, and three quarters of the wrapped float has to vote no to reject them. The same DAC with 6% wrapped is not carried by that position on any path.

What a DAC does about it, in order of weight:

1. **Keep a wrapped float in proportion to what can be borrowed or bought.** Long-term holders wrapping a standing position is the defence that works without anyone reacting.
2. **Turn on `blockingOnAllProposals`** while the float is thin. Every proposal then needs `(1−b)` of the electorate to resolve early, and holders get the full fallback period to reject it.
3. **Lengthen the warmup as the DAC matures.** The default of four hours suits a bootstrap, when holders are few and close. The warmup is the window in which holders can wrap in response to a proposal (`test_NOTE_C01_warmupIsTheDefenceWindow_*`): a mature DAC with dispersed holders needs days, not hours. Alert holders when a warmup starts, and derive that from the schedule rather than from an event: a proposal whose oracle deadline passes without a publication is in warmup from that second, whether or not anyone has touched it yet.
4. **Set vote retention.** With `voteRetentionPercent` at zero a fallback vote belongs to whoever was wrapped at the snapshot second, for that second only (`test_NOTE_C01_noRetention_*`). With retention set, the voter must still hold the share when it votes, and with `voteLockDuration` set that share stays wrapped for the period: the capital that decides a vote is still in the DAC, visible and immovable, weeks or months later.

Retention and lock price an attempt; they do not prevent one. Someone who buys tokens to pass a proposal carries them through the lock at whatever price the outcome leaves. Someone who borrows the token itself is hedged against that price and pays the carry: interest on the position for the length of the lock. Set the lock against that arithmetic (borrow cost over the lock compared with what a fallback vote can move), and do not treat it as a substitute for a float.

**Oracle-primary DACs need a wrapped float too.** Holders of the underlying token vote by Merkle proof and have no reason to wrap, so the fallback electorate of such a DAC can be close to empty; if the oracle misses, a vote belongs to whoever is wrapped (`test_NOTE_C01_oracleMiss_*`). The measures above apply. Proposal rights are also measured in wrapped votes: holders of the underlying alone cannot open proposals, and anyone with a wrapped position can.

**The reference oracle is reference code.** `BasicGovernanceOracle` publishes one snapshot per proposal, once; a mistaken publication cannot be corrected. Its publisher role is global to the instance: a publisher onboarded for one DAC can publish for, or irreversibly deactivate, any other DAC on it. Merkle weights are not bounded by the published total, and the total is not bounded by the underlying supply. Run one oracle instance per DAC, exclude the wrapper's own underlying balance from the tree and the total, and expect a production oracle to replace the reference through `UPDATE_GOVERNANCE_ORACLE`. Deactivating an oracle does not move proposals by itself: a snapshot it published in time stays binding, so after a deactivation call `triggerEmergencyFallback()` on every open proposal that has one. Each then restarts with a full warmup. Vote retention binds wrapped votes only; what a Merkle vote requires of its holder is the oracle's snapshot policy.

### 6.3 Deals

**Funding an approved deal is a transfer of control.** Once the DAC approves a deal, its capital is in the agents' hands within the module's rules, until the deal's deadlines. The DAC cannot pause, override or close it earlier. What bounds the outcome is the stake at risk, the evaluator, and the reward limit, all fixed at approval. Read the deal's parameters (`initParams`) before voting, including `dealTarget` and any factory address in the deal configuration: they are not validated against a canonical list.

**A deal that is not meant as an open pool sets a whitelist or a minimal stake.** With the whitelist off and `minimalStake` at zero, any agent of the DAC joins for one unit of stake: it then evaluates the deal at will, takes a seat on the holder list (100 per deal, for the deal's lifetime) and votes its unit in deal governance. Before approval, an invited agent can stake any amount and cannot be un-invited.

**Give every deal a way to end.** A deal ends when an evaluator closes it (a closing milestone, `milestoneType == 1`, or `autoClose` at full unlock in the revenue evaluator), when its rewards are fully converted, or when its stake is fully slashed. A deal whose evaluator can reach none of these stays open after its deadline: its reward reservation is not released and its last staker cannot leave. Require a closing milestone at approval.

**Deadlines belong to the deal's terms.** `approveDeadline` should leave room for the DAC's voting period; the kernel does not check it, and a proposer whose approval deadline has already passed can withdraw the initial stake while the approval vote is still open. A deal's `minimalStake` above the DAC's `minInitialAgentStake` makes creation revert.

**The kernel adds no delay between a deal vote and its execution.** A staked-agent proposal is executable as soon as it resolves, which can be the block after it was created, and a DAC challenge can only attach to a proposal that is still pending (`test_NOTE_M01_*`). This is what lets a one-day trade deal exist under week-long DAC governance. Two consequences follow. A deal action that should leave the DAC time to react carries its own delay in the module. And a staker majority can vote itself out of a deal (`PERMIT_UNSTAKE`) ahead of an evaluation: stake is at risk for as long as the deal's own stakers keep it there, which is the reason to size `minimalStake` and to keep co-stakers meaningful.

**Slashing takes the stake, not the permissions a deal already granted.** A treasury deal's standing agent allowances, Permit2 allowances and proposals opened before a slash keep working after the stake is gone (`test_NOTE_M05_spendRightsOutliveTheStake_*`). The DAC's answer is the capital return, which any holder can call the moment a deal is closed with no stake left: send it in the same transaction as the evaluation that closes the deal, and nothing remains to spend (`test_NOTE_M05_evaluateThenReturnCapital_*`). A governance-appointed liquidator handles whatever is not a funding token.

**An evaluator can keep its own deal from being approved.** The activation hook runs without a gas limit, and a hook that never finishes inside a transaction makes the approval revert every time. Nothing has left the treasury at that point and stakers recover their stake after the approval deadline, so the cost falls on the deal that chose the evaluator. An `EvaluatorActivationSkipped` event at approval means the evaluator had no hook or its hook reverted: it then takes its references at its first evaluation, which the deal's stakers time.

**Evaluator configuration is the DAC's to check.** Curve arrays are not bounded in length, and a very long curve makes an evaluation expensive (section 7.3); `duration` may be one second; a milestone's `timestamp + extension` must not overflow. Each needs a DAC-approved configuration, and a deal linter should flag them. An evaluation with a full holder list fits ten slash or convert results, and five when it also closes the deal (section 7.2); a milestone evaluator produces up to three results per milestone that falls due, so milestones that can fall due together should be few, and a closing milestone should not share its date with several others.

**Evaluators can be added from any approved module.** `ADD_EVALUATOR` whitelists an evaluator for a deal and the deal's agents ratify it; the module is checked when the DAC votes, not again at ratification, so an evaluator from a module removed in between still deploys. That keeps custom evaluators addable, including the one a DAC uses to wind a deal down.

**Reward shares follow the stake held at the evaluation.** A staker who adds stake before a paying evaluation shares in it by its stake at that moment. Deals that should weight by time at risk need a module that does.

**`DACDeal`.** A tranche request checks the child capital call's token, cash amount and recipient, not the equity it buys: read the child call before approving a tranche. A deal's stakers operate the child DAC (`CREATE_DAC_PROPOSAL` is default-quorum and not challengeable). Child equity goes home when the deal closes; equity the deal has vote-locked in the child follows through `returnChildEquity()` when the lock ends. Pick a child capital call's expiry beyond the home DAC's approval of the tranche that funds it.

**`AgentDeal`.** Bind an agent deal only to a host DAC whose governance is trusted: host addresses are read from the host on each call. At close, host agent tokens, host stake and claimed host rewards stay on the deal until its stakers or a liquidator route them home.

**Deal reward pools.** A deal's own reward pool (`DACDeal`, `TreasuryDeal`) is claimed by a staker of the deal. After every staker has left, the pool and its reservation wait for a liquidator.

**`TreasuryDeal`.** `APPROVE_AGENT_SPEND` and `APPROVE_PERMIT2_SPEND` move value at the default quorum, while `APPROVE_DIRECT_SPEND` needs the high quorum. Allowance fields are taken as given (`duration = 0` allows one spend per second), an exhausted per-destination allowance falls through to the wildcard, and `REVOKE_AGENT` clears one `(agent, token, counterparty)` key at a time. A treasury deal can delegate the votes of vote tokens it holds (`DELEGATE_VOTE_RIGHTS`, blockable). The home DAC's own token cannot be delegated from a deal, but when the token is another DAC's governance token, the delegate's vote locks bind the treasury's balance, and a capital return skips that token until the lock ends.

### 6.4 Modules

Approving a module is a high-trust decision: a module defines what its deals do with the capital the DAC gives them. The kernel bounds what a module can do *outside* its deals (section 5), not what it does inside them. Audit a module's deals and evaluators before `ADD_MODULE`. Module authors: see `docs/module-development.md` for the hook guarantees (close hook stipend, per-token capital return, activation hook, `getCell()`), and build any reaction window an action deserves into the action.

### 6.5 Tokens

- **Underlying tokens of existing-token DACs.** Fee-on-transfer underlyings cannot deploy a DAC. Rebasing underlyings strand surplus or leave the wrapper short. A pausable, blacklisting or upgradeable underlying can freeze the wrapper.
- **Funding tokens.** Each funding token of a deal is admitted by a DAC vote; admit only tokens the DAC would hold. A token that cannot move is skipped at capital return and reported, and returns when it moves again. A deal tolerates six funding tokens that deliberately burn their whole gas stipend before a capital return no longer fits one transaction (section 7.1). Fee-on-transfer funding tokens revert on funding hops and drift recorded balances; `recoverTreasury` corrects the treasury side.
- **`recoverERC20` accepts any token.** A token nobody vouches for can produce `TreasuryDeposit` events and book balances.

### 6.6 Integrators and indexers

- Key on registered emitters. Module factories and every `deploy*` function are permissionless; instances made outside a DAC have no standing but can emit kernel-shaped events naming a real DAC. The trust anchor is the DAC's deal registry (`DealManager.state(dealCell).id != 0`).
- Do not treat a `TreasuryDeposit` of an unknown token as value.
- Native and deal proposals accept votes after they resolve early, so tallies can grow after the outcome is fixed; the outcome does not change.
- A 100% reward conversion closes a deal, and results after a close in the same evaluation are ignored.
- `DealCloseHookFailed` and `CapitalReturnFailed` mean a module or a token did not cooperate; the deal closed, and the other tokens returned.
- A `VotesLocked` event explains why a later transfer, unwrap or delegation of that account reverts.

---

## 7. Operating envelope

### 7.1 Limits

| Limit | Value | Where |
|---|---|---|
| Distinct stakers per deal, lifetime | 100 | `GovernanceLimits.MAX_DEAL_HOLDERS` |
| Module-controlled addresses per deal | 3, plus the deal and its cell | `DealManager.MAX_MODULE_CONTROLLED_ADDRESSES` |
| Quorum, high quorum, non-zero blocking | 0.1% to 100%; high ≥ default | `VotingConfigLib` |
| Qualification | 0 to 50% | `VotingConfigLib` |
| Deal-challenge floor | 0.1% of votable supply | `GovernanceLimits.MIN_VETO_QUALIFICATION` |
| Any governance duration | 1 second to 365 days | `GovernanceLimits.MAX_DURATION` |
| Vote lock | at most 3 years, at most the votes held | `VoteLock` |
| Dividend claim window | 365 days | `GovernanceLimits.DIVIDEND_CLAIM_WINDOW` |
| Revenue cycles settled per evaluation | 64 | `RevenueBasedEvaluator.MAX_CYCLES_PER_EVALUATION` |
| Close hook stipend | 5,000,000 gas | `DealCell` |
| Evaluator activation hook | no fixed limit; after a failed hook the approval needs 1/8 of the pre-call gas left, else it reverts | `DACCellGovernanceLib` |
| Capital return, per funding token | 1,000,000 gas in the deal cell; 1,000,000 in `TreasuryDeal`; 100,000 per probe | `DealCellGovernanceLib`, `TreasuryDeal` |
| Governance oracle read | 300,000 gas | `HybridDACManagementProposal` |

A funding token that burns every unit of gas it is given costs about 2.4M gas across the stages of a capital return (measured with one such token: 1.19M when only one stage holds a balance). Six of them in one deal leave a capital return inside a 2^24-gas transaction.

### 7.2 The holder cap

Every slash and every reward allocation walks a deal's holder list once per evaluation result, and Base caps a transaction at 16,777,216 gas. Measured with cold storage, one transaction per call, every holder with a live stake:

| Evaluation | 25 holders | 50 holders | 100 holders |
|---|---|---|---|
| First reward conversion | 0.93M | 1.65M | 3.09M |
| Later reward conversion | 0.44M | 0.74M | 1.33M |
| Slash | 1.48M | 2.77M | 5.35M |
| Conversion + slash + close | 1.76M | 3.25M | 6.23M |

With 100 holders, a first evaluation carrying `K` alternating conversion and slash results costs 7.94M (K = 2), 9.68M (4), 13.15M (8), 14.88M (10) and 16.62M (12). The cost is close to linear:

```
gas(N holders, K results) ≈ N × (79,400 + 8,700 × (K − 2))
```

which puts the ceiling at about 211 holders for a two-result evaluation and 112 for a ten-result one. The cap of 100 keeps a ten-result evaluation inside the limit, and an ordinary evaluation (one or two results) under half of it. A holder with no live stake costs one balance read per result. The list is historical, so the cap counts every address that ever staked into the deal.

An evaluation that also closes the deal needs the close hook's stipend on top: 5,000,000 gas must still be available when the close is reached, whatever the hook then uses, and that is 30% of a transaction. Sent with exactly the Base cap, results followed by a close fit as follows:

| Holders | Results before the close that fit |
|---|---|
| 100 | 5 (6 do not) |
| 75 | 8 (10 do not) |
| 50 | 16 |

An evaluation that does not fit reverts as a whole and does so every time, so a deal with a full holder list should not be able to produce more than five slash or convert results together with its close. The usual closing evaluations are far inside this: a full slash, or a final conversion, with the close.

The cap is a property of walking the list. Accounting that settles slashes and rewards per holder on claim, rather than per evaluation, would remove it; that is a change of the deal cell's storage model and belongs to a later protocol version.

### 7.3 Gas

| Path | Gas | Conditions |
|---|---|---|
| Protocol deployment | 73.0M total | 26 transactions, largest 5.55M |
| `deployDAC` / `deployExistingTokenDAC` | 2.38M / 2.83M | |
| `createDealProposal` | 4.17M / 6.80M | `TreasuryDeal` / `DACDeal` with child DAC |
| `createManagementProposal` | 0.52M to 0.78M | native / hybrid |
| `stakeToDeal` | 0.43M / 0.62M | 25th / 100th holder |
| `forceReturnCapital` | 0.35M | one funding token |
| `DACDeal` close hook | 0.24M | against its 5.0M stipend |
| Revenue evaluation, 64 cycles | 0.47M / 2.18M / 16.33M | 2 / 16 / 128 coefficients per curve |

The holder rows can be reproduced with `N_HOLDERS=100 K_RESULTS=10 forge test --match-path 'test/audit/pass-2026-11/GasCeilings.t.sol' --isolate -vv`.

### 7.4 Contract size

| Contract | Runtime (bytes) | Headroom under 24,576 |
|---|---|---|
| `DACCell` | 23,240 | 1,336 |
| `DACDeal` | 19,585 | 4,991 |
| `DealCellGovernanceLib` | 17,018 | 7,558 |
| `DealManager` | 15,816 | 8,760 |
| `DACCellGovernanceLib` | 15,039 | 9,537 |
| `DealCell` | 14,683 | 9,893 |
| `AgentDeal` | 13,584 | 10,992 |
| `TreasuryDeal` | 13,410 | 11,166 |

`DACCell` is the contract to watch. solc 0.8.38 generates the same code for the `cancun` and `prague` targets; `cancun` is the lowest target the sources build for.

### 7.5 Defaults

| Setting | Value |
|---|---|
| Native quorum / high / blocking | `q` / `(1+q)/2` / `(1−q)/2`; 50% / 75% / 25% in the seed |
| Native duration / qualification / execution validity | 7 days / 0 / 1 day |
| Hybrid seed quorum / high / blocking | 50% / 75% / 20%, blocking on high-quorum types |
| Hybrid oracle deadline / warmup / fallback duration | 1 day / 4 hours / 3 days |
| Hybrid vote retention / lock | 0 / 0 (off) |

The defaults are bootstrap settings: no qualification, a short warmup, no retention. They keep a new DAC with a handful of holders fast. Sections 6.1 and 6.2 say what to revisit as it grows.

---

## 8. Design positions

These are properties the protocol chooses. They are listed so that DAC operators and integrators know what each one puts at risk.

| Position | What it means in practice |
|---|---|
| **A DAC cannot pause, override or close a live deal before its deadlines.** | The funding of an approved deal, plus approved tranches, is in the agents' hands. Reward issuance stays bounded by the DAC-approved limit and the evaluator. |
| **Economic commitments over structural prohibitions.** No minimum electorate, no forced blocking, no execution delay in the kernel. | A DAC sets its own cost of governing: qualification, vote retention, lock length, warmup, blocking. Section 6 says how. |
| **Module trust.** A module is approved by high-quorum vote and trusted inside its own deals. | A malicious module can lose its deals' funding and trap stakes in them. It cannot reach beyond them. |
| **`dacFactory` and `dealTarget` are not validated.** No lock-in to one factory. | A deal pointing at a hostile target loses its funding at approval. Interfaces must decode `initParams` and flag non-canonical addresses. |
| **`APPROVE_DEAL` does not bind a parameter hash.** | Before approval the stakers can still change the deal's voting config, whitelist and early-return flag, after holders have voted. |
| **`RECOVER_DEAL` is default-quorum and not blockable**, and the liquidator's stake is unbacked. | Control of a closed, staker-less deal's remaining assets. |
| **One challenge slot per deal proposal.** | A holder above the floor can hold a challengeable deal proposal for one full DAC vote, with its qualifying votes locked for that time. |
| **The claimer chooses the evaluator in `mintMain`.** | None beyond the reward cap, which is enforced after the evaluator's answer. |
| **The reference oracle is reference code.** Deactivation is one-way and open to any publisher. | A production oracle is expected to replace it through `UPDATE_GOVERNANCE_ORACLE`. |
| **Native: main tokens sent from a holder to a controlled address stay in votable supply.** | The base errs high. Quorum gets harder, never easier. |
| **A deal funded in the home main token** hands a child's controller home votes. | Bounded by the funding. |
| **After `dealDeadline` any holder can return an open deal's funding tokens.** | Working capital of a deal that runs past its deadline. Core evaluators never extend that deadline. |

---

## 9. Review record

The review reproduced the scenarios below. "Code" means the release closes the scenario and a regression test pins it; "Guide" means the behaviour is intended and section 6 says how to operate with it. References are the identifiers used during the review.

| Ref | Subject | Outcome | Pinned by |
|---|---|---|---|
| C-01 | Electorate of a wrapped-only (fallback) vote | Code: vote retention share and vote lock as strategy parameters. Guide: 6.2 | `HybridGovernanceHardening`: `test_REG_C01_*`, `test_NOTE_C01_*` |
| H-01 | Oracle snapshot published in time but not activated | Code: honoured by publication time. Guide: 6.2 | `test_REG_H01_*`, `test_CONTROL_H01_*` |
| H-02 | Timepoint of vote weights and of the quorum base | Code: one past timepoint for both, DAC and deal proposals | `KernelHardening`: `test_REG_H02_*`; invariant F1 |
| H-03 | Zero stakes and the length of a deal's holder list | Code: stake above zero, list capped at 100. Envelope: 7.2 | `test_REG_H03_*` |
| M-01 | Delay between a deal vote and its execution | Guide: 6.3 | `test_NOTE_M01_*`, `test_CONTROL_M01_*` |
| M-02 | Timestamps taken from the observing transaction | Code: schedule fixed by durations, on native and hybrid proposals | `test_REG_M02_*` |
| M-03 | Capital calls without an end | Code: expiry. Guide: 6.1 | `test_REG_M03_*`, `test_NOTE_M03_*` |
| M-04 | Evaluator schedules and reference prices | Code: measured from the deal's approval | `EvaluatorActivation` |
| M-05 | Spend rights after a slash | Guide: 6.3 | `TreasuryDealBehaviour`: `test_NOTE_M05_*` |
| M-06 | Who may evaluate a deal, and when | Code: stake in the deal before the deadline | `test_REG_M06_*` |
| M-07 | Which addresses a deal takes out of the electorate | Code: the module rule on the kernel path, plus the cell binding | `ControlledAddress` |
| M-08 | Capital return with a token that cannot move | Code: per-token isolation | `test_REG_M08_*` |
| M-09 | Qualification of proposal and challenge creators | Code: past votes, and a lock on the qualifying votes | `ProposalQualification` |
| L-01 | DAC address and its deployer | Code | `test_REG_L01_*` |
| L-02 | Deals without a terminal state | Guide: 6.3 | |
| L-03 | Quorum class of `CAPITAL_CALL` | Code: high quorum | `test_REG_L03_*` |
| L-04 | Close hook of a module | Code: isolated, guaranteed stipend | `LifecycleHardening`: `test_REG_L04_*` |
| L-05 | Bounds on evaluator configuration | Guide: 6.3 | `EvaluatorGasCeilings` |
| L-06 | `Permit2Treasury` allowances | Code: approval that narrow-allowance tokens accept. Guide: 6.3 | `test_REG_L06_*` |
| L-07 | Evaluator from a module removed before ratification | Guide: 6.3 | |
| L-08, L-09 | Approval deadline and initial stake; equity bought by a tranche | Guide: 6.3 | |
| L-10 | Assets on a closed `AgentDeal` | Guide: 6.3 | |
| L-11 | Reward shares and time at stake | Guide: 6.3 | |
| L-12 | Reference oracle roles and bounds | Guide: 6.2 | |
| L-13 | Bounds on voting configuration | Code: `VotingConfigLib` | `test_REG_L13_*` |
| L-14 | Unclaimed dividends | Code: claim window and sweep | `test_REG_L14_*` |
| L-15 | One-shot wiring and unused paths | Code | `test_REG_L15_*` |

Informational observations of the review are folded into sections 6 and 8.

This is an automated review. It does not replace an independent human audit before mainnet. Every row above with a test can be re-run by anyone from this repository.

---

## 10. Release checklist

Open release-engineering items. None is in `src/`.

| Item | Action |
|---|---|
| **CI stops at the format check.** `forge fmt --check` fails on the repository, and the workflow runs format, then build, then tests, so CI neither builds nor tests. | Run `forge fmt` once, or move the format step after the tests. |
| **A dry run overwrites the deployment manifest.** `writeProtocolManifest` runs during simulation. | Write only when broadcasting; refuse to overwrite. |
| **No chain or Permit2 guard in the deployment scripts.** The Permit2 address is checked only for non-zero, then fixed immutably in `TreasuryDealFactory`; `Permit2TreasuryFactory.permit2` has no getter. | Off a local chain, require `0x000000000022D473030F116dDEE9F6B43aC78BA3` with code; expose a getter. |
| **Fallbacks to well-known keys and mock tokens on any chain.** | Chain-guard the fallbacks; add a keystore or hardware-wallet path. |
| **Preflight and SmokeCheck coverage.** Preflight omits the module registry, the native controller and schema, and the existing-token set; neither compares code hashes. | Extend both. |
| **Linked libraries are not in the manifest.** | Record `DACCellGovernanceLib`, `DealCellGovernanceLib` and `DACDeployment` addresses. |
| **Metadata reproducibility.** `auto_detect_remappings` embeds detected remappings in every contract's metadata. | Set `auto_detect_remappings = false` and add `forge-std/=lib/forge-std/src/`. |
| **Testnet.** Sepolia deployments predate this tree. | Redeploy from the release commit and rehearse the mainnet procedure. |
| **Mainnet defaults.** | Decide qualification, warmup, retention and execution validity for the first DACs (7.5). |

---

## 11. Tests

`forge test` runs 339 tests; 338 pass and one, the full invariant campaign, is skipped unless enabled.

### 11.1 Review tests

`test/audit/pass-2026-11/`. `test_REG_*` replays a scenario and asserts that it fails. `test_NOTE_*` pins intended behaviour that section 6 documents. `test_CONTROL_*` is the baseline a scenario is measured against. `test_VERIFY_*` checks a property end to end.

| File | Covers |
|---|---|
| `KernelHardening.t.sol` | Vote and base timepoint (DAC and deal level), the opening of voting, voting-config bounds, deal-vote execution timing, fixed execution windows, capital-call expiry and quorum, evaluation gating, deployer-bound addresses, staking limits and their gas |
| `HybridGovernanceHardening.t.sol` | Timely snapshots (also after an oracle deactivation, and with an oracle that stops answering), the fixed hybrid schedule, vote retention and vote locks, and what a fallback electorate is |
| `ProposalQualification.t.sol` | Past-vote qualification and the lock on a creator's and a challenger's votes |
| `EvaluatorActivation.t.sol` | Revenue schedules and growth baselines measured from the deal's approval; the activation hook without a gas limit, under every gas limit a caller can choose |
| `TreasuryDealBehaviour.t.sol` | Spend rights after a slash, per-token capital return, narrow-allowance tokens, and the Permit2 signature paths, against the canonical Permit2 runtime |
| `ControlledAddress.t.sol` | Which addresses a deal can take out of the electorate |
| `LifecycleHardening.t.sol` | Close-hook isolation, `DACDeal` equity at and after close, dividend claim window and sweep, one-shot wiring |
| `AccountingProperties.t.sol` | Reward-cap fuzz and sweep-path properties |
| `ExistingModeAccountingProperties.t.sol` | Existing-token reserve, funding conservation and capital return, end to end |
| `GasCeilings.t.sol`, `EvaluatorGasCeilings.t.sol` | The measurements behind section 7. They print figures. |

### 11.2 Stateful invariant suite

`test/invariant/` drives a native DAC through 63 handlers: main-token transfers, delegation and burns; donations to every protocol address; capital calls with replays; agent mint and revoke; treasury mint and burn; voting-config changes; dividends with well-formed and over-allocating roots, forged claims and sweeps; the treasury sync functions; deal challenges; the whole deal lifecycle with tranches in cash and in main token; treasury-deal spending through direct spend, agent allowances and Permit2; DAC-deal reinvest and return; evaluation by a mock evaluator returning arbitrary slash, convert, extend and close results and by the real milestone and revenue evaluators; claims, capital return, recovery and time warps.

**Held after every call.**
- Treasury: for each cash token and the main token, controller balance ≥ recorded treasury ≥ commitments, commitments equal dividends still owed, and recorded treasury reconciles with every inflow and governed outflow.
- Cash is conserved across all protocol addresses; `recoverERC20` never pays its caller; no call debits an account that took no part in it.
- Per deal: invested capital equals settled tranches; `paid ≤ unlocked ≤ limit`; cell limit equals manager limit; claimables sum to `unlocked − paid`.
- Reward reservation equals the sum over deals of `limit − paid` while active and `unlocked − paid` once closed; supply plus obligations stays under `maxSupply`; close releases exactly `limit − unlocked`, once.
- Main supply equals capital calls plus treasury mints plus reward claims minus burns. Stake supply equals escrowed agent tokens plus liquidator stake.
- Votable supply never underflows, locked balance never exceeds balance on a controlled address, and live votes never exceed votable supply.
- A proposal's recorded electorate covers every vote that exists at its snapshot (F1), and its tally never exceeds it.
- A live vote lock is always covered by the account's votes (V1).
- Every proposal executes at most once; closed and approved are final.
- `DealManager` and `DealCell` hold nothing but donations.

**Held at the end of every run.** Every claimable reward and pool can be claimed; after the deadline `forceReturnCapital` succeeds and leaves no funding token on cell, deal or treasury; after close every staker gets its full stake back; inside its claim window every remaining leaf of a well-formed dividend pays.

**Runs on this tree.** Two campaigns of 200 runs × 250 calls (100,000 handler calls) and one of 40 runs × 200 calls, on three seeds, with unexpected reverts treated as failures: no invariant, expectation or end-of-run probe failed.

**Not covered by the suite.** Existing-token mode, `AgentDeal`, Permit2 receive and signature paths, ERC-1271 signing, legal-wrapper paths, distributor inventory, deferred birth, deals inside child DACs, and non-standard tokens. Those are covered by the unit and scenario tests above.

**Running it.** A plain `forge test` runs a smoke campaign of 16 runs × 80 calls in about five seconds. The full campaign:

```
INV_CAMPAIGN=true FOUNDRY_INVARIANT_RUNS=200 FOUNDRY_INVARIANT_DEPTH=250 \
  FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_FUZZ_SEED=0x01 \
  forge test --match-contract NativeInvariantsCampaign
```

The harness reads private storage by slot (`NativeAssetController` slots 5, 6, 7, 9, 10, 11 and `DealCell` slots 24, 28) and must be re-checked when those layouts change.

### 11.3 Fuzz suites at 20,000 runs

Every fuzz test in the repository passes at 20,000 runs: `FOUNDRY_FUZZ_RUNS=20000 forge test --no-match-path 'test/invariant/*'`.

---

## Appendix A. Deal proposal types

Quorum and blocking are measured on the deal's stake supply, so blocking protects minority agents, not the DAC. "If veto" means the proposal is challengeable by the DAC only when the deal has `vetoEnabled`.

| Type | Deal | Quorum | Blocking | Challengeable |
|---|---|---|---|---|
| `UPDATE_VOTING_CONFIG` | any | high | no | if veto |
| `ENABLE_VETO_RIGHT` | any | high | no | if veto |
| `ADD_STAKE` | any | high | no | if veto |
| `TOGGLE_WHITELIST` | any | high | no | if veto |
| `TOGGLE_EARLY_RETURNS` | any | high | no | if veto |
| `PERMIT_EVALUATOR_ADD` | any | high | no | if veto |
| `PERMIT_UNSTAKE` | any | high | no | always |
| `STRIKE_OUT_AGENT` | any | high | no | always |
| `REQUEST_TRANCHE` | any | default | yes | if veto |
| `REINVEST_PROFITS` | `DACDeal` | high | no | if veto |
| `CREATE_DAC_PROPOSAL` | `DACDeal` | default | no | never |
| `VOTE_DAC_PROPOSAL` | `DACDeal` | default | yes | if veto |
| `RETURN_PROFITS` | `DACDeal` | default | no | never |
| `APPROVE_VOTING_VENUE_VERSION` | `DACDeal` | high | yes | if veto |
| `EXTERNAL_VOTE_SIGN` | `DACDeal` | default | yes | if veto |
| `APPROVE_DIRECT_SPEND` | `TreasuryDeal` | high | no | if veto |
| `APPROVE_PERMIT2_SPEND` | `TreasuryDeal` | default | yes | if veto |
| `APPROVE_AGENT_SPEND` | `TreasuryDeal` | default | yes | if veto |
| `ASSIGN_CLAIMER` | `TreasuryDeal` | default | no | never |
| `REVOKE_AGENT` | `TreasuryDeal` | default | no | never |
| `RETURN_CAPITAL_TO_DAC` | `TreasuryDeal` | default | no | never |
| `DELEGATE_VOTE_RIGHTS` | `TreasuryDeal` | default | yes | if veto |
| `HOST_STAKE` | `AgentDeal` | high | no | if veto |
| `HOST_APPROVE_STAKE` | `AgentDeal` | high | no | if veto |
| `HOST_CREATE_DEAL` | `AgentDeal` | high | no | if veto |
| `HOST_CREATE_PROPOSAL` | `AgentDeal` | default | yes | if veto |
| `HOST_VOTE` | `AgentDeal` | default | yes | if veto |
| `HOST_CLAIM_REWARD` | `AgentDeal` | default | no | never |
| `HOST_UNSTAKE` | `AgentDeal` | default | yes | if veto |
| `HOST_INVITE` | `AgentDeal` | default | no | never |
| `RETURN_ASSET_TO_DAC` | `AgentDeal` | default | no | never |

The never-challengeable types are inbound or permission-reducing with two exceptions: `CREATE_DAC_PROPOSAL`, which lets a deal's stakers open proposals in the child DAC, and `HOST_INVITE`, which grants invite rights in a host deal.

---

*Sources for external facts: Base per-transaction gas limit, [docs.base.org/specifications/transactions/throughput-and-limits](https://docs.base.org/specifications/transactions/throughput-and-limits) and the [configuration changelog](https://docs.base.org/base-chain/network-information/configuration-changelog); Solidity optimizer advisory behind the compiler pin, [soliditylang.org/blog/2026/10/22/yul-optimizer-knowledge-base-stale-bookkeeping-bug](https://www.soliditylang.org/blog/2026/10/22/yul-optimizer-knowledge-base-stale-bookkeeping-bug/).*
