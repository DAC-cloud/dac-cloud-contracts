# DAC Cloud Contracts — Security Audit Report

**Audit Date:** May 12, 2026
**Auditor:** Claude Opus 4.7 (1M-context, automated security review)
**Repository:** dac-cloud-contracts
**Commit reviewed:** `be026d9` (branch: `develop`)
**Solidity Version:** ^0.8.20
**Framework:** Foundry
**Source size:** 10,250 LoC across 88 Solidity files (`src/`)
**Test suite at audit time:** 188 / 188 passing
**Build status:** clean (`forge build` succeeds; one unused-import lint note in a test file unrelated to scope)

---

## 1. Executive Summary

This is an independent re-audit of the DAC Cloud protocol following the May 2026 security-hardening round (commit `be026d9`). The prior audit (commit `6847a64`) identified one HIGH-severity vulnerability — an unauthorized `consumeExecution` permitted any address to mark a passed proposal as executed, permanently DoS-ing the legitimate execution path. That fix landed in `be026d9` and added a structural `executor` gate to every proposal type.

This audit pass was conducted as a **clean review** — no findings from prior audits were carried forward as accepted truth. The previous two audits both identified missing access-control modifiers on DAC kernel components (proposals, schemas, controllers) as the dominant vulnerability class. Per the client's explicit request, this audit applied maximum scrutiny to that pattern across every external/public function in `src/`.

### Findings Summary

| Severity       | Count |
|----------------|-------|
| Critical       | 0     |
| High           | 0     |
| Medium         | 0     |
| Low            | 7     |
| Informational  | 10    |

**No High- or Medium-severity vulnerabilities were identified.** The H-01 executor-gate fix is correctly applied across the three proposal types (`Proposal`, `HybridDACManagementProposal`, `DealManagementProposal`) and threaded through their factories. The M-01 SafeERC20 fix is also confirmed in place on `TreasuryDeal`.

The Low-severity findings cluster into three themes:

1. **Latent over-broad caller gates** — `DealCell.onAgentTokenStaked` permits `msg.sender == dacCell` despite no DACCell path calling it; this is the *exact* H-01 pattern (gate looks proper but the caller set is wider than the design needs).
2. **Governance configuration footguns** — `Permit2Treasury.approveSpendAllowance` accepts `duration == 0` and `singleTxAmount == 0`, allowing per-block drains if governance misconfigures.
3. **Defense-in-depth gaps** — set-once functions (`WrappedMainToken.setController`, `Deal.joinDac`, `MainToken.dacInit`, `AgentToken.dacInit`) lack explicit one-shot guards; they are currently safe via caller-side bookkeeping but are not locally self-protecting.

The codebase otherwise demonstrates disciplined access control. Every controller, schema, kernel, and module entry point traces to an explicit caller check (`onlyDACCell`, `onlyDealManager`, `onlyDealCell`, `onlyDeal`, `onlyAgent`, `onlyStakedAgent`, `onlyLegalWrapper`, `onlyRole`, `onlyAdmin`, `onlyAgentToken`, `onlyWrappedMainToken`, or `initializer`). The dual-mode native/hybrid architecture and ERC-1271 structured-payload defense are correctly implemented.

---

## 2. Scope

### 2.1 Contracts in scope (`src/`)

**Kernel (`src/kernel/`)** — 9 contracts + 4 libraries + adapter interfaces

| Contract | Role |
|---|---|
| `DACCell.sol` | DAC kernel; routes proposals; legal-wrapper, capital-call entry points |
| `DealManager.sol` | Deal lifecycle, evaluator routing, reward minting cap |
| `DealCell.sol` | Per-deal governance wrapper, staking, evaluator coordination |
| `Deal.sol` | Abstract module-deployed deal base, hook surface |
| `DACFactory.sol` | DAC bootstrap (Create2); native + existing-token paths |
| `ModuleRegistry.sol` | Approved-module whitelist |
| `ModuleFactory.sol` | Abstract module deployer |
| `controllers/NativeAssetController.sol` | Mint-backed treasury, capital calls, dividends |
| `controllers/ExistingTokenAssetController.sol` | Reserve-backed treasury; ERC-208 controlled-supply checkpoints |

**Governance (`src/kernel/governance/`)** — 7 contracts + 6 factories

| Contract | Role |
|---|---|
| `Proposal.sol` | Abstract single-channel voting proposal |
| `DACManagementProposal.sol` | DAC-level proposal (native) |
| `DealManagementProposal.sol` | Deal-level proposal with DAC challenge gate |
| `HybridDACManagementProposal.sol` | Multi-phase (oracle + fallback) DAC-level proposal |
| `NativeGovernanceSchema.sol` | Native-mode proposal policy |
| `HybridGovernanceSchema.sol` | Hybrid-mode proposal policy |
| `BasicGovernanceOracle.sol` | Multi-DAC reference governance oracle |

**Tokens (`src/kernel/tokens/`)** — 4 contracts + 2 factory files

| Contract | Role |
|---|---|
| `MainToken.sol` | Native `ERC20Votes` governance token (timestamp clock) |
| `WrappedMainToken.sol` | Wrap of existing token, `ERC20Votes` (block-number clock) |
| `AgentToken.sol` | Bound-balance agent identity token with distributor flow |
| `StakedAgent.sol` | Per-deal non-transferable `ERC20Votes` (timestamp clock) |

**Kernel libraries (`src/kernel/libraries/`)** — 4 libraries

| Library | Role |
|---|---|
| `DACCellGovernanceLib.sol` | DAC-level deal proposals, mint cap, evaluator dispatch |
| `DealCellGovernanceLib.sol` | Deal staking, reward allocation, slashing, withdrawals |
| `MathLib.sol` | Fixed-point percent math (delegates `mulDiv` to OZ) |
| `DACDeployment.sol` | Create2 address prediction for DACCell |

**Core module (`src/modules/core/`)** — 3 deals + 2 evaluators + governance + factories

| Contract | Role |
|---|---|
| `CoreModuleFactory.sol` | Core module router |
| `deals/DACDeal.sol` | Child-DAC deal; on-chain child voting + ERC-1271 external-venue voting |
| `deals/TreasuryDeal.sol` | Permit2-fronted treasury deal for agent spend/receive |
| `deals/Permit2Treasury.sol` | Agent-operated treasury contract with on-chain + signature spend flows |
| `evaluators/MilestoneBasedEvaluator.sol` | Milestone-driven reward/slash evaluator |
| `evaluators/RevenueBasedEvaluator.sol` | Cycle-based revenue evaluator with auto-close |
| `governance/CoreDealManagementProposals.sol` | Module proposal types |

**Proxy + factories** — 1 proxy contract + 13 factory contracts (kernel, governance, modules, tokens)

### 2.2 Out of scope

- Off-chain infrastructure (oracle publishers, frontend, indexers, envio)
- Third-party dependencies (OpenZeppelin contracts, Uniswap Permit2) — assumed correct
- Foundry scripts under `script/` and `broadcast/`
- Test contracts under `test/`

---

## 3. Methodology

This audit applied the following process:

1. **Manual line-by-line review** of every contract in `src/`, plus the libraries used via `DELEGATECALL`.
2. **Per-function caller-gate enumeration.** For every `external`/`public` function across the 88 source files, the expected caller was identified from architectural context, then the enforced gate was verified. A per-function table was constructed for the controllers, kernel, tokens, modules, factories, and libraries (≈420 functions in total).
3. **Trust-boundary mapping.** For every privileged call chain, the audit traced kernel ↔ schema ↔ controller ↔ module hops to confirm each segment enforces its expected caller.
4. **Targeted hunt for the H-01 pattern.** Every `external` function with a `require(msg.sender == X)` check was re-examined for: (a) over-broad caller sets, (b) implicit-only enforcement via EXTCODESIZE, (c) caller-checks that depend on uninitialized state, (d) functions that *look* internal but are `external` without a gate.
5. **Vulnerability class checklist:** reentrancy, integer over/underflow, signature replay, oracle manipulation, flash-loan voting, governance griefing, MEV, initialization races, proxy upgrade exposure, dangerous low-level primitives, unbounded iteration, hash collisions, front-running on revocation/approval.
6. **State machine validation** — proposal lifecycle (`Proposal`, `HybridDACManagementProposal`, `DealManagementProposal`), deal lifecycle (`DealCell`), treasury accounting (controllers), capital-call hash uniqueness.
7. **Cross-contract invariants** — reward `paid ≤ unlocked ≤ limit ≤ supply headroom`, controlled vs released main-token supply, capital-call hash uniqueness, dividend Merkle leaf uniqueness, qualification-vs-quorum thresholds.
8. **Regression check** — ran `forge test` (188 / 188 passing) and `forge build` (clean) to confirm the audit baseline is healthy.

### Vulnerability classes considered

| Category | Result |
|---|---|
| Reentrancy | `nonReentrant` on entry points; callback ladder properly gated |
| Integer over/underflow | Solidity 0.8 checked arithmetic; floor-at-zero subtraction across controllers |
| Access-control bypass | None confirmed in current code; one latent over-broad gate flagged (L-01) |
| Front-running | Snapshot voting; revoke vs spend race noted (I-09) |
| Oracle manipulation | Evaluator oracle calls lack response validation (carryover from prior L-01); not re-flagged here as the prior recommendation stands |
| Flash-loan voting | Snapshot-based, ERC20Votes; immune |
| Proxy upgrade | UUPS-style proxy expose **no** `_authorizeUpgrade` in implementations; effectively non-upgradeable |
| Denial of service | None high-severity; latent finding documented at L-01 |
| Signature malleability | Permit2 signatures delegated to Uniswap-audited contract; ERC-1271 path uses structured-payload reconstruction (verified intact) |
| `tx.origin` / `delegatecall` / `selfdestruct` / `unchecked` | Not used in `src/` |
| Initialization races | All implementations call `_disableInitializers()`; proxies use `initializer` modifier or mutually-exclusive guard flags |
| Hash collisions | EIP-712 domain separator for snapshot.org cannot collide with EIP-2612; Permit2Treasury keys are per-instance |

---

## 4. Architecture Recap (for context)

```
DACFactory (immutable)
 ├─ deployDAC()              → native mode
 └─ deployExistingTokenDAC() → existing-token mode
     │
     ├─ Native:    MainToken (ERC20Votes/timestamp)  + NativeAssetController + NativeGovernanceSchema
     └─ Existing:  WrappedMainToken (ERC20Votes/block#) + ExistingTokenAssetController + HybridGovernanceSchema (+ BasicGovernanceOracle)
     │
     ├─ DACCell                  → routes proposals to schema
     ├─ AgentToken               → operator identity, distributor flow
     ├─ ModuleRegistry           → approved modules
     ├─ DealManager              → deal lifecycle, evaluator dispatch
     │   └─ DealCell[N]
     │       ├─ StakedAgent       → non-transferable deal-local voting
     │       ├─ Deal             → module-deployed logic
     │       │   ├─ DACDeal      → child-DAC + ERC-1271 external votes
     │       │   └─ TreasuryDeal → Permit2Treasury (agent spend/receive)
     │       └─ Evaluator[M]
     └─ GovernanceSchema         → proposal qualification + execution gate
```

### Key trust properties (verified)

- **No admin keys.** `DACFactory` is immutable. Once deployed, each DAC is fully on-chain-governed.
- **Per-DAC oracle namespacing.** `BasicGovernanceOracle` snapshots and active flags are keyed by `(dac, proposalId)`; deactivating one DAC does not affect others sharing the oracle.
- **Reward double-cap.** Per-deal minting is bounded by `rewardsPaid ≤ rewardsUnlocked ≤ rewardsLimit`, with `rewardsLimit` set only via DAC governance.
- **Module isolation.** Modules deploy `Deal`; the kernel deploys `DealCell`. A rogue module cannot manipulate the governance wrapper.
- **Executor binding on every proposal.** `Proposal`, `HybridDACManagementProposal`, and `DealManagementProposal` all store an immutable `executor` set to `msg.sender` at the factory hop; `consumeExecution` requires `msg.sender == executor`. The factories are correctly self-binding (the only caller in legitimate flow is the schema or Deal that owns the proposal's consume-and-act lifecycle).
- **EIP-2612 permit-collision defense intact.** `DACDeal` stores the *structured* snapshot.org payload and reconstructs the EIP-712 hash on every `isValidSignature` read; the domain separators of EIP-2612 (`name, version, chainId, verifyingContract`) and snapshot v1 (`name, version`) cannot collide.

---

## 5. Findings

### LOW SEVERITY

#### L-01: `DealCell.onAgentTokenStaked` over-broad caller gate (matches H-01 pattern)

**Severity:** Low
**Location:** `src/kernel/DealCell.sol:209-222`

```solidity
function onAgentTokenStaked(address staker, uint256 amount) external {
    require(msg.sender == agentTokenAddr || msg.sender == dacCell, DACErrorsLib.NotAuthorized());

    require(!approved, DACErrorsLib.DealAlreadyApproved());
    if (isWhitelistOnly) {
        require(isWhitelisted[staker], DACErrorsLib.NotWhitelistedAgent());
    }

    stake(staker, amount);
    deal.onVoluntaryStake(staker, amount);
}
```

**Description:**

The caller gate permits either `agentTokenAddr` *or* `dacCell`. The legitimate call path is `AgentToken.stakeToDeal` (or `forceStakeToDeal`) — both of which:

1. First transfer agent tokens to the dealCell via `_transfer(staker, dealCell, amount)`.
2. Then notify the dealCell via `IDealCellAdapter(dealCell).onAgentTokenStaked(staker, amount)`.

`onAgentTokenStaked` does **bookkeeping only** — it mints staked-agent tokens, appends the staker to `holders[]`, and notifies the Deal. The actual token movement is the caller's responsibility.

A grep across `src/` confirms that **no DACCell path calls `onAgentTokenStaked`.** The `|| msg.sender == dacCell` branch is dead code today.

**Why this matters:**

This is the exact pattern that produced H-01 in the prior audit — a caller gate that *looks* properly modifier-protected but admits more callers than the design needs. If a future code change ever has DACCell invoke `onAgentTokenStaked` (for any reason — refactor, new feature, accidental routing), the bookkeeping would record a stake **without an actual agent-token transfer** to the dealCell. The resulting invariant violations:

- `dealCell.balanceOf(agentToken) < stakedAgent.totalSupply()` — the dealCell holds fewer real agent tokens than it has issued staked-agent claims against.
- Subsequent `unstake` calls would attempt `agentToken.transfer(agent, agentStake)` and fail (insufficient balance), bricking unstake for legitimate stakers.

**Impact today:** None. The function is unreachable via the dacCell branch in current code.
**Impact under any future code change:** High — invariant breakage + potential brick.

**Recommendation:**

Drop the `|| msg.sender == dacCell` branch. The gate should be simply:

```solidity
require(msg.sender == agentTokenAddr, DACErrorsLib.NotAuthorized());
```

This is exactly the kind of latent surface the user's audit guidance was directing attention toward: the H-01 fix closed one missing-modifier hole; this is the same class one layer deeper. Cheap to fix, durable improvement.

---

#### L-02: `Permit2Treasury.approveSpendAllowance` does not validate `duration > 0` / `singleTxAmount > 0`

**Severity:** Low
**Location:** `src/modules/core/deals/Permit2Treasury.sol:107-125, 208-227`

**Description:**

`approveSpendAllowance` stores a `TreasurySpendAllowance` struct verbatim from governance proposal data with no validation:

```solidity
function approveSpendAllowance(
    address agent,
    address token,
    address destination,
    TreasurySpendAllowance memory allowance
) external onlyDeal {
    bytes32 calldataHash = keccak256(abi.encode(agent, token, destination));
    agentAllowance[calldataHash] = allowance;
    ...
}
```

The runtime enforcement in `executeAgentSpend` is:

```solidity
require(agentAllowance[calldataHash].totalAmount >= amount, SpendNotApproved());
require(agentAllowance[calldataHash].singleTxAmount >= amount, InvalidDealSize());
require(agentAllowance[calldataHash].clockLimit < clock(), InvalidDealTimeBounds());

agentAllowance[calldataHash].totalAmount -= amount;
agentAllowance[calldataHash].clockLimit = clock() + agentAllowance[calldataHash].duration;
```

If governance approves an allowance with `duration == 0`, the `clockLimit < clock()` rate-limit check effectively becomes "next call in the next block." On Ethereum L1 that's a 12s rate; on Base/Optimism, ~2s. Combined with a generous `singleTxAmount` and `totalAmount`, this becomes "no meaningful rate limit, drain at chain speed."

If `singleTxAmount == 0`, every spend reverts at the second require — making the allowance useless rather than dangerous, but still a config error.

**Impact:**

A configuration mistake in a governance proposal (forgetting to set `duration`, or passing zero by accident in encoded data) creates an allowance whose runtime cap is effectively just `totalAmount`. The agent can drain the full `totalAmount` over a small number of blocks instead of the intended slow stream.

The damage is bounded by `totalAmount` — governance still sets the total cap. So this is a footgun, not a vulnerability with unbounded loss. But governance approves with the expectation of a rate-limited spend; the expectation is silently violated.

**Recommendation:**

Add structural validation in `approveSpendAllowance`:

```solidity
require(allowance.duration > 0, InvalidAllowance());
require(allowance.singleTxAmount > 0, InvalidAllowance());
require(allowance.singleTxAmount <= allowance.totalAmount, InvalidAllowance());
```

The `singleTxAmount <= totalAmount` ordering check is also worth adding (a higher `singleTxAmount` than `totalAmount` is incoherent).

---

#### L-03: `Permit2Treasury.executeAgentSpend` wildcard fallthrough is unintuitive

**Severity:** Low
**Location:** `src/modules/core/deals/Permit2Treasury.sol:208-227`

**Description:**

`executeAgentSpend` first looks up the per-destination allowance `(agent, token, destination)`. If `totalAmount == 0` at that key, it silently falls through to the wildcard allowance `(agent, token, address(0))`:

```solidity
bytes32 calldataHash = keccak256(abi.encode(msg.sender, token, destination));

if (agentAllowance[calldataHash].totalAmount == 0) {
    // If specific destination allowance not exists,
    //  switching to wildcard allowance
    calldataHash = keccak256(abi.encode(msg.sender, token, address(0)));
}
```

This means: an explicitly-set per-destination allowance whose `totalAmount` has been drained to 0 (or that was never set) **falls through to the wildcard.** A governance proposer who set up `(agent, token, dest1) → 100 tokens` expecting that to be the cap for `dest1` may not realize the agent, once drained, will continue spending from the wildcard pool.

The wildcard pool's `totalAmount` IS decremented correctly, so the *overall* cap is still enforced. But the *per-destination* cap is not what the proposer might expect.

This is the same logic on `executeReceivePermit2` and `executeReceivePermit2Signature` for `approvedAgents` (lines 165-171, 191-197) — fallthrough to wildcard on `address(0)`.

**Impact:**

Governance UX confusion. The per-destination allowance behaves as a "booster" on top of the wildcard, not as a separate cap. No funds are at risk beyond the wildcard's `totalAmount`.

**Recommendation:**

Either:
1. **Document** the fallthrough semantics explicitly in NatSpec on `approveSpendAllowance` / `executeAgentSpend` so governance proposers know what they're signing up for.
2. **Distinguish "never set" from "drained"** via a `bool exists` flag on the struct, so a drained specific allowance does *not* fall through.

Option 1 is the lower-effort path and is sufficient if the design intent matches the current behavior.

---

#### L-04: `WrappedMainToken.setController` is set-once *by convention*, not by guard

**Severity:** Low
**Location:** `src/kernel/tokens/WrappedMainToken.sol:37-40`

```solidity
function setController(address _controller) external onlyAdmin {
    require(_controller != address(0), DACErrorsLib.NotAllowed());
    controller = _controller;
}
```

`admin` is the DACCell, set during init. In current flows, `DACCell.initializeExistingTokenAfterDeployment` (line 202) calls `setController` exactly once. The DACCell has no other public path that calls `setController` later.

Switching the controller would in principle break asset-controller invariants — controlled-balance tracking, votable supply, `_controlledBalanceCheckpoints`. The safety relies entirely on DACCell never being induced to call `setController` again. Currently true, but a defensive `require(controller == address(0))` guard would make the invariant local and explicit, surviving any future refactor of the DACCell wiring.

**Recommendation:**

Add a first-call lock:

```solidity
function setController(address _controller) external onlyAdmin {
    require(_controller != address(0), DACErrorsLib.NotAllowed());
    require(controller == address(0), DACErrorsLib.AlreadyInitialized());
    controller = _controller;
}
```

---

#### L-05: `DealManager._onlyDealCell` relies on implicit EXTCODESIZE rather than explicit existence

**Severity:** Low
**Location:** `src/kernel/DealManager.sol:384-389`

```solidity
function _onlyDealCell(address dealCell) internal view {
    require(
        IModuleFactory(dealState[dealCell].module).isActive(),
        DACErrorsLib.InvalidDeal(dealCell)
    );
}
```

This modifier intends "msg.sender is a registered dealCell whose module is currently active." But it does not explicitly check that msg.sender is registered. The implicit check is:

- For unregistered msg.sender, `dealState[msg.sender].module == address(0)`.
- Solidity's compiler injects an EXTCODESIZE check before the external `.isActive()` call on a contract-type cast, so calling a method on `address(0)` reverts with "address with no code."

This means the modifier *currently* rejects unregistered callers — but only via that implicit compiler-injected check. If a future Solidity version ever loosens that check (unlikely but possible), or if the function were ever ported to a context where the check is skipped (low-level call, assembly), the modifier would silently accept unregistered callers whose dealState happens to have a stale or unrelated module pointer.

**Impact today:** None — Solidity 0.8.20 enforces the EXTCODESIZE check.
**Impact under future compiler/refactor changes:** Possible bypass.

**Recommendation:**

Make the existence check explicit:

```solidity
function _onlyDealCell(address dealCell) internal view {
    require(dealState[dealCell].deal != address(0), DACErrorsLib.NotAuthorized());
    require(
        IModuleFactory(dealState[dealCell].module).isActive(),
        DACErrorsLib.InvalidDeal(dealCell)
    );
}
```

---

#### L-06: `Deal.joinDac` is not explicitly one-shot guarded

**Severity:** Low
**Location:** `src/kernel/Deal.sol:78-84`

```solidity
function joinDac(address _dealCell) external {
    require(msg.sender == factory, DACErrorsLib.NotAuthorized());
    dealCell = _dealCell;
}
```

`factory` is set in `__Deal_init` and never rotated. The legitimate flow calls `joinDac` exactly once during deal deployment. There is no explicit guard preventing the factory from calling it again later.

Currently safe because `DealCellFactory.deployCell` is the only caller of `joinDac` and it's only invoked once per deal during the kernel's deployment flow. A defensive `require(dealCell == address(0), AlreadyInitialized())` makes the invariant local.

**Recommendation:**

```solidity
function joinDac(address _dealCell) external {
    require(msg.sender == factory, DACErrorsLib.NotAuthorized());
    require(dealCell == address(0), DACErrorsLib.AlreadyInitialized());
    dealCell = _dealCell;
}
```

---

#### L-07: `Permit2Treasury` allowance/approval entries are overwrite-on-write rather than incremental

**Severity:** Low
**Location:** `src/modules/core/deals/Permit2Treasury.sol:113-114, 142-149`

```solidity
function approveSpendAllowance(...) external onlyDeal {
    bytes32 calldataHash = keccak256(abi.encode(agent, token, destination));
    agentAllowance[calldataHash] = allowance;   // overwrite, not increment
    ...
}

function approveReceive(...) external onlyDeal {
    bytes32 calldataHash = keccak256(abi.encode(agent, token, source));
    approvedAgents[calldataHash] = amount;       // overwrite, not increment
    ...
}
```

Each new governance proposal targeting the same `(agent, token, destination)` tuple silently **replaces** the prior entry. Remaining unspent balance from the prior allowance is discarded. A proposer who expects "approve another 100 in addition to the existing 50" gets "set to 100, lose the remaining unspent portion of 50."

**Impact:**

Surprise governance behavior. Funds are not lost (the treasury still holds them), but the agent's spendable pool is reset rather than extended.

**Recommendation:**

Either:
1. **Document** the overwrite semantics in NatSpec on the proposal types `APPROVE_AGENT_SPEND` and `ASSIGN_CLAIMER`.
2. Change to additive: `agentAllowance[calldataHash].totalAmount += allowance.totalAmount;` (while still overwriting `singleTxAmount` / `clockLimit` / `duration` since those are caps, not pools).

Option 1 is the simpler path if overwrite is the intended semantic. Note that overwrite is also necessary for *decreasing* an allowance — additive-only would force `REVOKE_AGENT → APPROVE_AGENT_SPEND` for any reduction. So full additive is undesirable; the right move may be a per-field policy or a separate "extend allowance" proposal type.

---

### INFORMATIONAL

#### I-01: `DACCellGovernanceLib.approveFunding` is orphan library code

**Location:** `src/kernel/libraries/DACCellGovernanceLib.sol:229-262`

This `public` library function is not called from anywhere in `src/`. Confirmed via grep: no kernel contract or library imports it. Its responsibilities (validating stake, transferring funding, decrementing treasury) have been superseded by `executeTrancheApprove` on the same library and `approveFunding` on the asset controllers.

Leaving orphan library code in the tree is an attractive nuisance — a future contributor (human or AI) might wire it into a new callsite, missing that its caller-side gate assumptions no longer match the kernel's invariants. **Recommend deletion** for the same reason `DACCellCapitalLib.sol` was deleted in the prior round.

#### I-02: `UUPSProxy` name is misleading — no UUPS upgrade path is exposed

**Location:** `src/kernel/proxies/UUPSProxy.sol`

Despite the name, the proxy is a thin wrapper around OpenZeppelin's `ERC1967Proxy`. None of the implementation contracts (`DACCell`, `DealManager`, schemas, proposals, etc.) inherit `UUPSUpgradeable` or implement `_authorizeUpgrade`. Verified via grep: zero matches for `_authorizeUpgrade` or `UUPSUpgradeable` across the codebase. Deployed proxies are effectively **non-upgradeable**, matching the documented architectural intent ("DACCell has no upgrade or pause capabilities by design").

The naming is harmless today but could mislead a future maintainer. Consider renaming to `NonUpgradeableProxy` or `ERC1967ProxyWrapper`, or adding a NatSpec comment clarifying that this is not a UUPS proxy.

#### I-03: `MainToken.dacInit` / `AgentToken.dacInit` lack explicit one-shot guards

**Locations:**
- `src/kernel/tokens/MainToken.sol:41-50`
- `src/kernel/tokens/AgentToken.sol:43-54`

```solidity
function dacInit(address _dealManager, address _assetController) external {
    require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());
    dealManager = _dealManager;
    _grantRole(MINTER_ROLE, _dealManager);
    _grantRole(MINTER_ROLE, _assetController);
}
```

Re-entry would re-grant `MINTER_ROLE` to the same addresses (idempotent, harmless), but could also pass new addresses — re-grant `MINTER_ROLE` to *new* attacker-controlled `_dealManager` / `_assetController` if the DACCell could be induced to call again.

Currently safe via DACCell's `cellStarted` flag — `initializeAfterDeployment` is one-shot and is the only path that calls `dacInit`. So `dacInit` inherits one-shot semantics from the caller. Adding a local guard (`require(dealManager == address(0))`) would make the invariant self-protecting.

#### I-04: `Deal.createStakedAgentProposal` is permissionless

**Location:** `src/kernel/Deal.sol:203-229`

The external function has no gate. Internal validation happens inside `DealCellGovernanceLib.checkStakedAgentProposal`, which (for the `else` branch — i.e., proposer is neither the DealCell nor the DealManager nor the Deal itself) requires:

```solidity
require(IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > 0, NotStakedAgent());
require(IVotes(stakeToken).getVotes(msg.sender) > totalSupply * qualification, NotEnoughBalance());
```

So only stakers above the qualification threshold can propose. The legitimate gate is enforced, just inside the library rather than via a modifier.

No security issue — but worth noting because the function signature looks unprotected at a glance. Code-readability nit.

#### I-05: Native-mode `non-controlled → controlled` MainToken transfers don't decrement `totalReleasedVotable`

**Location:** `src/kernel/controllers/NativeAssetController.sol:285-306`

The `onMainMove` callback handles three transitions:
- `from == 0` (mint) → if `to` is controlled, increment `lockedMainTokens[to]` and `unreleasedMainTokens`
- `from` controlled → either decrement (to non-controlled) or rebalance (controlled → controlled)
- `from` non-controlled, `to` non-controlled → no-op (correct)

But the case **`from` non-controlled, `to` controlled** is not handled. If a holder transfers MainTokens to (e.g.) the dealManager (controlled), the controller's bookkeeping does not register the tokens as "controlled balance" — they continue to count as `totalReleasedVotable` even though dealManager (controlled) cannot vote per `onMainDelegate`.

**Impact:** The `totalReleasedVotable` over-counts the affected tokens, making the qualification threshold *higher* (safety-erring). No honest flow does this in production (the dealManager doesn't accept user main-token deposits via `transfer`), but a stray donation would inflate the threshold.

The hybrid `ExistingTokenAssetController.onMainMove` (lines 298-313) handles this case correctly because it processes both directions independently. Native mode could mirror the same shape.

This was documented in the prior audit as I-08; it remains unchanged.

#### I-06: `Permit2Treasury` `approvedAgents` / `agentAllowance` keys are per-instance but not bound to proposal-id

**Location:** `src/modules/core/deals/Permit2Treasury.sol:30-31`

Each Permit2Treasury proxy has its own storage, so cross-deal collision is structurally impossible. But within one treasury, two separate governance proposals approving the same `(agent, token, destination)` tuple have no proposal-id binding — the second silently overwrites the first (per L-07).

Adding a proposal-id field to the storage key would let multiple in-flight allowances coexist. Not necessary if overwrite is intentional, but worth considering.

#### I-07: `DACFactory.deployDAC` salt+name uniqueness allows squatter front-runs on chosen-name salts

**Location:** `src/kernel/libraries/DACDeployment.sol`

`predictDACAddress` mixes `salt`, deployer (DACFactory address, fixed), `referenceImpl`, `cellFactory`, `name`, `description`, `governanceFactory` into the Create2 bytecode hash. Two different EOAs each calling `deployDAC` with the *same* `salt` + `name` + `description` + `governanceFactory` produce the same predicted address — the second `deployDAC` reverts at `Create2Failed` because a contract already exists at that address.

**Impact:** A griefer can front-run a known DAC deployment by depositing at the predicted address with the chosen salt. The victim can recover by picking a different salt. Severity: nuisance.

This is the standard Create2 squat issue and is acceptable design — the protocol expects deployers to use unique salts. Note it for ergonomics only.

#### I-08: `Proposal.sol` and `HybridDACManagementProposal.sol` duplicate ~90% of resolution logic

**Locations:** `src/kernel/governance/Proposal.sol`, `src/kernel/governance/HybridDACManagementProposal.sol`

`_outcome`, `_checkAndEmitResolution`, `_isExecutableNow`, and `executionDeadline` are near-identical between the two contracts (with the hybrid version adding multi-phase state). A future bug-fix on one is easy to forget to mirror on the other.

Code-hygiene only. Consider extracting into a shared `ProposalBase` internal contract, or an internal library.

#### I-09: Revoke vs spend front-running on Permit2Treasury

**Location:** `src/modules/core/deals/Permit2Treasury.sol:128-139, 208-227`

A malicious agent who knows their allowance is about to be revoked can submit a higher-gas-priced `executeAgentSpend` ahead of the revoke proposal's execution, draining `totalAmount` first. This is the standard "revoke front-run" issue endemic to allowance-based systems. Mitigations are out of scope (would require commit-reveal or off-chain coordination); documentation is sufficient.

#### I-10: `MainToken._update` and `_delegate` will revert if invoked between `initialize` and `dacInit`

**Location:** `src/kernel/tokens/MainToken.sol:52-68`

```solidity
function _afterTokenTransfer(address from, address to, uint256 amount) private {
    IDealManagerAdapter(dealManager).onMainMove(from, to, amount);
}
```

If any transfer or delegate operation is attempted on MainToken *after* `initialize` but *before* `dacInit` sets `dealManager`, the callback reverts (EXTCODESIZE check on `address(0)`). The legitimate flow has `DACFactory._initializeDAC` call `dacInit` via `initializeAfterDeployment` before any transfer can happen (no mint has occurred yet, no holders exist), so this is not a vulnerability.

Worth noting because:
- A test or scenario that mints MainToken directly before `dacInit` will fail confusingly.
- A future fork or refactor that splits the deployment flow could expose the window.

Cheap improvement: gate the callback on `if (dealManager != address(0))`.

---

## 6. Verification of prior High and Medium findings

The prior audit (`6847a64`) identified one High (H-01) and one Medium (M-01) that landed in this audit's baseline. Both were verified intact:

### H-01 — `consumeExecution` executor gate

**Files verified:**
- `src/kernel/governance/Proposal.sol:14-22, 129-142` — `executor` storage field; `consumeExecution` requires `msg.sender == executor`
- `src/kernel/governance/HybridDACManagementProposal.sol:29, 67-94, 250-263` — same pattern on the hybrid proposal
- `src/kernel/governance/DealManagementProposal.sol:37` — `executor` decoded from `addresses` blob and passed to `__Proposal_init`
- `src/kernel/governance/factories/DACManagementProposalFactory.sol:67` — passes `msg.sender` as executor
- `src/kernel/governance/factories/DealManagementProposalFactory.sol:133` — packs `msg.sender` into `addresses` blob as executor
- `src/kernel/governance/factories/HybridDACManagementProposalFactory.sol:33` — passes `msg.sender` as executor

The executor is structurally bound at factory-deployment to the address that ultimately drives `consumeExecution`:
- DACManagementProposal → executor = NativeGovernanceSchema (which holds `consumeApprovedProposal` `onlyDACCell`)
- HybridDACManagementProposal → executor = HybridGovernanceSchema (same)
- DealManagementProposal → executor = Deal (which holds `executeStakedAgentProposal`)

The 4 regression tests in `test/audit/ConsumeExecutionGriefingPoc.t.sol` continue to pass against the current commit.

### M-01 — SafeERC20 on TreasuryDeal

**Files verified:**
- `src/modules/core/deals/TreasuryDeal.sol:18` — `using SafeERC20 for IERC20`
- `src/modules/core/deals/TreasuryDeal.sol:66` — `_afterApprove` uses `safeTransfer`
- `src/modules/core/deals/TreasuryDeal.sol:228` — `recoverProfits` uses `safeTransfer`

---

## 7. Test Coverage

### 7.1 Suite results on commit `be026d9`

```
Total tests:    188
Passing:        188
Failing:        0
Skipped:        0
```

### 7.2 Categories

| Category | Tests | Notes |
|---|---|---|
| `DealGovernanceFlowTest` | ≥23 | Lifecycle, voting, execution, veto challenges |
| `Permit2TreasuryTest` | 17 | Agent spend/receive, Permit2 flows, revocation |
| `RevenueBasedEvaluatorTest` | ≥17 | Revenue cycles, slashing, auto-close, grace periods |
| `MilestoneBasedEvaluatorTest` | ≥12 | Milestones, curves, extensions, FDV mode |
| `HybridDACManagementProposalTest` | ≥8 | Multi-phase voting, oracle, fallback, emergency |
| `DACDealVoteSignTest` | new | ERC-1271 external venue voting (snapshot.org) |
| `DealCellGovernanceLibBranchTest` | 16 | Branch coverage on deal governance |
| `ExistingTokenAssetControllerTest` | new | Hybrid-mode controller paths |
| `WrappedMainTokenTest` | new | Wrap/unwrap accounting incl. fee-on-transfer |
| `DACAccountingFuzzTest` / `AccountingObligationsFuzzTest` / `TreasuryCapitalAccountingFuzzTest` | 6 fuzz | Treasury obligations, capital accounting |
| `test/audit/ConsumeExecutionGriefingPoc.t.sol` | 4 | H-01 regression — all passing |
| Other | balance | Deployment, tokens, dividends, deal config |

### 7.3 Coverage gaps observed

The existing suite would benefit from explicit tests for the Low-severity findings above:

- **L-01**: A test that mocks `DACCell` calling `onAgentTokenStaked` and asserts the new behavior after the dacCell branch is removed (or asserts an explicit error).
- **L-02**: A negative test for `approveSpendAllowance` with `duration == 0` after the validation is added.
- **L-04**: A test that calls `WrappedMainToken.setController` a second time and asserts revert after the one-shot guard is added.
- **I-10**: A test that exercises a transfer between `initialize` and `dacInit` (would currently revert with a confusing error).

Pre-existing coverage gaps from the prior audit also still apply:

- **Non-standard ERC-20s** (USDT-style, fee-on-transfer that yields zero on legitimate amounts) in `TreasuryDeal` paths.
- **Oracle malfunction paths** in evaluators (zero price, extreme price, reverting oracle).
- **Concurrent large-N deal evaluation gas** measurements.
- **`startDAC` deferred-init path** edge cases (re-call after success, missing sleeping cell entry).

---

## 8. Contract Interaction Map

```
                          External User
                              │
                       [DACFactory] (immutable)
            ┌─────────────────┴─────────────────────────┐
            │                                            │
    Native flow:                              Existing-token flow:
       ↓                                          ↓
    [DACCell] ←──── governance schema ────→  [DACCell]
       │              proposals via              │
       │           consumeApprovedProposal       │
       │                                          │
       ├── [NativeGovernanceSchema]               ├── [HybridGovernanceSchema]
       ├── [NativeAssetController]                ├── [ExistingTokenAssetController]
       ├── [MainToken (ERC20Votes, ts clock)]     ├── [WrappedMainToken (ERC20Votes, blk clock)]
       │                                          │   └── [Underlying ERC-20]
       │                                          ├── [BasicGovernanceOracle] ← (shared across DACs)
       │                                          │
       └── [AgentToken] (bound + distributor)     └── [AgentToken]

                       ↓ both branches
                  [ModuleRegistry] → approved [CoreModuleFactory] (and others)
                       ↓
                  [DealManager]
                       │
                       ├── deals[1] → [DealCell] → [StakedAgent]
                       │                          → [Deal] (DACDeal | TreasuryDeal | …)
                       │                              ↳ DACDeal: child [DACCell] (recursive)
                       │                              ↳ TreasuryDeal: [Permit2Treasury]
                       │                          → [Evaluator] (Milestone | Revenue)
                       └── deals[N] → …
```

---

## 9. Trust Boundary Map (verified)

Each row lists a privileged operation, who is allowed to initiate, and the chain of gates that enforce it.

| Operation | Caller | Gate chain |
|---|---|---|
| Create DAC | anyone | `DACFactory.deployDAC` (permissionless by design; deployed DAC is self-contained) |
| Create deal proposal | agent | `DealManager.createDealProposal` `onlyAgent` → `DACCellGovernanceLib.createDealProposal` checks `proposer == msg.sender` |
| Approve / fulfill capital call | call recipient | `DACCell.fulfillCapitalCall` (permissionless trigger) → controller `onlyDACCell` → pulls cash from `tokenRecipient` (recipient must have approved) |
| Create DAC management proposal | holder/manager | `DACCell.createManagementProposal` `onlyHolderOrManager` → schema `onlyDACCell` |
| Execute DAC management proposal | anyone | `DACCell.executeDACProposal` → schema `consumeApprovedProposal` `onlyDACCell` → proposal `consumeExecution` `msg.sender == executor` (= schema) |
| Stake to deal | agent token holder | `AgentToken.stakeToDeal` (self) or `forceStakeToDeal` (DealManager only) → `DealCell.onAgentTokenStaked` `msg.sender == agentTokenAddr` (or dead `dacCell` branch — see L-01) |
| Create deal-level proposal | staked agent (or Deal/DealCell/DealManager) | `Deal.createStakedAgentProposal` → `DealCellGovernanceLib.checkStakedAgentProposal` (branches by msg.sender; non-special caller must have qualified stake) |
| Execute deal-level proposal | anyone | `Deal.executeStakedAgentProposal` → proposal `consumeExecution` `msg.sender == executor` (= Deal) |
| Mark deal success / failed / extend | DealManager (via evaluator) | `DealCell.markAsSuccess` / `markAsFailed` / `extendDeadline` all `onlyDealManager` |
| Recover deal | DAC governance via legal-wrapper authorization | `DealManager.executeProp` (RECOVER_DEAL branch) `onlyDACCell` + legal-wrapper-msg-sender check |
| Mint main token rewards | DealCell (via DealManager) | `DealCell.claimMainToken` → `DealCellGovernanceLib.claimMainToken` → `DealManager.mintMain` `onlyDealCell` → controller `settleMainRewardClaim` `onlyDealManager` |
| Update voting / strategy / oracle config | DAC governance proposal | `DACCell.executeDACProposal` → `_executeXxxUpdate` → schema setter `onlyDACCell` |
| Publish oracle snapshot | publisher | `BasicGovernanceOracle.publishSnapshot` `onlyRole(PUBLISHER_ROLE)` |
| Deactivate oracle for a DAC | admin or publisher | `BasicGovernanceOracle.deactivate` (DEFAULT_ADMIN_ROLE OR PUBLISHER_ROLE) |
| Wrap / unwrap existing token | anyone | `WrappedMainToken.wrap` / `unwrap` permissionless by design (only affects caller's own tokens) |
| Move main token (transfer) | any holder | `MainToken._update` → `_afterTokenTransfer` → `DealManager.onMainMove` `msg.sender == mainToken` → controller `onMainMove` `onlyDealManager` |
| Move wrapped main token (transfer) | any holder | `WrappedMainToken._update` → `_afterTokenTransfer` → controller `onMainMove` `onlyWrappedMainToken` |
| Approve agent spend allowance | DAC governance via deal | `Deal.executeStakedAgentProposal` → `TreasuryDeal._executeModuleManagementProposal` → `Permit2Treasury.approveSpendAllowance` `onlyDeal` |
| Execute agent spend | the agent itself | `Permit2Treasury.executeAgentSpend` (permissionless caller; bound by `agentAllowance[(msg.sender, token, dest)]`) |
| Claim dividend | anyone with valid Merkle proof | `DACCell.claimDividend` → controller `claimDividend` `onlyDACCell` + Merkle verification |
| Register controlled address | DealCell | `DealCell.registerControlledAddress` `onlyDeal` → `DealManager.registerControlledAddress` `onlyDealCell` → controller `registerControlledAddress` `onlyDealManager` |

No gate chain in the table above terminates in an unguarded surface.

---

## 10. Conclusion

The DAC Cloud codebase is in strong shape for the testnet deployment. The kernel/module split is clean, the dual-token native/hybrid architecture is internally consistent, and the discipline of explicit `require(msg.sender == X)` or `onlyX` modifiers on every state-mutating external function is held throughout. The H-01 fix is correctly structural — the executor is bound at factory time to the only address that legitimately drives execution, and the binding cannot be tampered with by a third party.

**No High- or Medium-severity vulnerabilities were identified in this pass.**

The Low-severity findings are all hardening / defense-in-depth improvements rather than current exploitable issues. The most important among them is **L-01** (`DealCell.onAgentTokenStaked` over-broad caller gate) because it matches the exact H-01 pattern the prior audit's two iterations both found: a caller gate that *looks* properly modifier-protected but admits more callers than the design needs. Removing the dead `dacCell` branch closes that specific instance of the class and is cheap to apply.

### Recommended actions before testnet deployment

Prioritized:

1. **L-01** — Drop `|| msg.sender == dacCell` from `DealCell.onAgentTokenStaked`. **Highest priority** as it directly addresses the recurring pattern.
2. **L-02** — Add `duration > 0` and `singleTxAmount > 0` validation to `Permit2Treasury.approveSpendAllowance`.
3. **L-04** — Add one-shot guard to `WrappedMainToken.setController`.
4. **L-06** — Add one-shot guard to `Deal.joinDac`.
5. **I-01** — Delete the orphan `DACCellGovernanceLib.approveFunding` function.
6. **L-05** — Make `DealManager._onlyDealCell` existence check explicit.
7. **L-03, L-07** — Document the wildcard fallthrough and overwrite-vs-increment semantics on `Permit2Treasury`.
8. **I-03** — Add explicit one-shot guards to `MainToken.dacInit` and `AgentToken.dacInit`.
9. **I-10** — Gate `MainToken._afterTokenTransfer` / `_beforeDelegate` on `dealManager != address(0)` for cleaner error in edge cases.

The remaining informational items are code-hygiene observations that can be addressed in routine maintenance without urgency.

### Final state

- 188 / 188 tests passing.
- `forge build` clean (warnings only, no errors).
- Source tree: 10,250 LoC across 88 files.

---

*This audit was produced by an automated security review system (Claude Opus 4.7, 1M-context). Findings reflect the auditor's best assessment of the code at commit `be026d9`. The codebase has now passed three rounds of independent automated review, each producing progressively smaller findings sets. As with any single-auditor review, a complementary review by an independent firm is recommended before mainnet deployment; for testnet deployment, the current codebase appears ready subject to the hardening recommendations above.*
