# DAC Cloud Protocol -- Module Development Guide

*Date: April 7, 2026*

This guide is intended for third-party developers building modules on the DAC Cloud Protocol. It covers the interfaces you must implement, the abstract base contracts you can extend, and the security properties the kernel enforces on your behalf (and expects you to uphold).

---

## 1. Overview

A **module** is an execution extension point for the DAC protocol. Modules define new deal types (how capital is deployed and managed) and evaluator types (how deal outcomes are measured). Every DAC runs deals through modules, and the protocol kernel delegates deal-specific logic to whatever module the DAC governance has approved.

A **module factory** is the on-chain entry point for a module. It provides:

- **Deal factories** -- contracts that deploy new deal instances of the module's deal kinds.
- **Evaluator factories** -- contracts that deploy evaluators compatible with the module's deals.
- **Metadata** -- module ID, version, and manifest URI for off-chain tooling and indexers.

### Trust model

Modules are approved at the DAC level through governance proposals. Each DAC independently controls which modules it trusts. A module being deployed on-chain does not grant it any authority -- a DAC must explicitly approve it before any of its deal kinds can be used. This means module developers ship code, but communities decide whether to adopt it.

---

## 2. Module Factory Interface

Every module factory must implement `IModuleFactory`:

```solidity
interface IModuleFactory {
    // Identity
    function moduleId() external view returns (bytes32);
    function moduleVersion() external view returns (uint32 major, uint32 minor, uint32 patch);
    function moduleManifestURI() external view returns (string memory);

    // Capabilities
    function supportedDealKinds() external view returns (bytes4[] memory);
    function supportedEvaluatorKinds() external view returns (bytes4[] memory);
    function supportsDealKind(bytes4 dealKind) external view returns (bool);
    function dealAcceptsEvaluator(bytes4 dealKind, bytes4 evaluatorKind, address evaluatorModule) external view returns (bool);
    function evaluatorAcceptsDeal(bytes4 evaluatorKind, bytes4 dealKind, address dealModule) external view returns (bool);
    function supportsDealRewardPool(bytes4 dealKind) external view returns (bool);

    // Status
    function isActive() external view returns (bool);
    function safetyCheck(address deal) external view returns (bool);

    // Deployment
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address manager,
        address dealCell,
        VotingConfig calldata votingConfig
    ) external returns (address dealAddr);

    function deployEvaluator(
        address dac,
        uint256 id,
        address dealCell,
        DealParams calldata params,
        bytes4 evaluatorSelector,
        bytes calldata evaluatorConfig
    ) external returns (address evaluatorAddr);
}
```

Key points:

- **`moduleId`** -- a `bytes32` identifier, e.g. `bytes32("dac.core")`. Choose a namespaced identifier that won't collide.
- **`moduleVersion`** -- semver triple. Increment when upgrading factory logic.
- **`moduleManifestURI`** -- optional URI pointing to off-chain metadata (description, docs, audit reports).
- **`supportedDealKinds` / `supportedEvaluatorKinds`** -- enumerate all `bytes4` selectors this module handles.
- **`dealAcceptsEvaluator(dealKind, evaluatorKind, evaluatorModule)`** -- called on the deal's module: "can my deal work with this evaluator kind from this module?" See section 6.
- **`evaluatorAcceptsDeal(evaluatorKind, dealKind, dealModule)`** -- called on the evaluator's module: "can my evaluator work with this deal kind from this module?" See section 6.
- **`supportsDealRewardPool(dealKind)`** -- whether deals of this kind can allocate a portion of rewards to the deal contract itself (see section 7).
- **`isActive`** -- the kernel checks this before deploying. Return `false` to pause new deployments.
- **`safetyCheck(deal)`** -- a hook for runtime invariant checks. The kernel may call this during deal lifecycle transitions.
- **`deployDeal`** -- receives a pre-deployed `dealCell` address from the kernel and creates the Deal contract. Returns the deal address. The kernel (DACCellGovernanceLib) deploys the DealCell, passes it to `deployDeal`, then initializes the DealCell afterward. Module code never controls DealCell deployment or initialization. The evaluator is deployed separately by the kernel via `deployEvaluator`.
- **`deployEvaluator`** -- called by the kernel, not by `deployDeal`. Deploys an evaluator instance for a specific deal.

---

## 3. Extending ModuleFactory

The protocol provides an abstract `ModuleFactory` base contract that handles deal deployment wiring. Module authors extend it and override two internal methods:

```solidity
abstract contract ModuleFactory is IModuleFactory {
    function getDealFactory(bytes4 dealKind) internal virtual returns (IDealFactory);
    function getEvaluatorFactory(bytes4 dealKind, bytes4 evaluatorSelector) internal virtual returns (IEvaluatorFactory);
}
```

The base `deployDeal` implementation:

1. Receives the pre-deployed `dealCell` address from the kernel (the kernel's DACCellGovernanceLib deploys and initializes the DealCell -- modules never control this).
2. Calls your `getDealFactory(dealKind)` to get the appropriate `IDealFactory`.
3. Calls `factory.deployDeal(...)` to create the deal instance and returns the deal address.

The base `deployEvaluator` implementation calls your `getEvaluatorFactory(dealKind, evaluatorSelector)` and delegates to it.

### Example: routing deal kinds to factories

From the core module:

```solidity
function getDealFactory(bytes4 dealKind) internal view override returns (IDealFactory factory) {
    if (dealKind == CoreDealType.DAC_DEAL) {
        factory = IDealFactory(dacDealFactory);
    }
    else if (dealKind == CoreDealType.PERMIT2_TREASURY) {
        factory = IDealFactory(treasuryDealFactory);
    }
    else {
        revert DealKindNotSupported(dealKind);
    }
}
```

### Defining deal kind selectors

Deal kinds and evaluator kinds are `bytes4` selectors derived from interface function signatures. This gives each kind a stable, collision-resistant identifier:

```solidity
interface IMyModuleDeals {
    function createBountyDeal() external pure returns (bytes4);
}

library MyDealType {
    bytes4 public constant BOUNTY_DEAL = IMyModuleDeals.createBountyDeal.selector;
}
```

---

## 4. Building a Deal

### Extend the abstract Deal contract

Your deal contract must extend `Deal` and implement an initializer:

```solidity
contract BountyDeal is Deal {
    function initialize(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _agentToken,
        address _mainToken,
        address _proposer,
        address _factory
    ) external initializer {
        __Deal_init(_id, _dac, _governanceFactory, _agentToken, _mainToken, _proposer, _factory);
    }
}
```

The `Deal` base provides storage for `id`, `dacCell`, `dealCell`, `agentTokenAddr`, `mainTokenAddr`, and governance state. It uses OpenZeppelin's `Initializable` (deals are deployed behind proxies) and `ReentrancyGuard`.

### Lifecycle hooks

The kernel's DealCell calls these hooks at various points. Override the internal `_` prefixed versions:

| Hook | Called when |
|------|------------|
| `_beforeInitialize(params, votingConfig)` | Deal is being initialized with its parameters |
| `_afterInitialize(params, votingConfig)` | Initialization is complete |
| `_onVoluntaryStake(staker, amount)` | An agent voluntarily stakes into the deal |
| `_beforeEveryStake(staker, amount)` | Before any stake (voluntary or added by proposal) |
| `_afterEveryStake(staker, amount)` | After any stake completes |
| `_beforeApprove(trancheId)` | Before a funding tranche is approved |
| `_afterApprove(trancheId)` | After a funding tranche is approved |
| `_afterInvite(invitee, grantInviteRight)` | After an agent is invited to the deal |
| `_afterUnstake(staker, amount)` | After an agent unstakes |
| `_beforeWithdrawCapital()` | Before capital withdrawal to the DAC |
| `_afterWithdrawCapital()` | After capital withdrawal completes |
| `_beforeMarkAsSuccess(rewardPercent)` | Before the deal is marked successful |
| `_onDealRewardAllocated(amount)` | When the deal's reward pool portion is allocated |
| `_afterMarkAsFailed(slashPercent)` | After the deal is marked as failed |
| `_beforeExtendDeadline(oldDeadline, newDeadline)` | Before a deadline extension |
| `_beforeClose()` | Before the deal is closed |
| `_beforeRecovery(liquidator, liquidatorStake)` | Before recovery/liquidation |
| `_afterRecovery(liquidator, liquidatorStake)` | After recovery completes |
| `_beforeClaimMainToken(grantee, amount)` | Before main token claim |
| `_afterClaimMainToken(grantee, amount)` | After main token claim |
| `_onMessageDeal(message, data)` | When the deal receives an arbitrary message |
| `_onLegalWrapperMessage(legalWrapper, messageKind, message)` | When a legal wrapper sends a message |

### Deal-level proposal system

Staked agents can create and execute governance proposals on the deal. The base `Deal` contract provides:

```solidity
function createStakedAgentProposal(ProposalParams calldata params) external returns (uint256 proposalId);
function executeStakedAgentProposal(uint256 proposalId) external;
```

The kernel handles a set of built-in proposal types (defined in `AbstractDealManagementType`):

- `UPDATE_VOTING_CONFIG` -- change the deal's voting parameters
- `REQUEST_TRANCHE` -- request a funding tranche
- `ADD_STAKE` / `PERMIT_UNSTAKE` / `STRIKE_OUT_AGENT` -- agent management
- `TOGGLE_WHITELIST` / `TOGGLE_EARLY_RETURNS` / `ENABLE_VETO_RIGHT` -- deal configuration
- `PERMIT_EVALUATOR_ADD` -- allow adding an evaluator

### Module-specific proposals

To add custom proposal types, override two methods:

```solidity
// 1. Declare which proposal types your deal supports
function _checkStackedAgentProposalSupported(
    ProposalParams calldata params
) internal virtual override returns (bool supported) {
    supported = (
        params.typ == MyDealManagementType.SUBMIT_BOUNTY ||
        params.typ == MyDealManagementType.APPROVE_SUBMISSION
    );
}

// 2. Handle execution of your custom proposals
function _executeModuleManagementProposal(
    DealManagementProposal proposal
) internal virtual override {
    bytes4 typ = proposal.typ();

    if (typ == MyDealManagementType.SUBMIT_BOUNTY) {
        // decode proposal.data() and execute
    }
    else if (typ == MyDealManagementType.APPROVE_SUBMISSION) {
        // ...
    }
    else {
        revert DACErrorsLib.UnsupportedProposal();
    }
}
```

You can also hook into proposal creation and execution with `_beforeCreateProposal` and `_afterCreateProposal`.

### The DealManagementProposalFactory: quorum configuration

Module-specific proposal types need quorum rules. You provide these by extending `DealManagementProposalFactory` and overriding `moduleManagementProposalQuorum`:

```solidity
contract MyManagementProposalFactory is DealManagementProposalFactory {
    function moduleManagementProposalQuorum(
        uint256,
        ProposalParams memory params,
        address,
        address,
        address,
        VotingConfig memory
    ) internal override pure returns (QuorumConfig memory quorum) {
        quorum.allowed = (
            params.typ == MyDealManagementType.SUBMIT_BOUNTY ||
            params.typ == MyDealManagementType.APPROVE_SUBMISSION
        );

        // High-stakes actions require high quorum
        quorum.high = (params.typ == MyDealManagementType.APPROVE_SUBMISSION);

        // Allow veto on high-quorum proposals
        quorum.veto = quorum.high;

        // Enable blocking minority on specific types
        quorum.blocking = false;
    }
}
```

The `QuorumConfig` struct fields:

| Field | Effect |
|-------|--------|
| `allowed` | Must be `true` or the proposal reverts. Set `false` for unsupported types. |
| `high` | Uses `highQuorumPercent` from VotingConfig instead of `quorumPercent`. |
| `blocking` | Enables blocking minority threshold (`blockingPercent`). |
| `veto` | When combined with `vetoEnabled` on the deal, allows challenge/veto flow. |

---

## 5. Building an Evaluator

Evaluators measure deal outcomes and emit on-chain judgments that the kernel translates into reward/slash/extend/close actions.

### Implement IEvaluator

```solidity
interface IEvaluator {
    function permitMint(
        address deal,
        address to,
        uint256 amount
    ) external returns (bool permit);

    function evaluateDeal(
        uint256 dealId,
        address dealCell,
        address dealAddr,
        address managerAddr
    ) external returns (EvaluationResult[] memory);
}
```

### evaluateDeal

Called by the kernel during evaluation cycles. Returns an array of `EvaluationResult`:

```solidity
struct EvaluationResult {
    uint8 action;       // 0=slash, 1=convert, 2=extend, 3=close
    uint256 percent;    // percentage to slash or convert (scaled)
    uint256 extendTo;   // new deadline timestamp (only for action=2)
}
```

Actions:

| Action | Value | Meaning |
|--------|-------|---------|
| Slash | 0 | Slash `percent` of agent stakes |
| Convert | 1 | Convert `percent` of staked capital into rewards |
| Extend | 2 | Extend the deal deadline to `extendTo` |
| Close | 3 | Close the deal |

You can return multiple results in a single evaluation. For example, convert 50% then extend:

```solidity
function evaluateDeal(...) external returns (EvaluationResult[] memory results) {
    results = new EvaluationResult[](2);
    results[0] = EvaluationResult({action: 1, percent: 5000, extendTo: 0});  // convert 50%
    results[1] = EvaluationResult({action: 2, percent: 0, extendTo: block.timestamp + 90 days});
    return results;
}
```

### permitMint

A secondary authorization gate for reward claims. The kernel calls this before minting reward tokens to a claimant. For basic evaluators that don't need claim-level control, simply return `true`:

```solidity
function permitMint(address, address, uint256) external pure returns (bool) {
    return true;
}
```

For evaluators that need to enforce claim conditions (e.g., vesting schedules or KYC checks), implement custom logic here.

### Evaluator initialization

Evaluators are initialized by the evaluator factory with deal-specific context. The factory receives `(dac, id, dealCell, params, evaluatorConfig)` from the kernel. The `evaluatorConfig` bytes are opaque to the kernel -- your module controls the encoding:

```solidity
contract MyEvaluatorFactory is IEvaluatorFactory {
    function deployEvaluator(
        address dac,
        uint256 id,
        address dealCell,
        DealParams calldata deal,
        bytes calldata evaluatorConfig
    ) external returns (address) {
        // Decode your module-specific config
        (uint256 targetRevenue, uint256 checkInterval) = abi.decode(
            evaluatorConfig, (uint256, uint256)
        );

        MyEvaluator evaluator = new MyEvaluator();
        evaluator.initialize(dac, id, dealCell, targetRevenue, checkInterval);
        return address(evaluator);
    }
}
```

### Reward caps

Rewards are capped by the DAC-approved `rewardsLimit` in `DealParams`, regardless of what the evaluator returns. Even if `evaluateDeal` converts 100% of stakes, the actual reward payout will not exceed `rewardsLimit`. This is enforced by the kernel and cannot be bypassed by module code.

---

## 6. Cross-module Evaluator Compatibility

Evaluators can be deployed from a **different** module than the deal. This allows specialized evaluation modules to work with deals from other modules. The `DealParams.evaluatorModuleFactory` field specifies which module deploys the evaluator -- if set to `address(0)`, the deal's own module is used.

When an evaluator is being deployed (or later added via `ADD_EVALUATOR`), the kernel calls two separate methods:

1. **`dealAcceptsEvaluator(dealKind, evaluatorKind, evaluatorModule)`** on the deal's module -- "can my deal work with this evaluator from this module?"
2. **`evaluatorAcceptsDeal(evaluatorKind, dealKind, dealModule)`** on the evaluator's module -- "can my evaluator work with this deal from this module?"

Both must return `true`. The counter-party module address is included in each call, allowing fine-grained trust decisions (e.g., only accepting evaluators from audited modules).

The core module takes a permissive approach -- it returns `true` for all inputs (no constraints):

```solidity
// Core module: permissive -- accepts any counter-party module
function dealAcceptsEvaluator(bytes4, bytes4, address) external pure returns (bool) {
    return true;
}

function evaluatorAcceptsDeal(bytes4, bytes4, address) external pure returns (bool) {
    return true;
}
```

Third-party modules should be more restrictive. Return `true` only for evaluator/deal combinations you have tested and validated, and optionally restrict which counter-party modules you trust:

```solidity
function dealAcceptsEvaluator(bytes4 dealKind, bytes4 evaluatorKind, address evaluatorModule) external view returns (bool) {
    if (dealKind == MyDealType.BOUNTY_DEAL) {
        return evaluatorKind == MyEvaluatorType.BOUNTY_EVALUATOR
            || evaluatorKind == CoreEvaluatorType.MILESTONES_EVALUATOR; // tested with core milestones
    }
    return false;
}

function evaluatorAcceptsDeal(bytes4 evaluatorKind, bytes4 dealKind, address dealModule) external view returns (bool) {
    if (evaluatorKind == MyEvaluatorType.BOUNTY_EVALUATOR) {
        return dealKind == MyDealType.BOUNTY_DEAL;
    }
    return false;
}
```

---

## 7. Deal Reward Pool

If `supportsDealRewardPool(dealKind)` returns `true`, deals of that kind can set a non-zero `dealRewardPoolPercent` in `DealParams`.

When rewards are unlocked (via a convert evaluation result), the reward amount is split:

- **(100% - dealRewardPoolPercent)** goes to staked agents pro-rata based on their stake weight.
- **dealRewardPoolPercent** goes to `address(deal)` -- the deal contract itself.

The deal contract can then claim its accumulated reward pool via `IDealCell.claimMainToken` and apply whatever distribution logic it needs. For example, the core `DACDeal` forwards claimed tokens to its child DAC:

```solidity
function claimDealRewardPool(uint256 evaluatorId) external onlyStakedAgent nonReentrant {
    IDealCell(dealCell).claimMainToken(evaluatorId);
}

function _afterClaimMainToken(address grantee, uint256 amount) internal override {
    if (grantee != address(this) || amount == 0) return;
    IERC20(mainTokenAddr).safeTransfer(managedEntity, amount);
    IDACCell(managedEntity).recoverERC20(mainTokenAddr);
}
```

---

## 8. Related Contract Discovery

Deals often deploy or interact with auxiliary contracts (child DACs, vaults, oracles, etc.). Use `_registerRelatedContract` to emit `DealRelatedContract` events so indexers and frontends can discover these addresses without module-specific storage reads:

```solidity
_registerRelatedContract(
    relatedContract,  // address of the related contract
    role,             // bytes32 role identifier, e.g. bytes32("CHILD_DAC")
    controlled,       // true if the asset controller should track this address
    managed           // true if this is a managed entity
);
```

- **`controlled = true`** -- the related contract is registered with the DealCell's asset controller. Use this for contracts that hold or manage capital on behalf of the deal.
- **`managed = true`** -- signals to indexers that this is a managed entity (e.g., a child DAC whose governance the deal participates in).
- If `relatedContract` is `address(0)`, the call is a no-op.

Example from `DACDeal._beforeInitialize`:

```solidity
_registerRelatedContract(managedEntity, bytes32("CHILD_DAC"), false, true);
_registerRelatedContract(dacCellDNA.dacMainToken, bytes32("CHILD_MAIN_TOKEN"), false, false);
_registerRelatedContract(dacCellDNA.dacAgentToken, bytes32("CHILD_AGENT_TOKEN"), false, false);
```

---

## 9. Security Considerations

### Do not revert unconditionally in hooks

Deal hooks like `_beforeClose`, `_beforeWithdrawCapital`, and `_beforeRecovery` are called during critical lifecycle transitions. If your hook reverts unconditionally, it can **brick the deal** -- capital becomes permanently locked because the kernel cannot complete the transition. Always ensure hooks have a valid execution path that does not revert, or use them only for validation that should legitimately block the operation.

### DealCell and evaluator deployment are kernel-controlled

Your `deployDeal` only creates the Deal contract. It receives a pre-deployed `dealCell` address from the kernel and must **not** deploy or initialize a DealCell. The kernel (DACCellGovernanceLib) handles DealCell deployment before calling `deployDeal` and DealCell initialization afterward. Similarly, the kernel calls `deployEvaluator` separately, and the evaluator module may be different from the deal module. Do not assume your deal will always be paired with your evaluator.

### `deployDeal` and `deployEvaluator` are publicly callable

`ModuleFactory.deployDeal` and `ModuleFactory.deployEvaluator` have no access control -- anyone can call them directly, not just a DAC's DealManager. A directly-deployed Deal is **economically inert** within the protocol: it will not be registered in any DealManager's deal registry, cannot receive DAC treasury funding, cannot route evaluator results, and cannot mint rewards.

However, the deployed contract is real and may appear on block explorers, indexers, or third-party dashboards. Do **not** assume that a contract deployed by your module was deployed through a legitimate DAC. If your module or related services need to verify provenance, the correct on-chain trust anchor is the DealManager's deal registry -- check `DealManager.state(dealCell).id != 0` to confirm a DealCell was created through proper DAC governance.

### Kernel-enforced reward caps

The kernel enforces `rewardsLimit` from `DealParams` regardless of evaluator output. Even if both the deal and evaluator contracts are compromised, rewards cannot exceed the DAC-approved limit. This is a defense-in-depth measure -- but it does not excuse sloppy evaluator logic.

### Agent capital is at risk

Agent stakes are real capital at risk in every deal. If your evaluator incorrectly slashes, or your deal hook causes unexpected behavior, agents lose money. Treat module code with the same rigor as any contract that holds user funds.

### Module approval is high-trust

Module approval is a governance action with significant implications. Communities should:

- Audit the module's deal and evaluator contracts before approval.
- Verify that `safetyCheck` performs meaningful validation.
- Review the quorum configuration in the module's `DealManagementProposalFactory`.
- Test cross-module evaluator compatibility claims.
- Confirm that `isActive()` can be toggled to pause deployments in an emergency.

---

## 10. Reference: Core Module

The built-in core module serves as the canonical reference implementation. Study these contracts for working patterns:

| Contract | Path | Purpose |
|----------|------|---------|
| `CoreModuleFactory` | `src/modules/core/CoreModuleFactory.sol` | Module factory with two deal kinds and two evaluator kinds |
| `CoreModuleDeals` | `src/modules/core/CoreModuleDeals.sol` | Deal and evaluator kind selector definitions |
| `DACDeal` | `src/modules/core/deals/DACDeal.sol` | Deal that deploys/manages a child DAC |
| `TreasuryDeal` | `src/modules/core/deals/TreasuryDeal.sol` | Deal for treasury management via Permit2 |
| `CoreDealManagementProposals` | `src/modules/core/governance/CoreDealManagementProposals.sol` | Module-specific proposal type selectors |
| `CoreManagementProposalFactory` | `src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol` | Quorum configuration for core proposal types |
| `MilestoneBasedEvaluator` | `src/modules/core/evaluators/MilestoneBasedEvaluator.sol` | Evaluator that checks milestone completion |
| `RevenueBasedEvaluator` | `src/modules/core/evaluators/RevenueBasedEvaluator.sol` | Evaluator that measures revenue targets |

Start with `CoreModuleFactory` to understand the wiring, then look at `DACDeal` for a full deal implementation with custom proposals, lifecycle hooks, and related contract registration.
