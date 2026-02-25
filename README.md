## DAC

Modular blockchain framework for operating **Decentralized Autonomous Corporations** — self-organizing entities where capital (LP holders) and managers/agents (MP holders) are economically aligned through transparent, performance-based incentives.

## Documentation

```
src/
├── interfaces/
│   ├── Structs.sol       = All common structs here; common struct for all proposals - ProposalParams
│   ├── IVoting.sol       = Simple voting with quorum, veto-rule, and expiration
│   ├── IDACEntity.sol
│   └── IDealCore.sol
│       ... + Other interfaces. Mostly unchanged, with params rename and adaptation for new proposals
├── kernel/
│   ├── tokens/
│   │   ├── MPToken.sol   = Non-transferable ERC-20, minted and revoked by DAC LP, stakeable into Deals for rewards
│   │   └── LPToken.sol   = Main DAC token, ERC-20 without transfer restrictions. Votes on proposals.
│   ├── governance/
│   │   ├── factories/
│   │   │   ├── LPManagementProposalFactory.sol    = factory for DAC-LP governance proposals
│   │   │   └── DealManagementProposalFactory.sol  = abstract factory for Deal staked-MP proposals
│   │   ├── Proposal.sol                           = abstract proposal to be used in DAC system; is IVoting
│   │   ├── LPManagementProposal.sol               = is Proposal; for DAC-LP governance
│   │   ├── DealManagementProposal.sol             = is Proposal; for Deal staked-MP governance
│   │   ├── AbstractDealManagementProposals.sol    = library const pattern for kernel-level Deal proposals
│   │   └── LPManagementProposals.sol              = library const pattern for LP proposals at a DAC level
│   ├── DACEntity.sol     = DAC kernel, single "cell" of the DAC tree, governed by LP token holders
│   ├── Deal.sol          = abstract Deal, represents all deals made by DAC, governed by MP-stakers (Deal is ERC-20)
│   └── DACFactory.sol    = Create2 factory for DAC cells
└── modules/
    └── core/
        ├── CoreModuleDeals.sol       = library const pattern with all deal types provided by the module
        ├── deals/
        │   ├── DACDeal.sol           = is Deal; representing LP ownership of another DAC-cell, proxies LP governance
        │   ├── TreasuryDeal.sol      = is Deal; Simple x402-enabled treasury
        │   └── Permit2Treasury.sol   = Simple Permit2 governed vault contract for treasury
        ├── governance/
        │   ├── factories/
        │   │   └── CoreDealManagementProposalFactory.sol   = concrete factory for core module deals governance
        │   └── CoreDealTypes.sol     = library const pattern with all core module proposals
        ├── evaluators/
        │   └── BasicEvaluator.sol
        └── factories/
            ├── DealFactory.sol
            └── EvaluatorFactory.sol

```

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Test.s.sol:TestScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
