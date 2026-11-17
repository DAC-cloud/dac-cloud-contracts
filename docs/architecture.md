# DAC Cloud Architecture

Updated: May 11, 2026

For the contract-by-contract inventory, see [contracts.md](contracts.md). For build, test, deployment, and scenario scripts, see [development.md](development.md).

## 1. Summary

DAC Cloud is a governance micro-kernel for modular onchain corporations.

The architecture is split into four concerns:

- `DACCell`: DAC identity, legal-wrapper integration, proposal routing, and DAC-level execution entrypoints
- `GovernanceSchema`: DAC proposal policy, qualification, quorum rules, and proposal deployment
- `AssetController`: treasury custody/accounting and DAC main-asset policy
- `DealManager`: deal lifecycle, evaluator routing, and module-driven execution

This separation keeps governance policy, treasury accounting, and deal execution in distinct, auditable boundaries.

## 2. Core Philosophy & Origin Story

DAC Cloud was born from a simple but powerful observation: **modern organizations are too rigid, while blockchains are too chaotic**.

Traditional corporations are hierarchical, slow to adapt, and misaligned between capital and execution. Classic DAOs are transparent but suffer from speculation, low skin-in-the-game for managers, and governance theater.

The original "DAC engine" idea of 2022 captured the essence perfectly: large organizations should reorganize as **trees of small, autonomous DACs** -- agile teams of 5-9 people (Scrum-sized) operating as independent economic entities that make deals with each other and with the outside world.

From these ideas DAC engine was born originally as a "Scrum-plugin" to enhance brand-aggregators and venture-studios businesses. With the rise of AI agents in 2026, the protocol was reborn as a corporation-as-code framework for EVM.

This is the **lego idea** at the heart of DAC Cloud.

Every team, product group, or service unit becomes its own **DAC** -- a lightweight, self-sovereign corporation with its own treasury, governance, and incentives. These DACs connect through **Deals** (capital calls, service agreements, revenue shares) and settle payments instantly via x402, Permit2, or direct ERC-20 transfers.

The result is a living, breathing organizational fractal:
- Small teams move fast.
- Capital flows where value is created.
- Performance is measured and rewarded transparently.
- The whole system scales without losing alignment.

### 2.1 Two DAC Modes

The protocol supports two first-class DAC modes:
- Operating a fresh DAC-native setup, with the mintable governance token;
- Attaching a DAC to an existing token.

#### 2.1.1 Native DAC

Native DACs are the original flow:

- deploy a fresh `MainToken`
- use direct `ERC20Votes` governance
- use `NativeGovernanceSchema`
- use `NativeAssetController`
- settle main-token rewards through native mint-backed accounting

This is the simplest launch path for a new tokenized organization.

#### 2.1.2 Existing-Token DAC

Existing-token DACs attach governance and deal logic to an already circulating token:

- deploy a `WrappedMainToken`
- deploy or attach to a `BasicGovernanceOracle`
- use `HybridGovernanceSchema`
- use `ExistingTokenAssetController`
- seed the DAC treasury by wrapping a nonzero donation of the underlying token during DAC creation
- treat main-asset rewards and dividends as reserve-backed claims against wrapped reserves

This lets teams adopt DAC governance and deal mechanics without replacing a live token.

## 3. Core Components

### 3.1 DACFactory

`DACFactory` is the bootstrap entrypoint.

It exposes two deployment paths:

- `deployDAC(...)` for native DACs
- `deployExistingTokenDAC(...)` for existing-token DACs

The factory deploys proxies for the kernel subcomponents through dedicated factories and then wires them together. For existing-token DACs it also deploys the wrapper/oracle pair and performs the initial wrapped-treasury seed.

A DAC's address is a CREATE2 address bound to its deployer: the factory derives the salt it deploys with as `deploymentSalt(deployer, salt) = keccak256(abi.encode(deployer, salt))`, where `deployer` is the caller of the factory. The address therefore commits to the deployer, the caller's salt, the DAC's name and description, and nobody else can take an address a deployer has computed. `DACDeployment.predictDACAddress(...)` takes the derived salt.

### 3.2 DACCell

`DACCell` is the DAC kernel.

Its responsibilities are:

- DAC metadata (`name`, `description`)
- storing pointers to:
  - main token
  - agent token
  - deal manager
  - module registry
  - asset controller
  - governance schema
- DAC proposal creation and execution routing
- legal-wrapper messaging
- DAC-level event emission

`DACCell` does not own deals, treasury balances, or main-token commitment accounting.

### 3.3 GovernanceSchema

The governance schema owns DAC-level governance policy.

Implementations:

- `NativeGovernanceSchema`
- `HybridGovernanceSchema`

The schema is responsible for:

- proposal qualification
- proposal-type gating
- voting-config validation
- governance-strategy validation
- deal-creation qualification config
- governance-oracle pointer management for hybrid DACs
- proposal deployment and proposal registry
- consuming passed proposals at execution time

The schema deliberately separates DAC governance policy from DAC execution.

### 3.4 AssetController

The asset controller is the treasury and main-asset accounting boundary.

Implementations:

- `NativeAssetController`
- `ExistingTokenAssetController`

The controller owns:

- treasury custody (`treasuryHolder()`)
- treasury balance accounting
- treasury sync / recovery logic
- capital-call state
- dividend payout commitments and claims
- main-token reward commitments
- settlement of main rewards
- controlled-address / non-votable-balance exclusions
- capability checks for mint / burn / capital-call support

DAC treasury state is controller-owned, not cell-owned.

#### 3.4.1 Accounting Hardening

Committed and treasury balances use safe floor-at-zero subtraction: if a subtraction would underflow (e.g., due to external ERC-20 balance drift or rounding), the balance floors to zero rather than reverting. This prevents edge-case lockups where an external transfer or fee-on-transfer token causes the tracked balance to diverge slightly from the actual on-chain balance.

### 3.5 DealManager

`DealManager` owns deal lifecycle, not DAC treasury policy.

It owns:

- deal registry
- deal creation
- module validation
- evaluator installation and permissioning
- evaluator execution
- deal state transitions such as approval, close, recovery eligibility, and reward/slash orchestration

Where DAC-level token accounting is needed, `DealManager` calls into the active `AssetController`.

### 3.6 ModuleRegistry

Approved module state lives in `ModuleRegistry`, not `DealManager`.

This keeps module approval semantically owned by the DAC kernel while keeping the registry logic out of the manager itself.

`DACCell` owns approval authority.
`DealManager` and other components query the registry.

## 4. Token Model

### 4.1 MainToken

In native mode, `MainToken` is the DAC governance token:

- transferable
- capped
- `ERC20Votes`-compatible
- subject to controlled-balance restrictions through the asset-controller/deal-manager boundary

### 4.2 WrappedMainToken

In existing-token mode, `WrappedMainToken` is the DAC-native governance and accounting asset:

- wraps an existing underlying ERC-20 at 1:1
- is `ERC20Votes`-compatible
- auto-self-delegates on first self-wrap
- reports moves and delegations to the asset controller
- is the asset used for:
  - wrapper-based qualification
  - wrapped voting in hybrid primary mode
  - fallback voting
  - reserve-backed rewards/dividends

### 4.3 Vote locks

`MainToken` and `WrappedMainToken` can pin voting power in place. A vote lock fixes an amount of an account's delegated votes until a timestamp: while it is live, nothing may bring that account's votes below the locked amount. That covers a transfer, an unwrap or burn, and a re-delegation, whether attempted by the account itself or by anyone who delegated to it. Whoever lends votes to a delegate shares its locks. Votes above the locked amount move freely.

Only the DAC's governance schema can lock, and only as part of the account's own governance act:

- opening a proposal locks the creator's qualifying votes until the proposal's voting can no longer be running (section 5.5)
- in existing-token DACs, casting a wrapped vote locks the configured share of the vote's weight for the configured period (section 5.3)

Locks merge conservatively (the larger amount and the later expiry win), expire on their own, and are bounded by the token itself: no lock can exceed the votes the account holds when it is set, nor run longer than three years. `lockedVotes(account)` returns the live amount and its expiry; `VotesLocked(account, amount, until)` is emitted on every lock.

The purpose is economic. Capital that is used to govern stays exposed to the outcome it produced instead of leaving in the next block.

### 4.4 AgentToken

`AgentToken` is the DAC-level operator token:

- minted and revoked by DAC governance
- can be minted either:
  - directly to a bound agent address, or
  - into DAC-approved distributor inventory
- required for deal participation
- subject to deal-creation anti-spam checks through `DealCreationConfig`

#### 4.4.1 Distributor flow

Distributor flow is the easy way to onboard a list of agents.

DAC governance uses the same `MINT_AGENT_TOKENS` proposal selector, but the payload can choose among:

- direct mint to a bound agent
- mint of transferable inventory to a distributor wallet
- distributor disable / allowance reset

The `AssetController` owns distributor state.

Important invariants:

- distributor addresses can hold transferable inventory
- real agent addresses hold bound, non-transferable balances
- distributor inventory does not count toward DAC agent qualification or deal-creation qualification
- transfer from distributor to recipient is a one-way conversion into a bound agent balance

This reduces onboarding friction for large agent networks without weakening the economic meaning of real agent membership.

### 4.5 StakedAgent

`StakedAgent` is the deal-local governance token:

- minted per deal
- non-transferable
- `ERC20Votes`-compatible
- used for deal-level proposals and execution rights

## 5. DAC Governance Model

### 5.1 Native DAC Governance

Native DAC governance uses a dedicated DAC proposal flow:

- direct `ERC20Votes` snapshot voting on `MainToken`
- delegated-vote qualification
- quorum, blocking, and high-quorum rules from `VotingConfig`
- execution validity windows after resolution

A proposal reads everything at one past timepoint: the second before its creation. Vote weights are `getPastVotes` at that second, and the quorum base is the votable supply at that same second (`AssetController.getPastVotableSupply`). Tokens that become votable in the creation second or later, by capital call, reward claim, release from a controlled address or purchase, neither vote on the proposal nor count in its base. Deal proposals follow the same rule on `StakedAgent`: weights and base are the stake supply at the second before creation.

A proposal can only be opened when that past votable supply is non-zero, so nothing can be proposed in the same second a DAC receives its first votable tokens. Voting opens the second after creation: a proposal is on chain for at least one block before a vote can resolve it, so creation, resolution and execution never share a transaction.

### 5.2 Existing-Token DAC Governance

Existing-token DAC governance uses a hybrid state machine.

There are two voting channels in the primary path:

- Merkle voting for unwrapped underlying holders
- wrapped `ERC20Votes` voting for wrapped holders

Both are anchored to the same proposal snapshot reference.

If the oracle does not publish in time, the proposal transitions into fallback:

1. `AwaitingOracleSnapshot`
2. `PrimaryVoting`, if the oracle publishes in time
3. otherwise `FallbackWarmup`
4. then `FallbackVoting`
5. then `Resolved`

Fallback is wrapped-token-only and starts from a clean vote state after warmup.

The schedule is fixed by the configured durations and by the oracle's publication time, never by the transaction that happens to record a transition:

| Phase | Starts | Ends |
|-------|--------|------|
| `AwaitingOracleSnapshot` | proposal creation | `oracleSnapshotDeadline = creation + oraclePublishDeadline` |
| `PrimaryVoting` | the snapshot's `publishedAt` | `publishedAt + duration` |
| `FallbackWarmup` | the oracle deadline (or creation in wrapped-only mode, or the emergency trigger) | `fallbackSnapshotTime = start + fallbackWarmupDuration` |
| `FallbackVoting` | `fallbackSnapshotTime` | `fallbackSnapshotTime + fallbackDuration` |

Transitions are applied lazily: any vote, execution attempt or state read applies every transition that is due, with the scheduled times. A snapshot the oracle published at or before the deadline is therefore always honoured, whether or not anyone called `activatePrimaryVoting()` before the deadline, and a proposal with a timely snapshot cannot be moved into fallback by waiting. A proposal nobody touches still runs out on schedule: its phases end when the table says they end, and a vote that arrives later is refused. `activatePrimaryVoting()`, `beginFallbackWarmup()` and `activateFallbackVoting()` remain as explicit, optional pokes that record the same transitions with the same times.

The oracle can change this schedule in one way only, and only through an explicit transaction. When the oracle is switched off for the DAC, a snapshot it published in time stays binding; anyone can then call `triggerEmergencyFallback()` on a proposal that is awaiting or in primary voting, which discards the primary votes and starts a fresh warmup from that moment. A proposal is never moved onto a fallback snapshot that already lies in the past. An oracle that stops answering (it reverts, burns its gas, or returns malformed data) reads as an oracle with no snapshot: the proposal takes the fallback path at its deadline, and nothing that waits on its resolution is frozen.

Every snapshot in the protocol is a timestamp: `MainToken`, `StakedAgent` and `WrappedMainToken` all run ERC-6372 clocks in `mode=timestamp`, and the asset controller's controlled-balance checkpoints share that clock. The primary phase snapshots at the second before proposal creation. The fallback phase snapshots at the last second of warmup: warmup is measured in seconds (`fallbackWarmupDuration`) and the snapshot time follows from the schedule above, so it is public for the whole warmup. Holders can therefore wrap and delegate in response to a proposal during warmup, while no single actor can choose when the snapshot is taken. Voting activates once the snapshot time has passed. A phase whose votable supply at its snapshot is zero resolves as rejected: nobody could vote, and a dormant proposal would freeze anything gated on its resolution, such as a deal proposal held by a `CAST_VETO_DEAL` challenge. Quorum and blocking thresholds round up, so a dust-level supply cannot pass a proposal with no votes.

### 5.3 Hybrid Strategy Tweaks

Hybrid governance strategy has three important toggles:

- `blockingOnAllProposals`
- `blockingOnHighQuorum`
- `oraclePrimaryEnabled`

These let an existing-token DAC choose between:

- full oracle-primary hybrid mode
- wrapped-only bootstrap mode
- more defensive blocking settings during early community formation

Two further parameters decide how much of a wrapped vote's capital must stay in place:

- `voteRetentionPercent`: the share (0 to `1e18`) of a wrapped vote's snapshot weight that must still be delegated to the voter at the moment it votes. A voter who wrapped for the snapshot second and has since unwrapped or moved the tokens cannot vote with that weight.
- `voteLockDuration`: how long, in seconds, that retained share stays vote-locked on the voter after the vote (section 4.3). During the lock it cannot be unwrapped, transferred or re-delegated.

Zero retention switches the mechanism off: a vote then belongs to whoever held the wrapped tokens at the snapshot second, for that second only. A high retention with a long lock is the opposite stance: whoever decides a vote keeps the deciding capital in the DAC for weeks or months afterwards and lives with the result. A retention share with a zero lock only has to be present in the block of the vote. The settings bind wrapped votes; Merkle votes are bound by the oracle's snapshot policy.

Both parameters are read from the strategy as it stands when a proposal is created.

Wrapped-only bootstrap mode is not a separate governance family. It is a configuration of the hybrid family:

- proposals skip oracle publication as the primary path
- proposals begin in `FallbackWarmup`
- wrapped-token voting becomes the active governance channel after warmup
- governance can later switch back to oracle-primary mode

### 5.4 Governance Oracle

`BasicGovernanceOracle` is the reference publisher for proposal-specific Merkle snapshots in hybrid mode. A single oracle instance can serve any number of DACs — all snapshots and active state are namespaced per DAC.

Important properties:

- oracle snapshots are namespaced by `(dac, proposalId)` so a single deployment can support an arbitrary number of DACs without proposal-id collisions
- each snapshot includes:
  - `snapshotTime` (a timestamp; the Merkle tree reflects underlying balances as of the last block whose timestamp is at or below it)
  - `merkleRoot`
  - `totalUnderlyingVotingPower`
  - `publishedAt`
- per-DAC active state — deactivating one DAC's slot has no effect on any other DAC sharing the oracle
- deactivation forces that DAC's active hybrid proposals into the fallback path
- DAC governance can replace the oracle instance with a new one
- consumer surface is the read-only `IGovernanceOracle` (`isActive(dac)`, `getSnapshot(dac, id)`); operator surface is the extended `IBasicGovernanceOracle` (publish, admin, deactivate). This split lets future implementations (optimistic/staked publishers, ZK-proven snapshots, multi-publisher aggregators) swap in transparently for consumers.

### 5.5 Qualification

Proposal qualification uses delegated voting power rather than raw token balances:

- native DAC proposals: delegated `MainToken` votes
- hybrid DAC proposals: delegated `WrappedMainToken` votes
- deal proposals: delegated `StakedAgent` votes

Qualification thresholds are **percent-based**. A qualification value ranges from 0 to `0.5e18` (where `1e18 = SCALE = 100%`). The effective threshold is computed at runtime as:

```
threshold = MathLib.mul(votableSupply, qualificationPercent)
```

Both sides of the comparison are read at the second before the proposal is created: the creator's past votes against the votable supply of that same second. A balance borrowed and returned inside the creating transaction does not qualify, and the creator must hold strictly more than the threshold.

Because the threshold is derived from the votable supply, it scales automatically as supply changes -- new mints, burns, wraps, or unwraps shift the absolute threshold without requiring governance to update qualification parameters.

Opening a DAC proposal also commits the qualifying votes. The threshold amount is vote-locked on the creator (section 4.3) until the proposal's voting can no longer be running: `duration` after creation in native DACs, the end of the longest scheduled path in existing-token DACs. A DAC that sets `qualification` to zero asks for no commitment; every non-zero setting makes opening a proposal a position the creator holds for the length of the vote.

This makes governance participation intentional and gives communities a way to set proposer thresholds that remain meaningful regardless of supply dynamics.

### 5.6 Challenging deal proposals

A `CAST_VETO_DEAL` challenge holds the challenged deal proposal until the DAC vote resolves and occupies that proposal's single challenge slot. Opening one uses the same proposal-creation `qualification` as every other type, floored at `GovernanceLimits.MIN_VETO_QUALIFICATION` (0.1% of votable supply) so that a DAC which leaves `qualification` at zero cannot have its deals stalled for one wei. The threshold is sized for a normal active holder, not for a blocking minority: below it a holder can still vote on a challenge someone else opened. Like any qualification it is measured on past votes, and the challenger's qualifying votes stay locked for the DAC's voting period, so a challenge always has capital behind it for as long as it holds a deal proposal.

### 5.7 Voting configuration bounds

A `VotingConfig` is checked wherever it is set, for a DAC and for a deal alike:

- `quorumPercent` and `highQuorumPercent` lie between 0.1% and 100%, and the high quorum is never below the default quorum
- `blockingPercent` is zero (blocking switched off) or between 0.1% and 100%
- `duration` and `executionValidityDuration` are non-zero and at most 365 days
- `qualification` is at most 50%

The bounds are sanity checks, not policy: they reject values that can only be a unit mistake (a raw `50` where `50e16` was meant) or that would leave governance unable to act, and they impose no relation between blocking and quorum. A low quorum with a larger objection threshold is a legitimate optimistic setup.

## 6. Deal Creation and Anti-Spam Controls

DAC-level governance can configure:

- `minAgentBalance`
- `minInitialAgentStake`

through `DealCreationConfig`.

These values apply when creating a new deal proposal:

- proposer must hold at least the configured `AgentToken` balance
- proposer must commit an initial stake into the new deal

This prevents unbacked deal creation and ties proposal spam resistance to real operator capital.

### 6.1 Per-Deal Participation Controls

`DealParams` includes two additional participation controls:

- `agentsLimit`: maximum number of unique stakers in a deal (0 = no limit)
- `minimalStake`: minimum stake required per agent to join the deal (0 = no minimum)

When `agentsLimit` is nonzero, the deal enforces a cap on the number of unique stakers. When `minimalStake` is nonzero, any agent staking into the deal must commit at least that amount. These controls let deal creators tune participation density -- from open-access pools to tight, high-commitment working groups.

Two rules hold whatever a deal configures:

- a stake is never zero
- a deal admits at most `GovernanceLimits.MAX_DEAL_HOLDERS` (100) distinct stakers over its lifetime

Slashing and reward allocation walk the deal's holder list inside one evaluation, so the list is bounded by the kernel: with a full list, a first evaluation that both allocates rewards and slashes costs about 7.9M gas, under half of a 2^24-gas transaction, and an evaluation carrying ten results still fits (14.9M). The list is historical (an address that staked once keeps its place), and `holdersCount()` on the deal cell reports how much of it is used. A liquidator appointed by DAC governance joins a closed deal outside the cap.

A deal with the whitelist switched off and `minimalStake` at zero is open to every agent of the DAC for one unit of stake. Its governance, its reward shares and its holder list are then shared with whoever arrives first; a deal that is not meant as an open pool sets at least one of the two.

## 7. Deal Governance Model

Deal governance is separate from DAC governance.

It uses `DealManagementProposal` on `StakedAgent`, with a DAC oversight model based on bounded challenges rather than veto:

- DAC governance can open a bounded challenge against a challengeable deal proposal
- challenge state lives on the deal proposal contract itself
- deal execution is delayed while a challenge is unresolved, not vote resolution

This preserves bytecode headroom for module-specific `Deal` implementations while making DAC oversight workable for short-duration deal votes.

### 7.1 Challenge Model

If a deal proposal is challengeable:

- staked-agent voting resolves normally
- a DAC `CAST_VETO_DEAL` proposal can register a challenge hold
- while the DAC challenge is unresolved, the deal proposal is not executable
- if the DAC challenge fails, the hold is released
- if the DAC challenge passes and is executed, the deal proposal is permanently blocked
- if the DAC challenge passes but expires unexecuted, the hold is released

Only one DAC challenge can be opened per deal proposal.

### 7.2 Execution Validity

Both DAC and deal proposals have execution-validity windows.

That means:

- a proposal can pass
- remain executable only for a bounded duration
- then become stale if not executed

This avoids indefinitely executable governance decisions and makes challenge delays bounded and explicit.

The window starts at the proposal's `resolutionTime`. A vote that decides the outcome stamps its own time. A proposal that resolves because its voting period ran out is stamped with the end of that period, whoever observes it first and whenever, so the window cannot be parked by leaving a passed proposal untouched.

A deal proposal is executable as soon as it resolves. The kernel adds no delay of its own between resolution and execution, which is what lets short deals (a one-day trade under week-long DAC governance) work at all. A DAC challenge therefore attaches to deal proposals that are still pending; a deal whose actions deserve a reaction window gets it from its module, as an execution delay in the action itself.

### 7.3 Evaluation

`DealManager.evaluateDeal(id, evaluatorId)` runs one of the deal's evaluators and applies what it returns (reward conversion, slash, extension, close).

Who may call it depends on the deal's `evaluationDeadline`:

- until the deadline, whoever holds stake in that deal. The deal's own agents decide when their work is measured.
- after the deadline, any main-token holder or agent of the DAC as well. This is the point where the DAC's side may step in.

An evaluator measures a deal from its activation. When the DAC approves a deal, the deal cell records `approvedAt` and the kernel calls `onDealActivated()` on every evaluator attached to it (an optional, isolated, gas-capped hook). The core evaluators use it as follows:

- `RevenueBasedEvaluator` counts cycles from `max(evaluationStart, approvedAt)`: no cycle runs while the DAC is still voting on the deal
- `MilestoneBasedEvaluator` takes the reference price of a growth-mode milestone at activation, so price movement before the deal existed is neither rewarded nor punished

An evaluator added to a deal that is already live takes its reference at the moment it is added.

## 8. Treasury and Main-Asset Accounting

Treasury accounting is controller-owned, with committed-balance tracking that separates free and reserved funds.

### 8.1 Native Mode

Native mode supports mint-backed main-token flows. The asset controller tracks:

- treasury-held `MainToken`
- main-token committed balances (reserved for rewards, dividends, and active obligations)
- DAC-controlled / excluded balances
- capital-call state
- dividend payout commitments

### 8.2 Existing-Token Mode

Existing-token mode uses reserve-backed claims.

The wrapped treasury inventory must actually exist before it can be committed.

This affects:

- deal reward reservation
- reward claim settlement
- dividend payout reservation
- treasury spend safety
- wrapped votable-supply exclusions for DAC-controlled balances

The existing-token flow therefore behaves like reserved treasury accounting rather than mint-headroom accounting.

### 8.3 Rewards

Staked agents receive rewards from participating in deals if the deal was evaluated positively.

Some deals also receive allocation of rewards to the Deal contract itself.

Each deal can configure:

- `dealRewardPoolPercent`

The remaining portion of unlocked rewards stays allocated pro rata to staked agents.

On reward unlock:

- staker share is allocated to agent claim balances
- deal share is allocated to `address(deal)`

The deal can then claim its own main-token pool and apply module-specific logic such as:

- campaign rewards
- MLM-style reward trees
- LP incentives
- loyalty or promotion programs

The kernel does not interpret those downstream schedules. It only routes ownership.

This feature is capability-gated by the selected module factory.

## 9. Capital Calls and Dividends

Capital calls and dividends are routed through the asset controller.

This is important because commitments are not just a main-token problem.

Implications:

- capital calls are tracked centrally by the controller
- dividend payouts reserve actual treasury balances
- claims settle against controller-held state, and cumulative claims against a payout are capped at its committed total, so a malformed Merkle root can never draw on other commitments or free treasury
- arbitrary treasury assets such as USDC are tracked consistently with the same commitment discipline

A capital call is an offer at a fixed price to a named recipient. Because it issues votable tokens (or, in existing-token mode, sells treasury-held wrapped tokens) to a chosen recipient at a chosen price, a `CAPITAL_CALL` proposal needs the high quorum, and it remains blockable. Every governance capital call states its expiry: the proposal data is `(treasuryToken, cashAmount, expiry)`, the expiry must lie in the future, and after it the call can neither be read nor fulfilled. A deliberately long-dated call is a legitimate instrument (it is an option on the DAC's equity, and governance votes on it as one); an open-ended call is not expressible. Only a DAC's root call, created at bootstrap for its founder, has no expiry. Until it expires, a call is filled by whoever sends the transaction, with the recipient's funds, so a recipient approves the asset controller when it means to pay.

A dividend payout can be claimed for `GovernanceLimits.DIVIDEND_CLAIM_WINDOW` (365 days) from its execution. After that window the payout is closed: `DACCell.sweepDividend(proposalId)`, open to anyone, releases whatever was not claimed from the commitment back to the free treasury. Nothing leaves the treasury in a sweep.

## 10. Module System

Modules are the execution extension point.

Each module factory exposes:

- module id
- semantic version
- manifest URI
- supported deal kinds
- supported evaluator kinds
- whether a given deal kind supports deal reward pools

The shipped module is `CoreModuleFactory`, which includes:

- `DACDeal`
- `TreasuryDeal`
- `AgentDeal`
- `MilestoneBasedEvaluator`
- `RevenueBasedEvaluator`

The core module declares support for deal reward pools on the `DACDeal` and `TreasuryDeal` kinds. `AgentDeal` does not use a deal reward pool: its economic role is to earn incentives inside a host DAC and route them home, not to accrue a home-main-token pool.

Module deals can emit standardized `DealRelatedContract` events so indexers can discover runtime-linked addresses such as:

- treasury contracts
- child DACs
- child tokens

without module-specific storage reads.

The kernel keeps a few outcomes out of a module's hands:

- **Closing.** A deal's close hook (`beforeClose`) runs with a guaranteed gas stipend and its failure is reported (`DealCloseHookFailed`), not propagated. No module, and no asset it holds, can stop a deal from closing or shield its stakers from the evaluation that closes it.
- **Returning capital.** `withdrawCapital` handles a deal's funding tokens one by one, each in an isolated, gas-capped call. A token that cannot move at that moment (frozen, paused, hostile) is reported (`CapitalReturnFailed`) and skipped; the others return, and the call can be repeated for what was skipped.
- **The electorate.** The address a module returns as its `Deal` is excluded from the votable supply only if it is a contract bound to the very deal cell being created (`getCell()`) that has never delegated. This is the same rule a module is held to for the further addresses it registers itself.
- **Activation.** The evaluator activation hook is optional and isolated: an evaluator without it, or one whose hook fails, does not affect the approval of a deal.

In each isolated call the stipend is guaranteed by the kernel: the caller either provides enough gas for it or the whole transaction reverts, so a turn can only fail because of the module or token it was given to.

### 10.1 DACDeal External Voting

`DACDeal` holds a child DAC's `MainToken` balance after capital calls fulfill — that balance is delegated to the deal itself, giving the deal voting power inside the child DAC. Two paths exist for using that voting power:

**On-chain child DAC governance.** `CREATE_DAC_PROPOSAL` and `VOTE_DAC_PROPOSAL` let staked-pigs propose and vote on the child DAC's own management proposals. This path is direct and synchronous.

When a `DACDeal` closes, its child equity goes home to the DAC treasury. The close hook transfers what is transferable at that moment. Equity the deal has vote-locked in the child (it opened a child proposal under a non-zero qualification, or cast a retained wrapped vote) stays on the deal until the lock ends; `returnChildEquity()`, open to anyone once the deal is closed, sends the remainder home.

**External venue voting via ERC-1271.** Some governance models call for off-chain voting on snapshot.org or similar EIP-712 attestation venues — for example shareholder-judged evaluators that aggregate votes off-chain. `DACDeal` implements `isValidSignature(bytes32, bytes)` (ERC-1271) so the deal's voting power can participate in these venues without delegating tokens to any external address.

Two staked-pig proposals govern this surface:

- `APPROVE_VOTING_VENUE_VERSION` — manages an allowlist of `(venueId, version)` pairs that may be used in vote-signing proposals. Sensitive (high quorum + blocking allowed) because the version determines which EIP-712 domain separator gets reconstructed during hash validation.
- `EXTERNAL_VOTE_SIGN` — approves a specific external vote. Carries the full structured payload (e.g. for snapshot: `version`, `from`, `space`, `timestamp`, `proposal`, `choice`, `reason`, `app`, `metadata`, `expiry`). On execution, the deal reconstructs the EIP-712 final hash from the structured fields using the venue's bound domain separator, stores the approval, and emits `ExternalVoteApproved` with the reconstructed hash.

**Why structured payloads, never raw hashes.** `DACDeal` holds tokens that implement EIP-2612 permit (the child `MainToken` inherits OZ `ERC20PermitUpgradeable`). OZ's permit path falls through to ERC-1271 for contract owners. If the deal stored raw approved hashes, an attacker could craft a payload that hashes to a permit-shaped digest, get it approved as if it were a snapshot vote, and then call `permit(...)` on the held token to drain the deal. By instead storing the structured payload and reconstructing the hash with the venue's domain separator on every read, the deal can never validate a hash that wasn't produced through its own venue-bound reconstruction. EIP-2612 hashes use the token's domain (with `chainId` and `verifyingContract`); snapshot's domain has only `(name, version)` — they cannot collide.

**Fork extensibility.** New venues (Safe Messages, Tally, custom optimistic governors, etc.) can be added by overriding two virtual hooks: `_executeExternalVoteSignExtension(venueId, payload)` for the approval path, and `_isValidSignatureExtension(hash)` for the lookup path. The `EXTERNAL_VOTE_SIGN` envelope (`bytes32 venueId, bytes payload`) stays venue-agnostic so the dispatch layer never needs to change.

### 10.2 Cross-Module Evaluator Deployment

Deals can specify a separate `evaluatorModuleFactory` in `DealParams`, distinct from the deal's own `moduleFactory`. This lets the kernel deploy the evaluator independently from the deal's module.

When `evaluatorModuleFactory` is `address(0)`, the deal's own `moduleFactory` is used (backward compatible). When a separate module is specified:

- the kernel deploys the evaluator using the evaluator module factory
- both the deal module and the evaluator module must agree on compatibility via `supportsEvaluatorKind(dealKind, evaluatorSelector)`
- the evaluator is deployed at the kernel level (inside `DACCellGovernanceLib.createDealProposal`), using the module specified by `evaluatorModuleFactory`

Later-added evaluators (via the `ADD_EVALUATOR` proposal) can also independently specify any approved module as their evaluator factory. The `ADD_EVALUATOR` proposal data encoding includes the `evaluatorModuleFactory` field, giving each evaluator its own module provenance.

This architecture creates a **trust stratification** between deal risk and reward risk. The deal module governs capital flow and state transitions, while the evaluator module governs performance assessment. By allowing these to come from different approved modules, a DAC can mix and match deal types with evaluation strategies -- for example, running a treasury deal with a third-party evaluation oracle, or attaching a custom milestone tracker to a standard deal shell.

### 10.3 AgentDeal: DAC-as-agent composition

`AgentDeal` is the inverse of `DACDeal`. Where `DACDeal` lets a DAC *own and capitalize a child DAC*, `AgentDeal` lets a DAC *act as an agent inside another (host) DAC* -- the lego piece that lets, for example, a drone/heavy-machinery DAC provide services to a farmland-field DAC for incentives.

An `AgentDeal` binds to exactly one host DAC at creation (via `DealParams.dealTarget`, stored as `managedEntity`) and caches the host's agent and main token addresses. Reading those host kernel getters during initialization also asserts the target is a real DAC. The relationship is emitted as `DealRelatedContract` events (`HOST_DAC`, `HOST_AGENT_TOKEN`, `HOST_MAIN_TOKEN`) for indexers.

Two governance layers apply, both reusing existing kernel mechanics:

- **Home layer.** The agent-deal is an ordinary deal in its home DAC. Its own staked agents govern every host-side action through staked-agent proposals.
- **Host layer.** The agent-deal is itself a staked agent inside the host DAC's deals. It holds the host's `AgentToken` (minted to it by host governance) and, after staking, the host's `StakedAgent`. It can only ever *propose and vote* there; host governance still has to pass anything it proposes. Because the agent-deal holds the host's `AgentToken`/`StakedAgent` and never the host's `MainToken`, it has no host *DAC-level* vote -- its power inside the host is bounded to deal-level agency by construction.

The home-side staked-agent proposals are:

- `HOST_STAKE` -- stake host agent tokens into a host deal; the resulting host `StakedAgent` self-delegates on mint, so the position carries voting power.
- `HOST_APPROVE_STAKE` -- approve host agent tokens for a host `ADD_STAKE` into an already-approved host deal, and delegate the host stake up front so the pulled position carries voting power.
- `HOST_APPROVE_STAKE` -- approve a host deal to pull additional stake via its own `ADD_STAKE` flow after activation.
- `HOST_CREATE_DEAL` -- originate a brand-new deal in the host DAC. Because an agent above the host's qualification threshold may propose deals, the agent-deal can act on what it observes (e.g. drones survey a field and propose a fertilizer deal). The proposer is forced to the agent-deal itself.
- `HOST_CREATE_PROPOSAL` / `HOST_VOTE` -- create and vote on staked-agent proposals inside existing host deals.
- `HOST_CLAIM_REWARD` -- claim main-token incentives the agent-deal earned in a host deal.
- `HOST_UNSTAKE` -- exit a host deal and recover the host agent tokens.
- `HOST_INVITE` -- invite an agent into a whitelist-only host deal the agent-deal originated (it is that deal's sole initial inviter).
- `RETURN_ASSET_TO_DAC` -- route earned host incentives (and any other idle foreign assets) back to the home treasury. The home main token is excluded from this path to avoid interfering with main-token obligation accounting.

Every host action takes a host deal cell and is validated against the bound host DAC's deal registry (the same `DealManager.state(...).id != 0` trust anchor used by `AgentToken`), so an agent-deal can only ever interact with deals belonging to its one bound host DAC. As with the rest of the core module, host interactions are typed kernel-interface calls on validated host contracts rather than arbitrary external calls.

## 11. Deployment Paths

### 11.1 Native DAC Bootstrap

`deployDAC(...)`:

1. predicts the `DACCell` address
2. deploys `MainToken`
3. deploys `AgentToken`
4. deploys `DACCell`
5. initializes:
   - `DealManager`
   - `ModuleRegistry`
   - `NativeAssetController`
   - `NativeGovernanceSchema`
6. initializes the root capital call

### 11.2 Existing-Token DAC Bootstrap

`deployExistingTokenDAC(...)`:

1. deploys `WrappedMainToken`
2. deploys `AgentToken`
3. deploys `BasicGovernanceOracle` (or accepts a pre-deployed shared instance via configuration)
4. deploys `DACCell`
5. initializes:
   - `DealManager`
   - `ModuleRegistry`
   - `ExistingTokenAssetController`
   - `HybridGovernanceSchema`
6. pulls a nonzero underlying-token seed donation from the creator
7. wraps it
8. deposits the wrapped balance into the controller treasury

This path emits dedicated existing-token deployment metadata for indexers.

## 12. Event Surface

Important events and their semantics:

- `ExistingTokenDACDeployed(...)`
  identifies the underlying token, wrapped token, oracle, asset controller, creator, and initial wrapped treasury seed
- `Wrapped(...)` / `Unwrapped(...)`
  provide explicit wrapper lifecycle events beyond raw ERC-20 transfers
- `GovernanceOraclePublisherUpdated(...)`
  surfaces oracle publisher role changes
- `OracleSnapshotPublished(...)` and `GovernanceOracleDeactivated(...)`
  both indexed by the DAC address, so per-DAC oracle activity can be filtered cleanly when many DACs share an oracle
- `VenueVersionApproved(...)` and `ExternalVoteApproved(...)`
  surface DACDeal external voting approvals (venue version allowlist updates and per-vote ERC-1271 signature approvals)
- `DealProposalChallenged(...)`
  surfaces the DAC challenge hold on a deal proposal
- `DealChallengeEnabled(...)`
  surfaces challenge enablement on a deal
- `AgentDistributorApproved(...)` / `AgentDistributorRevoked(...)` / `AgentTokenDistributed(...)`
  surface DAC-managed onboarding inventory and downstream distribution
- `DealRewardPoolAllocated(...)` / `DealRewardClaimed(...)`
  surface deal-local reward routing and settlement
- `ProposalResolved(...)`
  is neutral and does not carry legacy veto state
- `VotesLocked(account, amount, until)`
  emitted by `MainToken` / `WrappedMainToken` whenever governance pins voting power on an account
- `CapitalCallCreated(...)`
  carries the call's `expiry` as its last field (zero for a root call)
- `CapitalReturnFailed(dac, id, deal, token)`
  a funding token that could not be returned in a capital return; the call can be repeated
- `DealCloseHookFailed(dac, id, deal)`
  a module close hook that failed; the deal closed regardless
- `DividendSwept(payoutId, token, amount)`
  the unclaimed remainder of a dividend payout released back to the free treasury

For a full integration-oriented event and data-model guide, see the indexer/SDK handoff documents in this folder.

## 13. Design Principles

The following principles guide the protocol's architecture and inform ongoing development:

**Governance micro-kernel, not monolith.** `DACCell` is a thin routing kernel. Policy lives in the schema, accounting lives in the controller, deal execution lives in the manager. No single contract accumulates cross-cutting concerns.

**Controller-owned commitments.** Treasury balances, reward reservations, dividend payouts, and capital-call state are tracked by the asset controller, not scattered across deal or cell contracts. This creates a single source of truth for financial obligations.

**Defensive accounting.** Committed and treasury balance operations use floor-at-zero subtraction to absorb minor drift between tracked balances and actual ERC-20 balances. The protocol prefers graceful degradation over hard reverts in edge-case accounting paths.

**Module-driven extensibility.** The kernel defines deal lifecycle, evaluator routing, and state transitions. Module factories define deal behavior, evaluation logic, and reward-pool semantics. New deal types and evaluator strategies ship as new modules without kernel changes.

**Trust stratification.** Deal modules and evaluator modules can come from different approved factories. This separates the trust model for capital management from the trust model for performance evaluation, letting DACs compose risk profiles rather than accepting monolithic module bundles.

**Percent-based thresholds.** Qualification, quorum, and blocking thresholds are expressed as percentages of current supply rather than absolute token amounts. This keeps governance parameters stable across supply changes.

**Bounded governance execution.** Proposals have execution-validity windows. Challenge holds are bounded. No governance decision remains indefinitely executable, and every governance timestamp follows from configured durations rather than from the transaction that happens to observe it.

**Governance capital stays exposed.** The protocol prefers economic commitments to structural prohibitions. Opening a proposal or a challenge locks the qualifying votes for the length of the vote; an existing-token DAC can require that the capital behind a wrapped vote stays wrapped for a period it chooses. A DAC tunes how much commitment governing costs, from none to months of exposure, and the kernel enforces whatever it chose.

**Native and existing-token parity.** Both DAC modes share the same kernel interfaces. The difference is entirely in how the asset controller and governance schema are configured -- mint-backed vs. reserve-backed, direct voting vs. hybrid oracle/wrapped voting.

## 14. Supporting Libraries

The protocol uses several supporting libraries for shared logic:

- `MathLib`: fixed-point arithmetic, percentage computation (`SCALE = 1e18`), safe multiplication
- `DACErrorsLib`: centralized error definitions
- `DACEventsLib`: centralized event definitions
- `GovernanceLib`: shared governance utilities (voting math, proposal state derivation)
- `DACCellGovernanceLib`: DAC-level proposal creation, execution routing, and deal-creation orchestration
- `DealManagerLib`: deal state transitions, evaluator orchestration, reward/slash settlement
- `AssetControllerLib`: shared treasury accounting helpers

These libraries keep contract sizes manageable and provide consistent behavior across the native and existing-token code paths.
