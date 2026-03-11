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
│   │   ├── MainToken.sol                          = transferable DAC governance/equity token
│   │   ├── AgentToken.sol                         = DAC-level operating-rights token staked into deals
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
