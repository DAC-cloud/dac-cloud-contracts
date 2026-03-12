# DAC Cloud Contracts

DAC Cloud is a modular smart-contract framework for running **Decentralized Autonomous Corporations**: self-organizing entities where capital (token holders) and managers/agents, and economically aligned through explicit funding, governance, evaluation, and reward rules.

This repository contains the protocol kernel, the shipped core module, Solidity tests, and deployment / scenario scripts.

## Documentation

- [Whitepaper](docs/whitepaper.md)
  Concept, philosophy, and higher-level vision.
- [Architecture](docs/architecture.md)
  System model, lifecycle, governance, token design, and deal flow.
- [Contract Inventory](docs/contracts.md)
  Contract-by-contract map of the current implementation.
- [Development Guide](docs/development.md)
  Build and test commands, deployment scripts, scenario seeding, manifests, and local Anvil validation.

## Repository Map

- `src/interfaces/`
  Shared external interfaces, events, errors, and protocol structs.
- `src/kernel/`
  The protocol kernel: `DACFactory`, `DACCell`, `DealManager`, `DealCell`, `Deal`, governance, libraries, and tokens.
- `src/modules/core/`
  The shipped core module with `DACDeal`, `TreasuryDeal`, `Permit2Treasury`, and the built-in evaluators.
- `src/lib/`
  Supporting interfaces and third-party compatibility shims such as `IVotes`, `IClock`, and `IPermit2`.
- `test/`
  Unit, integration, regression, access-control, and fuzz coverage.
- `script/`
  Deployment, preflight, and manifest-driven scenario scripts for local and testnet validation.
- `deployments/`
  Generated deployment and scenario manifests keyed by chain id.

## Main Entry Points

- `src/kernel/DACFactory.sol`
  Deploys new DACs and wires the kernel.
- `src/kernel/DACCell.sol`
  DAC-level governance, treasury, capital calls, dividends, and legal-wrapper integration.
- `src/kernel/DealManager.sol`
  Deal registry, module routing, evaluator execution, and main-token flow accounting.
- `src/kernel/DealCell.sol`
  Per-deal state, staking, tranches, and reward accounting.
- `src/modules/core/CoreModuleFactory.sol`
  The shipped module factory for the core deal set.

## Status

The codebase includes extensive unit, integration, and fuzz coverage, plus local deployment and seeded scenario scripts for:

- base DAC bootstrap,
- treasury / execution-wallet flows,
- child-DAC governance and capital-call flows.

For operational usage, start with the [Development Guide](docs/development.md).
