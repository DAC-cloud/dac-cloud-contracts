# DAC Cloud Architecture

Updated: March 25, 2026

For the contract-by-contract inventory, see [contracts.md](contracts.md). For build, test, deployment, and scenario scripts, see [development.md](development.md).

## 1. Summary

DAC Cloud is a governance micro-kernel for modular onchain corporations.

At the current implementation stage, the architecture is intentionally split into four concerns:

- `DACCell`: DAC identity, legal-wrapper integration, proposal routing, and DAC-level execution entrypoints
- `GovernanceSchema`: DAC proposal policy, qualification, quorum rules, and proposal deployment
- `AssetController`: treasury custody/accounting and DAC main-asset policy
- `DealManager`: deal lifecycle, evaluator routing, and module-driven execution

This split replaces the older model where DAC governance, treasury accounting, and deal accounting all accumulated inside `DACCell`, `DealManager`, and DAC-side libraries.

## 2. Core Philosophy & Origin Story

DAC Cloud was born from a simple but powerful observation: **modern organizations are too rigid, while blockchains are too chaotic**.

Traditional corporations are hierarchical, slow to adapt, and misaligned between capital and execution. Classic DAOs are transparent but suffer from speculation, low skin-in-the-game for managers, and governance theater.

The original "DAC engine" idea of 2021–2022 captured the essence perfectly: large organizations should reorganize as **trees of small, autonomous DACs** — agile teams of 5–9 people (Scrum-sized) operating as independent economic entities that make deals with each other and with the outside world.

From these ideas DAC engine was born originally as a "Scrum-plugin" to enhance brand-aggregators and venture-studios businesses. With the rise of AI agents in 2026, the protocol was reborn as a corporation-as-code framework for EVM.

This is the **lego idea** at the heart of DAC Cloud.

Every team, product group, or service unit becomes its own **DAC** — a lightweight, self-sovereign corporation with its own treasury, governance, and incentives. These DACs connect through **Deals** (capital calls, service agreements, revenue shares) and settle payments instantly via x402, Permit2, or direct ERC-20 transfers.

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

This is still the simplest launch path for a new tokenized organization.

#### 2.1.2 Existing-Token DAC

Existing-token DACs attach governance and deal logic to an already circulating token:

- deploy a `WrappedMainToken`
- deploy a `GovernanceOracle`
- use `HybridGovernanceSchema`
- use `ExistingTokenAssetController`
- seed the DAC treasury by wrapping a nonzero donation of the underlying token during DAC creation
- treat main-asset rewards and dividends as reserve-backed claims against wrapped reserves

This lets teams adopt DAC governance and deal mechanics without replacing a live token.

## 3. Core Components

### 3.1 DACFactory

`DACFactory` is the bootstrap entrypoint.

It currently exposes two deployment paths:

- `deployDAC(...)` for native DACs
- `deployExistingTokenDAC(...)` for existing-token DACs

The factory deploys proxies for the kernel subcomponents through dedicated factories and then wires them together. For existing-token DACs it also deploys the wrapper/oracle pair and performs the initial wrapped-treasury seed.

### 3.2 DACCell

`DACCell` is now a thinner DAC kernel.

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

`DACCell` doesnt't own deals, treasury balances or main-token obligation accounting.

### 3.3 GovernanceSchema

The governance schema owns DAC-level governance policy.

Current implementations:

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

Current implementations:

- `NativeAssetController`
- `ExistingTokenAssetController`

The controller owns:

- treasury custody (`treasuryHolder()`)
- treasury balance accounting
- treasury sync / recovery logic
- capital-call state
- dividend payout commitments and claims
- main-token reward obligations
- settlement of main rewards
- controlled-address / non-votable-balance exclusions
- capability checks for mint / burn / capital-call support

DAC treasury state is controller-owned, not cell-owned.

### 3.5 DealManager

`DealManager` is focused on deal lifecycle, not DAC treasury policy.

It owns:

- deal registry
- deal creation
- module validation
- evaluator installation and permissioning
- evaluator execution
- deal state transitions such as approval, close, recovery eligibility, and reward/slash orchestration

Where DAC-level token accounting is needed, `DealManager` now calls into the active `AssetController`.

### 3.6 ModuleRegistry

Approved module state now lives in `ModuleRegistry`, not `DealManager`.

This keeps module approval semantically owned by the DAC kernel while keeping the registry logic out of the manager itself.

`DACCell` owns approval authority.
`DealManager` and other components query the registry.

## 4. Token Model

### 4.1 MainToken

In native mode, `MainToken` remains the DAC governance token:

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

`AgentToken` remains the DAC-level operator token:

- minted and revoked by DAC governance
- required for deal participation
- subject to deal-creation anti-spam checks through `DealCreationConfig`

### 4.4 StakedAgent

`StakedAgent` remains the deal-local governance token:

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

### 5.3 Governance Oracle

`GovernanceOracle` is the publisher for proposal-specific Merkle snapshots in hybrid mode.

Important properties:

- oracle snapshots are proposal-specific
- each snapshot includes:
  - `snapshotBlock`
  - `merkleRoot`
  - `totalUnderlyingVotingPower`
  - `publishedAt`
- the oracle can be deactivated by authorized actors
- deactivation forces active hybrid proposals into the fallback path
- DAC governance can replace the oracle instance with a new one

### 5.4 Qualification

Proposal qualification now uses delegated voting power rather than raw token balances:

- native DAC proposals: delegated `MainToken` votes
- hybrid DAC proposals: delegated `WrappedMainToken` votes
- deal proposals: delegated `StakedAgent` votes

This makes governance participation more intentional and gives communities a way to raise proposer thresholds without forcing token transfers.

## 6. Deal Creation and Anti-Spam Controls

DAC-level governance can configure:

- `minAgentBalance`
- `minInitialAgentStake`

through `DealCreationConfig`.

These values apply when creating a new deal proposal:

- proposer must hold at least the configured `AgentToken` balance
- proposer must commit an initial stake into the new deal

This prevents unbacked deal creation and ties proposal spam resistance to real operator capital.

## 7. Deal Governance Model

Deal governance intentionally remains separate from DAC governance.

It still uses `DealManagementProposal` on `StakedAgent`, but the DAC interaction model changed materially:

- DAC-level proposals no longer have veto semantics
- instead, DAC governance can open a bounded challenge against a challengeable deal proposal
- challenge state now lives on the deal proposal contract itself, not on `Deal`
- deal execution is delayed, not vote resolution

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

Both DAC and deal proposals now have execution-validity windows.

That means:

- a proposal can pass
- remain executable only for a bounded duration
- then become stale if not executed

This avoids indefinitely executable governance decisions and makes challenge delays bounded and explicit.

## 8. Treasury and Main-Asset Accounting

One of the largest refactor outcomes is the move to controller-owned commitments.

### 8.1 Native Mode

Native mode still supports mint-backed main-token flows, but the accounting now lives in the asset controller.

The controller tracks:

- treasury-held `MainToken`
- main-token obligations
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

The existing-token flow therefore behaves more like reserved treasury accounting than mint-headroom accounting.

## 9. Capital Calls and Dividends

Capital calls and dividends are now routed through the asset controller.

This is important because obligations are no longer just a main-token problem.

Current implications:

- capital calls are tracked centrally by the controller
- dividend payouts reserve actual treasury balances
- claims settle against controller-held state
- arbitrary treasury assets such as USDC are tracked consistently with the same commitment discipline

## 10. Module System

Modules remain the execution extension point.

Each module factory exposes:

- module id
- semantic version
- manifest URI
- supported deal kinds
- supported evaluator kinds

The current shipped module is `CoreModuleFactory`, which includes:

- `DACDeal`
- `TreasuryDeal`
- `MilestoneBasedEvaluator`
- `RevenueBasedEvaluator`

Module deals can emit standardized `DealRelatedContract` events so indexers can discover runtime-linked addresses such as:

- treasury contracts
- child DACs
- child tokens

without module-specific storage reads.

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
3. deploys `GovernanceOracle`
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

The event catalog now reflects the refactor more closely.

Important additions and semantics:

- `ExistingTokenDACDeployed(...)`
  identifies the underlying token, wrapped token, oracle, asset controller, creator, and initial wrapped treasury seed
- `Wrapped(...)` / `Unwrapped(...)`
  provide explicit wrapper lifecycle events beyond raw ERC-20 transfers
- `GovernanceOraclePublisherUpdated(...)`
  surfaces oracle publisher role changes
- `DealProposalChallenged(...)`
  surfaces the DAC challenge hold on a deal proposal
- `DealChallengeEnabled(...)`
  replaces the old veto-right enablement event
- `ProposalResolved(...)`
  is now neutral and no longer carries a stale `vetoed` field

For a full integration-oriented event and data-model guide, see the indexer/SDK handoff document referenced from the repo root.

## 13. Current Architectural Direction

The current codebase is still recognizably DAC Cloud, but it now operates with cleaner boundaries:

- `DACCell` is much closer to a real governance micro-kernel
- `DealManager` is much closer to a real deal lifecycle controller
- DAC governance policy is schema-owned
- DAC treasury and main-asset policy are controller-owned
- native and existing-token modes coexist without turning the kernel into a single-mode special case

That is the main architectural outcome of this iteration.
