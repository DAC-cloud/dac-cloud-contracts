# DAC Cloud Development Guide

Updated: April 3, 2026

This guide covers local development, test commands, deployment scripts, and manifest-driven scenario seeding.

For contract topology, see [architecture.md](architecture.md). For indexer / SDK integration-oriented protocol surfaces, see [indexer-sdk-handoff.md](indexer-sdk-handoff.md).

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
- `script/scenarios/ExistingGovernanceFlowBase.sol`
  Shared existing-token DAC hybrid-governance helpers.
- `script/scenarios/ExistingTreasuryFlowBase.sol`
  Shared existing-token treasury-deal seeding helpers.
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

### Existing-token DAC seed config

- `EXISTING_DAC_LABEL`
- `EXISTING_DAC_SYMBOL`
- `EXISTING_DAC_NAME`
- `EXISTING_DAC_DESCRIPTION`
- `EXISTING_DAC_DIVIDENDS_ENABLED`
- `EXISTING_DAC_UNDERLYING_TOKEN_ADDRESS`
- `EXISTING_DAC_MOCK_TOKEN_DECIMALS`
- `EXISTING_DAC_MOCK_TOKEN_MINT`
- `EXISTING_DAC_WRAP_AMOUNT`
- `EXISTING_DAC_TREASURY_SEED`
- `EXISTING_DAC_ORACLE_ADMIN_ADDRESS`
- `EXISTING_DAC_ORACLE_PUBLISHER_ADDRESS`
- `EXISTING_DAC_DEFAULT_QUORUM`
- `EXISTING_DAC_HIGH_QUORUM`
- `EXISTING_DAC_BLOCKING_QUORUM`
- `EXISTING_DAC_DURATION`
- `EXISTING_DAC_QUALIFICATION`
- `EXISTING_DAC_EXECUTION_VALIDITY`
- `EXISTING_DAC_ORACLE_PUBLISH_DEADLINE`
- `EXISTING_DAC_FALLBACK_WARMUP`
- `EXISTING_DAC_FALLBACK_DURATION`

### Existing governance flow config

- `EXISTING_GOV_FLOW_LABEL`
- `EXISTING_GOV_FLOW_EXISTING_DAC_LABEL`
- `EXISTING_GOV_FLOW_AGENT_MINT_AMOUNT`
- `EXISTING_GOV_FLOW_MERKLE_INDEX`
- `EXISTING_GOV_FLOW_MERKLE_AMOUNT`

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

### Existing treasury flow config

- `EXISTING_TREASURY_FLOW_LABEL`
- `EXISTING_TREASURY_FLOW_EXISTING_DAC_LABEL`
- `EXISTING_TREASURY_FLOW_AGENT_MINT_AMOUNT`
- `EXISTING_TREASURY_FLOW_STAKE_AMOUNT`
- `EXISTING_TREASURY_FLOW_FUNDING_AMOUNT`
- `EXISTING_TREASURY_FLOW_REWARDS_LIMIT`
- `EXISTING_TREASURY_FLOW_EXPECTED_RETURN`
- `EXISTING_TREASURY_FLOW_MERKLE_INDEX`
- `EXISTING_TREASURY_FLOW_MERKLE_AMOUNT`

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

Existing-token DAC seed:

```text
deployments/<chainid>/existing-dac-<label>.json
```

Existing governance flow seed:

```text
deployments/<chainid>/existing-governance-flow-<label>.json
```

Treasury flow seed:

```text
deployments/<chainid>/treasury-flow-<label>.json
```

Existing treasury flow seed:

```text
deployments/<chainid>/existing-treasury-flow-<label>.json
```

Child DAC flow seed:

```text
deployments/<chainid>/child-dac-flow-<label>.json
```

These manifests are intended to be consumed by later scripts, indexers, SDK tooling, and frontends.

## 7. Current Seeded Surface

The staged scripts now cover the full core entity set needed for local indexer / SDK work:

- protocol deployment
- native DAC bootstrap
- existing-token DAC bootstrap
- hybrid governance primary and fallback flows
- treasury deals for both DAC modes
- child-DAC deals for both DAC modes
- child proposal / capital-call / reinvest / return-profit flows

On very fast local Anvil instances, proposal creation and voting may still require a small `evm_increaseTime 1` + `evm_mine` step between phases for deterministic local runs.

## 8. Local Dry-Run

This runs the deployment script without broadcasting to a chain:

```bash
export PRIVATE_KEY=0x...
export PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3

forge script script/deploy/DeployProtocol.s.sol:DeployProtocol
```

## 9. Local Anvil Validation

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

## 10. Scenario Seeding

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

### Existing-token DAC

`SeedExistingTokenDAC.s.sol` creates a DAC around an existing token, deploys the wrapped governance token and governance oracle, optionally wraps founder inventory, and can pre-seed wrapped treasury reserves into the asset controller.

Useful environment variables for this mode:

- `EXISTING_DAC_LABEL`
- `EXISTING_DAC_SYMBOL`
- `EXISTING_DAC_NAME`
- `EXISTING_DAC_DESCRIPTION`
- `EXISTING_DAC_DIVIDENDS_ENABLED`
- `EXISTING_DAC_UNDERLYING_TOKEN_ADDRESS`
- `EXISTING_DAC_MOCK_TOKEN_DECIMALS`
- `EXISTING_DAC_MOCK_TOKEN_MINT`
- `EXISTING_DAC_WRAP_AMOUNT`
- `EXISTING_DAC_TREASURY_SEED`
- `EXISTING_DAC_ORACLE_ADMIN_ADDRESS`
- `EXISTING_DAC_ORACLE_PUBLISHER_ADDRESS`
- `EXISTING_DAC_DEFAULT_QUORUM`
- `EXISTING_DAC_HIGH_QUORUM`
- `EXISTING_DAC_BLOCKING_QUORUM`
- `EXISTING_DAC_DURATION`
- `EXISTING_DAC_QUALIFICATION`
- `EXISTING_DAC_EXECUTION_VALIDITY`
- `EXISTING_DAC_ORACLE_PUBLISH_DEADLINE`
- `EXISTING_DAC_FALLBACK_WARMUP`
- `EXISTING_DAC_FALLBACK_DURATION`

Run:

```bash
export FOUNDER_PRIVATE_KEY="$PRIVATE_KEY"

forge script \
  script/scenarios/SeedExistingTokenDAC.s.sol:SeedExistingTokenDAC \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Notes:

- If `EXISTING_DAC_UNDERLYING_TOKEN_ADDRESS` is not provided, the script deploys a mock underlying token and mints it to the broadcaster.
- `EXISTING_DAC_TREASURY_SEED` cannot exceed `EXISTING_DAC_WRAP_AMOUNT`.
- The founder must retain more wrapped tokens than the configured qualification, otherwise the script refuses to move too much wrapped balance into treasury and strand proposer rights.
- `EXISTING_DAC_EXECUTION_VALIDITY` controls how long passed DAC proposals remain executable after resolution.

### Existing-token DAC governance flow

The hybrid-governance scenario is intentionally staged to reflect live-chain role and timing boundaries:

- `SeedExistingGovernanceCreatePrimary.s.sol`
- `SeedExistingGovernancePublishPrimary.s.sol`
- `SeedExistingGovernanceVotePrimary.s.sol`
- `SeedExistingGovernanceExecutePrimary.s.sol`
- `SeedExistingGovernanceCreateFallback.s.sol`
- `SeedExistingGovernanceBeginFallbackWarmup.s.sol`
- `SeedExistingGovernanceActivateFallback.s.sol`
- `SeedExistingGovernanceVoteFallback.s.sol`
- `SeedExistingGovernanceExecuteFallback.s.sol`

Primary mode uses a single-leaf Merkle snapshot by default:

- account: founder
- index: `EXISTING_GOV_FLOW_MERKLE_INDEX`
- amount: `EXISTING_GOV_FLOW_MERKLE_AMOUNT`, or the founder's current unwrapped underlying balance if omitted

That keeps local and early testnet seeding simple while still exercising the real hybrid path: oracle publish, primary activation, wrapped voting, Merkle voting, and proposal execution.

Example primary sequence:

```bash
forge script script/scenarios/SeedExistingTokenDAC.s.sol:SeedExistingTokenDAC --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernanceCreatePrimary.s.sol:SeedExistingGovernanceCreatePrimary --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernancePublishPrimary.s.sol:SeedExistingGovernancePublishPrimary --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernanceVotePrimary.s.sol:SeedExistingGovernanceVotePrimary --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernanceExecutePrimary.s.sol:SeedExistingGovernanceExecutePrimary --rpc-url <rpc> --broadcast
```

Example fallback sequence:

```bash
forge script script/scenarios/SeedExistingGovernanceCreateFallback.s.sol:SeedExistingGovernanceCreateFallback --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernanceBeginFallbackWarmup.s.sol:SeedExistingGovernanceBeginFallbackWarmup --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernanceActivateFallback.s.sol:SeedExistingGovernanceActivateFallback --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernanceVoteFallback.s.sol:SeedExistingGovernanceVoteFallback --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingGovernanceExecuteFallback.s.sol:SeedExistingGovernanceExecuteFallback --rpc-url <rpc> --broadcast
```

Role note:

- `SeedExistingGovernancePublishPrimary` must be run by an address that has publisher rights on the governance oracle.

Local timing note:

- for fallback validation on Anvil, advance time between proposal creation and warmup start, and again between warmup start and fallback activation.

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

### Existing-token treasury flow

The existing-token treasury scenario stages the same basic treasury-deal creation path against a hybrid-governed DAC, using wrapped main-token reserves as the funding token.

Current staged scripts:

- `SeedExistingTreasuryCreateAgentMint.s.sol`
- `SeedExistingTreasuryPublishAgentMint.s.sol`
- `SeedExistingTreasuryExecuteAgentMint.s.sol`
- `SeedExistingTreasuryCreateDeal.s.sol`
- `SeedExistingTreasuryPublishApproveDeal.s.sol`
- `SeedExistingTreasuryApproveDeal.s.sol`

This flow gives indexers and SDKs a realistic wrapped-DAC dataset with:

- hybrid DAC proposal creation,
- oracle snapshot publication,
- wrapped plus Merkle voting on DAC proposals,
- agent minting,
- wrapped-token treasury deal creation,
- DAC approval of that deal.

Example local sequence:

```bash
forge script script/scenarios/SeedExistingTokenDAC.s.sol:SeedExistingTokenDAC --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingTreasuryCreateAgentMint.s.sol:SeedExistingTreasuryCreateAgentMint --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingTreasuryPublishAgentMint.s.sol:SeedExistingTreasuryPublishAgentMint --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingTreasuryExecuteAgentMint.s.sol:SeedExistingTreasuryExecuteAgentMint --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingTreasuryCreateDeal.s.sol:SeedExistingTreasuryCreateDeal --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingTreasuryPublishApproveDeal.s.sol:SeedExistingTreasuryPublishApproveDeal --rpc-url <rpc> --broadcast
forge script script/scenarios/SeedExistingTreasuryApproveDeal.s.sol:SeedExistingTreasuryApproveDeal --rpc-url <rpc> --broadcast
```

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

## 11. Local Timestamp Caveat

Proposal voting in this repository uses timestamp-based snapshots through ERC-6372 / ERC-5805-compatible vote checkpoints.

On fast local Anvil runs, creating a proposal and voting it immediately can land in the same timestamp and trigger future-lookup snapshot failures.

When running staged scripts locally, advance time between proposal creation and the next voting phase:

```bash
cast rpc --rpc-url http://127.0.0.1:8545 evm_increaseTime 1
cast rpc --rpc-url http://127.0.0.1:8545 evm_mine
```

This is generally not needed on real testnets, where proposal creation and later voting naturally occur in different blocks and timestamps.

## 12. Recommended Contributor Workflow

1. `forge build`
2. `forge test`
3. `forge coverage --report summary`
4. `forge build --sizes`
5. Validate deployment and scenario scripts on constrained local Anvil
6. Use the generated manifests as fixtures for indexer, SDK, and frontend work
