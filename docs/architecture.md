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
- auto-self-delegates on first wrap
- reports moves and delegations to the asset controller
- is the asset used for:
  - wrapper-based qualification
  - wrapped voting in hybrid primary mode
  - fallback voting
  - reserve-backed rewards/dividends

### 4.3 AgentToken

`AgentToken` is the DAC-level operator token:

- minted and revoked by DAC governance
- can be minted either:
  - directly to a bound agent address, or
  - into DAC-approved distributor inventory
- required for deal participation
- subject to deal-creation anti-spam checks through `DealCreationConfig`

#### 4.3.1 Distributor flow

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

### 4.4 StakedAgent

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

### 5.3 Hybrid Strategy Tweaks

Hybrid governance strategy has three important toggles:

- `blockingOnAllProposals`
- `blockingOnHighQuorum`
- `oraclePrimaryEnabled`

These let an existing-token DAC choose between:

- full oracle-primary hybrid mode
- wrapped-only bootstrap mode
- more defensive blocking settings during early community formation

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
  - `snapshotBlock`
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

Qualification thresholds are **percent-based**. A qualification value ranges from 0 to `1e18` (where `1e18 = SCALE = 100%`). The effective threshold is computed at runtime as:

```
threshold = MathLib.mul(totalVotingSupply, qualificationPercent)
```

Because the threshold is derived from current total voting supply, it scales automatically as supply changes -- new mints, burns, wraps, or unwraps shift the absolute threshold without requiring governance to update qualification parameters.

This makes governance participation intentional and gives communities a way to set proposer thresholds that remain meaningful regardless of supply dynamics.

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
- claims settle against controller-held state
- arbitrary treasury assets such as USDC are tracked consistently with the same commitment discipline

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
- `MilestoneBasedEvaluator`
- `RevenueBasedEvaluator`

The core module declares support for deal reward pools on both shipped deal kinds.

Module deals can emit standardized `DealRelatedContract` events so indexers can discover runtime-linked addresses such as:

- treasury contracts
- child DACs
- child tokens

without module-specific storage reads.

### 10.1 DACDeal External Voting

`DACDeal` holds a child DAC's `MainToken` balance after capital calls fulfill — that balance is delegated to the deal itself, giving the deal voting power inside the child DAC. Two paths exist for using that voting power:

**On-chain child DAC governance.** `CREATE_DAC_PROPOSAL` and `VOTE_DAC_PROPOSAL` let staked-pigs propose and vote on the child DAC's own management proposals. This path is direct and synchronous.

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

For a full integration-oriented event and data-model guide, see the indexer/SDK handoff document referenced from the repo root.

## 13. Design Principles

The following principles guide the protocol's architecture and inform ongoing development:

**Governance micro-kernel, not monolith.** `DACCell` is a thin routing kernel. Policy lives in the schema, accounting lives in the controller, deal execution lives in the manager. No single contract accumulates cross-cutting concerns.

**Controller-owned commitments.** Treasury balances, reward reservations, dividend payouts, and capital-call state are tracked by the asset controller, not scattered across deal or cell contracts. This creates a single source of truth for financial obligations.

**Defensive accounting.** Committed and treasury balance operations use floor-at-zero subtraction to absorb minor drift between tracked balances and actual ERC-20 balances. The protocol prefers graceful degradation over hard reverts in edge-case accounting paths.

**Module-driven extensibility.** The kernel defines deal lifecycle, evaluator routing, and state transitions. Module factories define deal behavior, evaluation logic, and reward-pool semantics. New deal types and evaluator strategies ship as new modules without kernel changes.

**Trust stratification.** Deal modules and evaluator modules can come from different approved factories. This separates the trust model for capital management from the trust model for performance evaluation, letting DACs compose risk profiles rather than accepting monolithic module bundles.

**Percent-based thresholds.** Qualification, quorum, and blocking thresholds are expressed as percentages of current supply rather than absolute token amounts. This keeps governance parameters stable across supply changes.

**Bounded governance execution.** Proposals have execution-validity windows. Challenge holds are bounded. No governance decision remains indefinitely executable.

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
