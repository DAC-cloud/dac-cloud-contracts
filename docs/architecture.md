**DAC Cloud Architecture**
**Updated: March 13, 2026**

For repository layout, build/test commands, deployment scripts, and scenario playbooks, see [development.md](development.md).

**“Lego for Autonomous Corporations” – The Full Vision**

## 1. Executive Summary

DAC Cloud is structured as a small kernel plus pluggable execution modules:

- `DACCell` is the DAC-level governance and treasury kernel.
- `DealManager` is the DAC's execution router, deal registry, and reward accountant.
- `DealCell` is the per-deal state container and staking/governance bridge.
- `Deal` is the pluggable execution contract for a specific deal type.
- `ModuleFactory` deploys concrete deal and evaluator implementations.
- `Evaluator` returns outcome instructions for a deal.

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

## 3. System Layers

### 3.1 DAC Layer

The DAC layer is the sovereign unit:

- `DACFactory` deploys the DAC
- `DACCell` owns DAC-level governance and treasury accounting
- `MainToken` provides transferable ERC20Votes governance power
- `AgentToken` provides operator rights at the DAC level
- `DealManager` manages all deals created by the DAC

### 3.2 Deal Layer

Each deal is split into two contracts:

- `DealCell` stores deal state, tranches, deadlines, whitelist flags, capital-return accounting, and the staked-agent token
- `Deal` stores execution logic and custom module proposal handling

This split is important:
- `DealCell` is the generic governance-and-accounting shell
- `Deal` is the custom execution brain

Modules provide a concrete `Deal` implementation that extends the abstract `Deal` contract, with the custom Deal logic automatically executed through lifecycle hooks or custom deal proposals.

### 3.3 Module Layer

Modules define:
- which deal kinds are supported,
- which evaluator kinds are supported,
- how concrete deal contracts are deployed.

The current repository ships one module:
- `CoreModuleFactory`

The core module currently supports:
- `DACDeal` - represents ownership of some other's DAC MainToken, with support for governance execution
- `TreasuryDeal` - represents simple agent-enabled shared wallet
- `MilestoneBasedEvaluator` - simple evaluator based on milestones thresholds on returned capital
- `RevenueBasedEvaluator` - simple evaluator for evaluating revenue streams

## 4. Deployment Flow

### 4.1 DAC Deployment

`DACFactory.deployDAC` performs the full DAC bootstrap:

1. Predict the `DACCell` address with `CREATE2`
2. Deploy `MainToken`
3. Deploy `AgentToken`
4. Deploy the `DACCell` proxy
5. Initialize the cell with token addresses, default voting config, and the core module
6. Deploy the `DealManager` from inside `DACCell.initializeAfterDeployment`
7. Grant mint/burn privileges from the tokens to the `DealManager`
8. Create the root capital call through `initializeRootCapitalCall`

There is also a deferred-birth path:
- if `deferBirthRole` is set, the child DAC is deployed but not started,
- the deployment DNA is stored in `sleepingCells`,
- an approved external address later calls `startDAC`.

That deferred path is used by `DACDeal` when a child DAC needs to be prepared before it is fully activated.

## 5. Token Architecture

### 5.1 MainToken

`MainToken` is:
- transferable,
- vote-enabled through OpenZeppelin `ERC20Votes`,
- capped by `maxSupply`,
- mintable only by DAC-authorized minters (`DACCell` and `DealManager`).

`DealManager` tracks controlled addresses and unreleased supply so that:
- main tokens held inside DAC-controlled contracts,
- unreleased rewards,
- other locked balances

do not accidentally participate in governance.

### 5.2 AgentToken

`AgentToken` is:
- minted and revoked through DAC governance,
- stakeable into a `DealCell` before approval,
- the source asset from which deal-local `StakedAgent` voting power is derived.

### 5.3 StakedAgent

`StakedAgent` is:
- deployed per deal,
- non-transferable,
- vote-enabled,
- minted and burned only by the deal's `DealCell`.

It is the token used for deal-local governance.

## 6. DAC Governance

DAC governance lives in `DACCell` and uses `DACManagementProposal`.

### 6.1 Voting Model

Proposal voting uses:
- snapshot voting power,
- `quorumPercent`,
- `highQuorumPercent`,
- `blockingPercent`,
- `duration`,
- `qualification`.

The proposal base contract also supports:
- optional veto rights,
- early resolution when quorum conditions are met,
- blocking resolution when `noVotes` reach the blocking quorum.

### 6.2 DAC Proposal Responsibilities

The current DAC-level proposal surface includes:
- updating voting config,
- setting the legal wrapper,
- approving offchain actions,
- minting and burning `MainToken`,
- minting and revoking `AgentToken`,
- toggling dividends,
- publishing dividend payout roots,
- creating capital calls,
- approving new deals,
- approving extra tranches,
- adding and removing module factories,
- recovering closed deals,
- forwarding messages to deals,
- adding evaluators to active deals,
- delegating DAC-held voting power in any compatible token.

## 7. Deal Governance

Deal governance lives in `Deal` and uses `DealManagementProposal`.

### 7.1 Base Deal Proposal Types

The kernel-level deal proposal types are:
- update voting config,
- request tranche,
- add stake,
- permit unstake,
- enable DAC veto,
- toggle whitelist,
- toggle early returns,
- permit evaluator addition.

### 7.2 Core Module Proposal Types

The core module adds deal-specific proposal types.

For `DACDeal`:
- create child DAC proposal,
- vote child DAC proposal,
- reinvest profits,
- return profits.

For `TreasuryDeal`:
- approve direct spend,
- approve Permit2 spend,
- approve agent spend allowance,
- assign receive claimer,
- revoke agent,
- return capital to DAC,
- delegate treasury voting rights.

## 8. Deal Lifecycle

### 8.1 Creation

An agent creates a deal by calling `DealManager.createDealProposal`.

That method:
1. checks the module factory is approved and active,
2. asks the module to deploy a `DealCell`, `Deal`, and initial evaluator,
3. stores the new `DealState`,
4. auto-creates a DAC proposal of type `APPROVE_DEAL`.

At this point the deal exists, but DAC capital is not yet committed.

### 8.2 Staking

Before tranche `0` is approved:
- agents stake `AgentToken` into the `DealCell`,
- the deal mints `StakedAgent`,
- staked agents can now govern the deal.

Whitelist mode starts enabled by default:
- only the proposer is initially whitelisted,
- the proposer can invite other agents,
- deal governance can later disable the whitelist.

### 8.3 Approval and Funding

If DAC governance approves the deal:
- DAC treasury funds are transferred to `DealManager`,
- `DealManager.approveFunding` transfers tranche funds to the `DealCell`,
- `DealCell.approveFunding` forwards tranche capital to the `Deal`,
- the deal becomes active.

Extra tranches follow a two-step path:
1. staked agents approve `REQUEST_TRANCHE`
2. `DealManager` auto-creates a DAC `APPROVE_TRANCHE` proposal

### 8.4 Evaluation

Any authorized evaluator call returns an array of `EvaluationResult` actions:

- `action == 0`: slash agent stake
- `action == 1`: unlock reward percentage
- `action == 2`: extend deadline
- `action == 3`: close deal

`DealManager` applies those actions by:
- slashing `AgentToken`,
- unlocking capped claimable `MainToken`,
- extending the deal deadline,
- closing the `DealCell`.

### 8.5 Reward Claims

Unlocked rewards become claimable per staked agent.

When an agent claims:
1. `DealCell` checks its claimable amount,
2. `DealManager.mintMain` verifies the evaluator permits minting,
3. reward minting is capped by:
   - per-deal reward limit,
   - unlocked amount,
   - total DAC main-token max supply.

## 9. Capital Model

### 9.1 Root Capital Call

Every DAC starts with root capital call `nonce = 0`.

That call mints the founder's initial `MainToken` allocation once the founder deposits the committed treasury asset.

### 9.2 Treasury Accounting

`DACCell` tracks treasury balances per token in `treasuryBalances`.

Deposits can happen through:
- capital call fulfillment,
- explicit deal returns through `depositTreasury`,
- treasury recovery when tokens were sent directly.

### 9.3 Capital Return

Deals return capital through `DealCellGovernanceLib.transferCapital`:
- the deal approves the `DACCell`,
- `DACCell.depositTreasury` pulls funds in,
- returned capital is recorded per funding token.

This lets evaluators reason about how much value was actually returned to the DAC.

## 10. Core Deal Types

### 10.1 DACDeal

`DACDeal` is the child-DAC investment primitive.

It supports two modes:
- target an already deployed child DAC,
- deploy a new child DAC during deal initialization.

Important behaviors:
- tranche `0` fulfills the child DAC's root capital call,
- later tranches fulfill child capital calls referenced by hash,
- profits can be reinvested into the child DAC through deal governance,
- on close, the child DAC `MainToken` position is transferred back to the parent DAC treasury.

### 10.2 TreasuryDeal

`TreasuryDeal` is the current treasury / execution-wallet primitive.

It deploys a dedicated `Permit2Treasury` and can:
- receive tranche funding,
- approve Permit2-based spends,
- approve direct spends,
- assign agent receive rights,
- assign agent spend limits,
- return capital to the DAC,
- hold non-funding-token profits until staked agents decide how to use them.

This is the live successor to the older `VaultDeal` concept from the prototype docs.

## 11. Evaluators

### 11.1 MilestoneBasedEvaluator

This evaluator:
- stores a milestone list,
- supports holdings, FDV, and growth valuation modes,
- can unlock rewards, slash, extend, and close,
- supports per-milestone reward and penalty curves.

### 11.2 RevenueBasedEvaluator

This evaluator:
- measures revenue in periodic cycles,
- computes expected revenue from a configurable schedule,
- applies a polynomial unlock curve,
- counts missed cycles,
- applies penalties after the grace window,
- can auto-close once its reward share is fully unlocked.

## 12. Legal Wrapper and Compliance Hooks

`DACCell` stores an optional `LegalWrapper`:
- wrapper address,
- operating agreement reference,
- registered-agent metadata,
- arbitrary extra bytes.

The wrapper can:
- emit legal-wrapper messages to the DAC,
- emit legal-wrapper messages to deals through `DealManager`,
- gate execution of legally sensitive actions such as enabling dividends, removing a module or recovering the deal.

## 13. Notes On Proxy Usage

Many contracts are deployed behind `UUPSProxy`, but the runtime contracts expose no public upgrade flow.

In practice the proxy is used here as:
- an initialization wrapper,
- a reusable deployment pattern for factories,
- a deterministic deployment helper.

The operational model is still effectively non-upgradeable unless new upgrade hooks are introduced later.

## 14. Mental Model

The cleanest way to think about DAC Cloud today is:

- `DACCell` decides policy and holds the treasury view.
- `DealManager` coordinates execution and enforces reward safety.
- `DealCell` holds per-deal governance and accounting state.
- `Deal` implements business logic.
- `Evaluator` decides outcomes.
- `ModuleFactory` decides which concrete business logic exists.
