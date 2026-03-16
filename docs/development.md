# DAC Cloud Development Guide

Updated: March 13, 2026

This guide covers local development, test commands, deployment scripts, and manifest-driven scenario seeding.

## 1. Tooling

DAC Cloud is built around Foundry.

Recommended local tools:

- `forge`
- `cast`
- `anvil`

If Foundry is installed under `~/.foundry/bin`, add it to your shell path:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
```

## 2. Common Commands

Build:

```bash
forge build
```

Run tests:

```bash
forge test
```

Generate coverage:

```bash
forge coverage --report summary
```

Inspect contract sizes:

```bash
forge build --sizes
```

## 3. Deployment Model

The protocol is intentionally non-upgradeable at the kernel and core-module level.

Deployment scripts therefore:

- redeploy the full stack from scratch,
- wire all factories together,
- produce a fresh `DACFactory`,
- write a manifest under `deployments/<chainid>/`.

The deployment script is multi-transaction, not monolithic: each top-level deployment after `vm.startBroadcast(...)` is broadcast as its own transaction.

The deployment flow is split into two layers:

1. protocol deployment and validation,
2. scenario seeding that consumes the written manifests.

## 4. Script Layout

### Shared script helpers

- `script/common/ScriptTypes.sol`
  Shared config and manifest structs.
- `script/common/ScriptConfig.sol`
  Environment-variable loading and default values.
- `script/common/ManifestIO.sol`
  Read/write helpers for deployment and scenario manifests.

### Deployment scripts

- `script/deploy/DeployProtocol.s.sol`
  Deploys the full protocol stack and writes `protocol.json`.
- `script/deploy/SmokeCheckProtocol.s.sol`
  Checks the deployment graph against a live RPC.
- `script/deploy/PreflightProtocol.s.sol`
  Verifies code exists at manifest addresses and prints runtime size margins for key contracts.

### Scenario helpers

- `script/scenarios/ScenarioGovernanceBase.sol`
  Shared DAC and deal proposal create/vote/execute helpers.
- `script/scenarios/TreasuryFlowBase.sol`
  Shared treasury-flow setup helpers.
- `script/scenarios/ChildDACFlowBase.sol`
  Shared child-DAC flow helpers.

### Local mock contracts

- `script/mocks/ScriptMockPermit2.sol`
  Local mock Permit2 for Anvil validation.
- `script/mocks/ScriptMintableERC20.sol`
  Local mintable ERC-20 for seeded treasury flows.

## 5. Environment Inputs

### Required for protocol deployment

- `PRIVATE_KEY`
  Broadcaster/deployer key.
- `PERMIT2_ADDRESS`
  Permit2 address used by `TreasuryDealFactory`.

### Common optional inputs

- `FOUNDER_PRIVATE_KEY`
  Founder key. Falls back to `PRIVATE_KEY`.
- `AGENT_PRIVATE_KEY`
  Operator key for staged treasury and child-DAC flows.
- `TREASURY_TOKEN_ADDRESS`
  Treasury token to use for a seeded DAC. If omitted in local flows, scripts can deploy a mock token.
- `RECIPIENT_ADDRESS`
  Optional recipient used by scenario flows.

### Basic DAC seed config

- `BASIC_DAC_LABEL`
- `BASIC_DAC_SYMBOL`
- `BASIC_DAC_NAME`
- `BASIC_DAC_DESCRIPTION`
- `BASIC_DAC_MAX_SUPPLY`
- `BASIC_DAC_DEFAULT_QUORUM`
- `BASIC_DAC_FOUNDER_ALLOCATION`
- `BASIC_DAC_FOUNDER_COMMITMENT`
- `BASIC_DAC_DIVIDENDS_ENABLED`

### Treasury flow config

- `TREASURY_FLOW_LABEL`
- `TREASURY_FLOW_BASIC_DAC_LABEL`
- `TREASURY_FLOW_AGENT_MINT_AMOUNT`
- `TREASURY_FLOW_STAKE_AMOUNT`
- `TREASURY_FLOW_FUNDING_AMOUNT`
- `TREASURY_FLOW_REWARDS_LIMIT`
- `TREASURY_FLOW_EXPECTED_RETURN`
- `TREASURY_FLOW_DIRECT_SPEND_AMOUNT`
- `TREASURY_FLOW_PERMIT2_SPEND_AMOUNT`
- `TREASURY_FLOW_ASSIGN_CLAIM_AMOUNT`
- `TREASURY_FLOW_AGENT_SPEND_TOTAL_AMOUNT`
- `TREASURY_FLOW_AGENT_SPEND_SINGLE_AMOUNT`
- `TREASURY_FLOW_AGENT_SPEND_DURATION`

### Child DAC flow config

- `CHILD_FLOW_LABEL`
- `CHILD_FLOW_BASIC_DAC_LABEL`
- `CHILD_FLOW_AGENT_MINT_AMOUNT`
- `CHILD_FLOW_STAKE_AMOUNT`
- `CHILD_FLOW_FUNDING_AMOUNT`
- `CHILD_FLOW_REWARDS_LIMIT`
- `CHILD_FLOW_MANAGED_EQUITY`
- `CHILD_FLOW_MAIN_MAX_SUPPLY`
- `CHILD_FLOW_DEFAULT_QUORUM`
- `CHILD_FLOW_CHILD_MINT_AGENT_AMOUNT`
- `CHILD_FLOW_CAPITAL_CALL_TOKEN_AMOUNT`
- `CHILD_FLOW_CAPITAL_CALL_CASH_AMOUNT`
- `CHILD_FLOW_REINVEST_AMOUNT`
- `CHILD_FLOW_RETURN_PROFIT_AMOUNT`

## 6. Manifest Outputs

Protocol deployment:

```text
deployments/<chainid>/protocol.json
```

Basic DAC seed:

```text
deployments/<chainid>/basic-dac-<label>.json
```

Treasury flow seed:

```text
deployments/<chainid>/treasury-flow-<label>.json
```

Child DAC flow seed:

```text
deployments/<chainid>/child-dac-flow-<label>.json
```

These manifests are intended to be consumed by later scripts, indexers, SDK tooling, and frontends.

## 7. Local Dry-Run

This runs the deployment script without broadcasting to a chain:

```bash
export PRIVATE_KEY=0x...
export PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3

forge script script/deploy/DeployProtocol.s.sol:DeployProtocol
```

## 8. Local Anvil Validation

Run Anvil with realistic code-size and block-gas constraints:

```bash
anvil \
  --host 127.0.0.1 \
  --port 8545 \
  --chain-id 31337 \
  --gas-limit 25000000 \
  --code-size-limit 24576
```

Deploy a local mock Permit2:

```bash
export PRIVATE_KEY=0x...

forge create \
  script/mocks/ScriptMockPermit2.sol:ScriptMockPermit2 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Set the mock address and deploy the protocol:

```bash
export PERMIT2_ADDRESS=<mock_permit2_address>

forge script \
  script/deploy/DeployProtocol.s.sol:DeployProtocol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --skip-simulation \
  --slow
```

Run deployment validation:

```bash
forge script \
  script/deploy/SmokeCheckProtocol.s.sol:SmokeCheckProtocol \
  --rpc-url http://127.0.0.1:8545

forge script \
  script/deploy/PreflightProtocol.s.sol:PreflightProtocol \
  --rpc-url http://127.0.0.1:8545
```

## 9. Scenario Seeding

### Basic DAC

`SeedBasicDAC.s.sol` creates a first DAC from the deployed `DACFactory`, fulfills the root capital call, delegates founder votes, and writes a scenario manifest.

Run:

```bash
export FOUNDER_PRIVATE_KEY="$PRIVATE_KEY"

forge script \
  script/scenarios/SeedBasicDAC.s.sol:SeedBasicDAC \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

### Treasury flow

The treasury scenario is intentionally staged across multiple scripts so proposal creation, voting, and execution can happen in separate transactions and separate blocks.

Current staged scripts:

- `SeedTreasuryCreateAgentMint.s.sol`
- `SeedTreasuryExecuteAgentMint.s.sol`
- `SeedTreasuryCreateDeal.s.sol`
- `SeedTreasuryApproveDeal.s.sol`
- `SeedTreasuryCreateActions.s.sol`
- `SeedTreasuryExecuteActions.s.sol`

This flow creates a treasury deal and seeds realistic activity around:

- direct spend approvals,
- Permit2 approvals,
- receive claim permissions,
- agent spend allowances,
- actual `executeAgentSpend(...)` usage.

### Child DAC flow

The child-DAC scenario is also staged across multiple scripts:

- `SeedChildDACCreateAgentMint.s.sol`
- `SeedChildDACExecuteAgentMint.s.sol`
- `SeedChildDACCreateDeal.s.sol`
- `SeedChildDACApproveDeal.s.sol`
- `SeedChildDACCreateChildProposal.s.sol`
- `SeedChildDACExecuteChildProposalCreate.s.sol`
- `SeedChildDACExecuteChildProposalVote.s.sol`
- `SeedChildDACCreateCapitalCallProposal.s.sol`
- `SeedChildDACExecuteCapitalCallCreate.s.sol`
- `SeedChildDACExecuteCapitalCallVote.s.sol`
- `SeedChildDACCreateReinvestProposal.s.sol`
- `SeedChildDACExecuteReinvestProposal.s.sol`
- `SeedChildDACCreateReturnProfitsProposal.s.sol`
- `SeedChildDACExecuteReturnProfitsProposal.s.sol`

This flow seeds a `DACDeal` lifecycle covering:

- parent DAC deal approval,
- child DAC creation,
- child proposal creation and parent-mediated vote,
- child capital call creation and parent-mediated vote,
- reinvested profits,
- returned profits.

## 10. Local Timestamp Caveat

Proposal voting in this repository uses timestamp-based snapshots through ERC-6372 / ERC-5805-compatible vote checkpoints.

On fast local Anvil runs, creating a proposal and voting it immediately can land in the same timestamp and trigger future-lookup snapshot failures.

When running staged scripts locally, advance time between proposal creation and the next voting phase:

```bash
cast rpc --rpc-url http://127.0.0.1:8545 evm_increaseTime 1
cast rpc --rpc-url http://127.0.0.1:8545 evm_mine
```

This is generally not needed on real testnets, where proposal creation and later voting naturally occur in different blocks and timestamps.

## 11. Recommended Contributor Workflow

1. `forge build`
2. `forge test`
3. `forge coverage --report summary`
4. `forge build --sizes`
5. Validate deployment and scenario scripts on constrained local Anvil
6. Use the generated manifests as fixtures for indexer, SDK, and frontend work
