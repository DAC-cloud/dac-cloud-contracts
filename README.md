## DAC

Modular blockchain framework for operating **Decentralized Autonomous Corporations** — self-organizing entities where capital (`MainToken` holders) and managers/agents (`AgentToken` holders) are economically aligned through transparent, performance-based incentives.

## Documentation

```
src/
├── interfaces/
│   ├── Structs.sol              = Shared DAC, deal, proposal, capital-call, and evaluator structs
│   ├── IVoting.sol              = Snapshot voting interface with quorum, blocking, and veto support
│   └── ...                      = DAC, deal, evaluator, and module interfaces
├── kernel/
│   ├── governance/
│   │   ├── factories/
│   │   │   ├── DACManagementProposalFactory.sol   = factory for DAC-level `MainToken` proposals
│   │   │   └── DealManagementProposalFactory.sol  = abstract factory for deal-level `StakedAgent` proposals
│   │   ├── Proposal.sol                           = shared proposal/voting base
│   │   ├── DACManagementProposal.sol              = DAC-level governance proposal
│   │   ├── DealManagementProposal.sol             = deal-level governance proposal
│   │   ├── DACManagementProposals.sol             = DAC proposal type selectors
│   │   └── AbstractDealManagementProposals.sol    = base deal proposal type selectors
│   ├── tokens/
│   │   ├── MainToken.sol                          = transferable DAC governance/main token
│   │   ├── AgentToken.sol                         = DAC-level non-transferable operating-rights token staked into deals
│   │   └── StakedAgent.sol                        = per-deal non-transferable governance token
│   ├── DACCell.sol                                = DAC-level governance, treasury, capital calls, dividends, legal wrapper
│   ├── DealManager.sol                            = deal registry, module registry, evaluator whitelist, reward accounting
│   ├── DealCell.sol                               = per-deal state, tranches, staking, and reward accounting
│   ├── Deal.sol                                   = abstract deal logic layer with lifecycle hooks
│   └── DACFactory.sol                             = DAC deployment factory with optional deferred birth
└── modules/
    └── core/
        ├── CoreModuleDeals.sol               = selectors for core deal and evaluator types
        ├── deals/
        │   ├── DACDeal.sol                   = child-DAC funding and ownership deal
        │   ├── TreasuryDeal.sol              = governed treasury / execution wallet deal
        │   └── Permit2Treasury.sol           = Permit2-enabled treasury controlled by `TreasuryDeal`
        ├── evaluators/
        │   ├── MilestoneBasedEvaluator.sol   = milestone-based reward/slash evaluator
        │   └── RevenueBasedEvaluator.sol     = revenue-schedule reward/slash evaluator
        ├── governance/
        │   ├── factories/
        │   │   └── CoreDealManagementProposalFactory.sol = concrete factory for core deal governance
        │   └── CoreDealManagementProposals.sol           = selectors for core module deal proposals
        └── CoreModuleFactory.sol                         = active module factory shipping the core deal set
```

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

## Deployment

The deployment flow is split into two layers:

1. `DeployProtocol.s.sol` deploys the full immutable protocol stack from scratch.
2. Scenario scripts will later consume the generated manifest and seed realistic DAC / deal activity.

### Current scripts

- `script/deploy/DeployProtocol.s.sol`
  Deploys all kernel + core factories and writes a protocol manifest.
- `script/deploy/SmokeCheckProtocol.s.sol`
  Verifies the deployed factory graph against a live RPC.
- `script/deploy/PreflightProtocol.s.sol`
  Checks that all deployed manifest addresses have code and prints EIP-170 runtime margins for the largest production contracts.
- `script/scenarios/SeedBasicDAC.s.sol`
  Creates a first DAC from the deployed `DACFactory`, fulfills the root capital call, delegates founder votes, and writes a scenario manifest.
- `script/scenarios/SeedTreasuryCreateAgentMint.s.sol`
  Creates the DAC proposal that mints `AgentToken` to the treasury-flow operator.
- `script/scenarios/SeedTreasuryExecuteAgentMint.s.sol`
  Votes and executes the treasury-flow agent mint proposal.
- `script/scenarios/SeedTreasuryCreateDeal.s.sol`
  Creates the treasury deal proposal, stakes the agent, and writes deal addresses into the treasury-flow manifest.
- `script/scenarios/SeedTreasuryApproveDeal.s.sol`
  Votes and executes the DAC approval for the treasury deal.
- `script/scenarios/SeedTreasuryCreateActions.s.sol`
  Creates treasury deal governance proposals for direct spend, Permit2 spend approval, claimer assignment, and agent spend allowance.
- `script/scenarios/SeedTreasuryExecuteActions.s.sol`
  Votes and executes the created treasury proposals, then performs an example `executeAgentSpend(...)`.
- `script/scenarios/SeedChildDACCreateAgentMint.s.sol`
  Creates the DAC proposal that mints `AgentToken` to the child-flow operator.
- `script/scenarios/SeedChildDACExecuteAgentMint.s.sol`
  Votes and executes the child-flow agent mint proposal.
- `script/scenarios/SeedChildDACCreateDeal.s.sol`
  Creates the `DACDeal`, stakes the operator, and writes the pending DAC approval id.
- `script/scenarios/SeedChildDACApproveDeal.s.sol`
  Votes and executes the parent DAC approval, recording the deployed child DAC addresses.
- `script/scenarios/SeedChildDACCreateChildProposal.s.sol`
  Creates the parent-deal proposal that will spawn a child DAC management proposal.
- `script/scenarios/SeedChildDACExecuteChildProposalCreate.s.sol`
  Votes and executes the parent create-proposal, recording the child proposal id and generated parent vote proposal id.
- `script/scenarios/SeedChildDACExecuteChildProposalVote.s.sol`
  Votes through the parent deal into the child DAC and executes the child proposal.
- `script/scenarios/SeedChildDACCreateCapitalCallProposal.s.sol`
  Creates a parent-deal proposal that will create a child DAC capital call.
- `script/scenarios/SeedChildDACExecuteCapitalCallCreate.s.sol`
  Votes and executes the parent create-proposal for the child capital call, recording the generated ids.
- `script/scenarios/SeedChildDACExecuteCapitalCallVote.s.sol`
  Votes through the parent deal into the child DAC and executes the child capital call, recording the child capital-call hash.
- `script/scenarios/SeedChildDACCreateReinvestProposal.s.sol`
  Mints mock treasury profits to the parent deal and creates a `REINVEST_PROFITS` proposal.
- `script/scenarios/SeedChildDACExecuteReinvestProposal.s.sol`
  Votes and executes the reinvest proposal.
- `script/scenarios/SeedChildDACCreateReturnProfitsProposal.s.sol`
  Mints mock treasury profits to the parent deal and creates a `RETURN_PROFITS` proposal.
- `script/scenarios/SeedChildDACExecuteReturnProfitsProposal.s.sol`
  Votes and executes the return-profits proposal.

### Inputs

`DeployProtocol` currently expects these environment variables:

- `PRIVATE_KEY`
  Deployer key used by Foundry broadcast.
- `PERMIT2_ADDRESS`
  Permit2 contract address for `TreasuryDealFactory`.

`SeedBasicDAC` uses:

- `FOUNDER_PRIVATE_KEY` (optional)
  Founder / broadcaster key. Falls back to `PRIVATE_KEY`.
- `BASIC_DAC_LABEL` (optional)
  Manifest suffix, defaults to `seed`.
- `BASIC_DAC_SYMBOL` (optional)
  Defaults to `SDAC`.
- `BASIC_DAC_NAME` (optional)
  Defaults to `Seed DAC`.
- `BASIC_DAC_DESCRIPTION` (optional)
  Defaults to a local/testnet seeding description.
- `BASIC_DAC_MAX_SUPPLY` (optional)
  Defaults to `1000000000e18`.
- `BASIC_DAC_DEFAULT_QUORUM` (optional)
  Defaults to `5e17` (50% at 1e18 scale).
- `BASIC_DAC_FOUNDER_ALLOCATION` (optional)
  Defaults to `200000000e18`.
- `BASIC_DAC_FOUNDER_COMMITMENT` (optional)
  Defaults to `20000e6`.
- `BASIC_DAC_DIVIDENDS_ENABLED` (optional)
  Defaults to `false`.
- `TREASURY_TOKEN_ADDRESS` (optional)
  If omitted, the script deploys a local mintable mock token for Anvil-style runs.

### Outputs

Deployment manifests are written to:

```text
deployments/<chainid>/protocol.json
```

The manifest contains the final `DACFactory` address plus all supporting factory and reference implementation addresses.

Basic DAC scenario manifests are written to:

```text
deployments/<chainid>/basic-dac-<label>.json
```

Treasury flow manifests are written to:

```text
deployments/<chainid>/treasury-flow-<label>.json
```

Child DAC flow manifests are written to:

```text
deployments/<chainid>/child-dac-flow-<label>.json
```

### Local dry-run

This simulates the deployment and writes a local manifest without broadcasting to an RPC:

```shell
export PRIVATE_KEY=0x...
export PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3

forge script script/deploy/DeployProtocol.s.sol:DeployProtocol
```

### Local Anvil validation

For deployment validation, run Anvil with realistic code-size and block-gas constraints enabled:

```shell
anvil \
  --host 127.0.0.1 \
  --port 8545 \
  --chain-id 31337 \
  --gas-limit 30000000 \
  --code-size-limit 24576
```

Then broadcast the protocol deployment:

```shell
export PRIVATE_KEY=0x...

# For local validation, first deploy a mock Permit2:
forge create \
  script/mocks/ScriptMockPermit2.sol:ScriptMockPermit2 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key "$PRIVATE_KEY" \
  --broadcast

export PERMIT2_ADDRESS=<mock_permit2_address>

forge script \
  script/deploy/DeployProtocol.s.sol:DeployProtocol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

After broadcast, inspect the manifest:

```shell
cat deployments/31337/protocol.json
```

Then run the smoke check against the same persistent RPC:

```shell
forge script \
  script/deploy/SmokeCheckProtocol.s.sol:SmokeCheckProtocol \
  --rpc-url http://127.0.0.1:8545
```

Run the stricter preflight check against the same manifest and RPC:

```shell
forge script \
  script/deploy/PreflightProtocol.s.sol:PreflightProtocol \
  --rpc-url http://127.0.0.1:8545
```

Seed the first DAC scenario:

```shell
export FOUNDER_PRIVATE_KEY="$PRIVATE_KEY"

forge script \
  script/scenarios/SeedBasicDAC.s.sol:SeedBasicDAC \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Inspect the seeded DAC manifest:

```shell
cat deployments/31337/basic-dac-seed.json
```

Seed the staged treasury flow:

```shell
export AGENT_PRIVATE_KEY=0x...

forge script \
  script/scenarios/SeedTreasuryCreateAgentMint.s.sol:SeedTreasuryCreateAgentMint \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedTreasuryExecuteAgentMint.s.sol:SeedTreasuryExecuteAgentMint \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedTreasuryCreateDeal.s.sol:SeedTreasuryCreateDeal \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedTreasuryApproveDeal.s.sol:SeedTreasuryApproveDeal \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedTreasuryCreateActions.s.sol:SeedTreasuryCreateActions \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedTreasuryExecuteActions.s.sol:SeedTreasuryExecuteActions \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Inspect the treasury flow manifest:

```shell
cat deployments/31337/treasury-flow-treasury.json
```

Seed the staged child DAC flow:

```shell
export AGENT_PRIVATE_KEY=0x...

forge script \
  script/scenarios/SeedChildDACCreateAgentMint.s.sol:SeedChildDACCreateAgentMint \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedChildDACExecuteAgentMint.s.sol:SeedChildDACExecuteAgentMint \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedChildDACCreateDeal.s.sol:SeedChildDACCreateDeal \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedChildDACApproveDeal.s.sol:SeedChildDACApproveDeal \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedChildDACCreateChildProposal.s.sol:SeedChildDACCreateChildProposal \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedChildDACExecuteChildProposalCreate.s.sol:SeedChildDACExecuteChildProposalCreate \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

forge script \
  script/scenarios/SeedChildDACExecuteChildProposalVote.s.sol:SeedChildDACExecuteChildProposalVote \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Important:

- `SmokeCheckProtocol` must be run against a persistent node where the deployment was actually broadcast.
- `PreflightProtocol` also requires a persistent node with the manifest addresses actually deployed.
- Running it as an isolated dry-run VM will fail, because the manifest points to contracts that only exist on the target chain.
- Treasury scenario scripts are intentionally split wherever governance snapshots depend on prior blocks.
- On real testnets, separate broadcasts naturally land in later blocks.
- On fast local Anvil runs, if two governance phase scripts land with the same timestamp, advance one block between them before voting:

```shell
cast rpc --rpc-url http://127.0.0.1:8545 evm_increaseTime 1
cast rpc --rpc-url http://127.0.0.1:8545 evm_mine
```

### Transaction model

The deployment script uses `vm.startBroadcast(...)`, so it does **not** try to deploy the whole protocol in one giant transaction.

Each top-level contract creation after `startBroadcast()` becomes its own broadcast transaction. That means:

- real block gas limits are enforced per deployment transaction
- EIP-170 code-size limits are enforced by the target node
- deployment is far less likely to hit a single EIP-7825 gas ceiling
