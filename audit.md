# DAC Cloud Contracts - Security Audit Report

**Audit Date:** April 14, 2026
**Auditor:** Claude Opus 4.6 (Automated Security Review)
**Repository:** dac-cloud-contracts
**Commit:** `dbbd67b` (branch: `develop`)
**Solidity Version:** ^0.8.20
**Framework:** Foundry

---

## 1. Executive Summary

This report presents a comprehensive security audit of the DAC Cloud smart contract protocol. The audit covers all 87 Solidity source files comprising the kernel layer (DACCell, DealManager, DealCell, Deal, AssetControllers, Governance, Tokens) and the core module layer (DACDeal, TreasuryDeal, Permit2Treasury, MilestoneBasedEvaluator, RevenueBasedEvaluator).

The protocol implements a dual-token governance system for Decentralized Autonomous Companies (DACs) with two operational modes: Native (mint-based) and Existing Token (wrap-based). It features a modular deal management framework with agent staking, on-chain evaluators, and multi-phase hybrid governance.

**Overall Assessment:** The codebase demonstrates strong security fundamentals. No critical or high severity vulnerabilities were identified. The architecture follows sound separation-of-concern patterns, access controls are consistently enforced, and the absence of dangerous low-level primitives (`delegatecall`, `selfdestruct`, `tx.origin`, `unchecked`) eliminates entire vulnerability classes. All 168 test cases pass.

### Findings Summary

| Severity       | Count |
|----------------|-------|
| Critical       | 0     |
| High           | 0     |
| Medium         | 2     |
| Low            | 5     |
| Informational  | 6     |

---

## 2. Scope

### 2.1 Contracts in Scope

**Kernel Core (7 contracts)**
- `DACCell.sol` (684 lines) - Primary DAC governance controller
- `DACFactory.sol` (293 lines) - DAC deployment with Create2
- `DealManager.sol` (405 lines) - Deal lifecycle management
- `DealCell.sol` (575 lines) - Per-deal governance wrapper
- `Deal.sol` (332 lines) - Abstract deal base with hook system
- `ModuleFactory.sol` (53 lines) - Abstract module deployer
- `ModuleRegistry.sol` (46 lines) - Module whitelist

**Kernel Tokens (4 contracts)**
- `MainToken.sol` (93 lines) - ERC20Votes governance token
- `AgentToken.sol` (142 lines) - Soulbound-ish agent token with transfer restrictions
- `StakedAgent.sol` (63 lines) - Non-transferable staking receipt token
- `WrappedMainToken.sol` (108 lines) - Wrapped ERC20Votes for existing-token mode

**Kernel Controllers (2 contracts)**
- `NativeAssetController.sol` (378 lines) - Treasury for native DACs
- `ExistingTokenAssetController.sol` (392 lines) - Treasury for existing-token DACs

**Kernel Governance (6 contracts)**
- `Proposal.sol` (231 lines) - Abstract voting proposal
- `DACManagementProposal.sol` (36 lines) - DAC-level proposal
- `DealManagementProposal.sol` (115 lines) - Deal-level proposal with veto challenge
- `NativeGovernanceSchema.sol` (266 lines) - Native mode governance
- `HybridGovernanceSchema.sol` (304 lines) - Hybrid mode governance
- `HybridDACManagementProposal.sol` (472 lines) - Multi-phase proposal with oracle + fallback
- `GovernanceOracle.sol` (96 lines) - Off-chain snapshot oracle

**Kernel Libraries (3 libraries)**
- `DACCellGovernanceLib.sol` (539 lines) - DAC governance logic
- `DealCellGovernanceLib.sol` (590 lines) - Deal governance logic
- `MathLib.sol` (101 lines) - Fixed-point percentage arithmetic

**Core Module (5 contracts)**
- `CoreModuleFactory.sol` (107 lines) - Core module router
- `DACDeal.sol` (298 lines) - Child-DAC deal type
- `TreasuryDeal.sol` (242 lines) - Permit2-based treasury deal
- `Permit2Treasury.sol` (269 lines) - Agent-operated treasury
- `MilestoneBasedEvaluator.sol` (270 lines) - Milestone evaluator
- `RevenueBasedEvaluator.sol` (223 lines) - Revenue-cycle evaluator

**Also reviewed:** All 22 factory contracts, 6 interface files, proxy contract, deployment library, and all 26 test files (including 3 fuzz tests).

### 2.2 Out of Scope

- Off-chain infrastructure (oracle publishers, frontend, indexers)
- Third-party dependencies (OpenZeppelin, Uniswap Permit2) - assumed correct
- Deployment scripts and seed scenarios

---

## 3. Methodology

The audit employed the following approach:

1. **Manual code review** - Line-by-line review of every contract in `src/`
2. **Architecture analysis** - Trust boundary mapping, access control verification, state machine validation
3. **Attack surface enumeration** - Systematic check for OWASP smart contract vulnerabilities
4. **Invariant analysis** - Verification of accounting invariants (treasury balances, token obligations, reward caps)
5. **Cross-contract interaction review** - Tracing call chains across kernel-module boundaries
6. **Test coverage analysis** - Review of existing test suite (168 tests, all passing)

### Vulnerability Categories Checked

| Category | Result |
|---|---|
| Reentrancy | ReentrancyGuard used on entry points; callbacks are controlled |
| Integer overflow/underflow | Solidity 0.8 checked arithmetic; no `unchecked` blocks |
| Access control bypass | All modifiers verified; role separation is consistent |
| Front-running | Governance proposals use snapshot-based voting |
| Oracle manipulation | External oracle dependency noted (see L-03) |
| Flash loan attacks | Token snapshots use past-block values |
| Proxy risks | UUPS proxies are non-upgradeable (no upgrade function exposed) |
| Denial of service | Unbounded iteration noted (see M-02) |
| Signature malleability | Permit2 signatures delegated to audited Uniswap contract |
| `tx.origin` abuse | Not used anywhere |
| `delegatecall` injection | Not used anywhere |
| `selfdestruct` griefing | Not used anywhere |
| Unchecked return values | Identified in token transfers (see M-01) |

---

## 4. Architecture Overview

### 4.1 System Design

```
DACFactory (immutable deployer)
 |
 +-- DACCell (governance hub)
      |-- MainToken (ERC20Votes, governance weight)
      |-- AgentToken (bounded-transfer, agent identity)
      |-- AssetController (treasury, capital calls, dividends)
      |-- GovernanceSchema (proposal creation, voting config)
      |-- ModuleRegistry (approved module whitelist)
      |-- DealManager (deal lifecycle)
           |-- DealCell[n] (per-deal governance)
           |    |-- StakedAgent (non-transferable receipt)
           |    |-- Deal (module-deployed logic)
           |    |-- Evaluator[n] (performance evaluation)
           |    +-- Tranche[n] (funding tranches)
           +-- ...
```

### 4.2 Trust Model

- **No admin keys.** The DACFactory is immutable; once a DAC is deployed, governance is fully on-chain.
- **Dual-token separation.** Main token holders (LPs / "chickens") vote on capital allocation. Agent token holders ("pigs") propose and execute deals. Neither role can unilaterally override the other.
- **Module boundary.** The kernel deploys DealCells; modules deploy Deals. Modules cannot control DealCell initialization, preventing rogue modules from manipulating the governance wrapper.
- **Evaluator isolation.** Evaluators can recommend reward/slash actions but the kernel enforces caps. Even a compromised evaluator + deal pair cannot mint rewards beyond the governance-approved `rewardsLimit`.
- **Challenge mechanism.** Deal proposals can be challenged by DAC-level veto proposals, creating a two-tier governance check.

### 4.3 Positive Security Patterns Observed

- `_disableInitializers()` in all implementation constructors prevents implementation contract initialization
- `Initializable` on every proxy-deployed contract prevents re-initialization
- No use of `selfdestruct`, `delegatecall`, `tx.origin`, or `unchecked` blocks
- Consistent custom error usage throughout (gas-efficient, descriptive)
- 88 events providing comprehensive audit trail
- 27 modifiers enforcing role-based access at every boundary
- UUPS proxies without upgrade mechanisms - contracts are effectively immutable post-deployment
- Snapshot-based voting prevents flash-loan vote manipulation
- Reward minting is double-capped: evaluator `permitMint` + kernel `rewardsPaid <= rewardsUnlocked <= rewardsLimit`

---

## 5. Findings

### MEDIUM SEVERITY

#### M-01: Inconsistent ERC20 Transfer Handling May Block Non-Standard Tokens

**Location:** `NativeAssetController.sol`, `ExistingTokenAssetController.sol`, `DealCellGovernanceLib.sol`

**Description:**
Token transfers in the AssetController contracts and governance library use bare `require(IERC20(token).transfer(...))` and `require(IERC20(token).transferFrom(...))` patterns instead of SafeERC20's `safeTransfer`/`safeTransferFrom`. Non-standard ERC20 tokens that do not return a boolean value (e.g., USDT, BNB, OMG) will cause these calls to revert at the ABI decoding level.

**Affected code paths (representative samples):**

```solidity
// NativeAssetController.sol:76
require(IERC20(token).transferFrom(from, address(this), amount), DACErrorsLib.TransferFailed());

// NativeAssetController.sol:201
require(IERC20(token).transfer(dealManager, fundingAmount), DACErrorsLib.TransferFailed());

// DealCellGovernanceLib.sol:326-330
require(IERC20(tranche.token).transfer(address(deal), tranche.amount), DACErrorsLib.TransferFailed());
```

In contrast, the module-level contracts (`DACDeal.sol`, `TreasuryDeal.sol`, `Permit2Treasury.sol`) correctly use `SafeERC20`:

```solidity
// Permit2Treasury.sol:99
IERC20(token).safeTransfer(destination, amount);
```

**Impact:** A DAC configured with a non-standard ERC20 as its treasury token or deal funding token would be unable to execute capital flows (funding approvals, dividend payouts, capital returns). No funds are at risk since the transactions would revert, but the DAC would be non-functional for those token types.

**Recommendation:** Replace all bare `transfer`/`transferFrom` calls in `NativeAssetController`, `ExistingTokenAssetController`, and `DealCellGovernanceLib` with SafeERC20 wrappers (`safeTransfer`, `safeTransferFrom`). Alternatively, document non-standard tokens as unsupported.

---

#### M-02: Unbounded Linear Iteration Over Holders Array

**Location:** `DealCellGovernanceLib.sol` - `stake()`, `addStake()`, `markAsSuccess()`, `markAsFailed()`, `_allocateStakerRewards()`, `whitelistHolders()`

**Description:**
Multiple functions iterate over the `holders[]` storage array with `O(n)` complexity:

```solidity
// DealCellGovernanceLib.sol:54-58
bool newHolder = true;
for (uint256 i = 0; i < holders.length; i++) {
    if (holders[i] == staker) {
        newHolder = false;
    }
}
```

This pattern appears in staking (duplicate check), reward allocation (pro-rata distribution), slashing (per-holder slash), and whitelist toggling (invite all holders). When `agentsLimit` is set to 0 (unlimited), the array can grow without bound.

**Impact:** Gas costs scale linearly with the number of stakers. For deals with many agents:
- `evaluateDeal` → `markAsSuccess` → `_allocateStakerRewards`: iterates all holders per evaluation
- `evaluateDeal` → `markAsFailed` → iterates all holders to slash
- Staking iterates all holders to check for duplicates

A deal with hundreds of agents could face gas costs exceeding block gas limits during evaluation, effectively bricking the deal.

**Recommendation:**
- Consider using a `mapping(address => bool)` for the duplicate check in `stake()` and `addStake()`
- Document a practical upper bound for `agentsLimit` (e.g., 50-100 agents)
- Consider lazy reward distribution (claim-based) instead of push-based allocation if larger agent counts are needed

---

### LOW SEVERITY

#### L-01: Simplified MathLib.mulDiv Incorrect for 512-bit Products

**Location:** `MathLib.sol:20-41`

**Description:**
The assembly `mulDiv` function performs full 512-bit product computation but only divides the lower 256-bit word:

```solidity
result := div(prod0, denominator)
```

For products where `x * y > 2^256` and the adjusted `prod1 > 0`, this discards the high word and returns an incorrect result. The overflow check (`denominator > prod1`) prevents some but not all such cases.

**Impact:** Low. All current usage involves SCALE (1e18) operations on token amounts that stay well within 256-bit single-word products. The function correctly reverts for very large inputs via the overflow guard.

**Recommendation:** If larger value ranges may be needed in future modules, replace with OpenZeppelin's `Math.mulDiv` which handles full 512-bit division. For current usage, document the valid input range (e.g., `x * y < 2^256`).

---

#### L-02: Stale `sleepingCells` Entry After `startDAC`

**Location:** `DACFactory.sol:165-178`

**Description:**
When `startDAC` is called to initialize a deferred DAC, the `sleepingCells[deferInitCell]` mapping entry is validated but never deleted:

```solidity
function startDAC(...) external {
    bytes32 deferInitCell = keccak256(abi.encode(msg.sender, dacCell));
    require(sleepingCells[deferInitCell] != bytes32(0), SleepingCellNotFound());
    bytes32 deferInitCalldata = keccak256(abi.encode(config, mainTokenAddr, agentTokenAddr));
    require(sleepingCells[deferInitCell] == deferInitCalldata, DNAMismatch());
    _initializeDAC(DACCell(dacCell), config, mainTokenAddr, agentTokenAddr);
    // sleepingCells[deferInitCell] not deleted
}
```

**Impact:** Minimal. The `initializeAfterDeployment` call inside `_initializeDAC` sets `cellStarted = true` on the DACCell, so replay is prevented by the DACCell's own guard. The stale mapping entry wastes ~20k gas worth of storage.

**Recommendation:** Add `delete sleepingCells[deferInitCell]` after successful initialization. Also provides gas refund.

---

#### L-03: External Oracle Dependency in Evaluators

**Location:** `MilestoneBasedEvaluator.sol:267-269`, `RevenueBasedEvaluator.sol`

**Description:**
Both evaluators call `IPriceOracle(oracle).tokenPrice(token)` for valuation calculations. The `IPriceOracle` interface is minimal (single `tokenPrice` function) and the contract assumes the oracle returns a normalized 18-decimal price.

```solidity
function getOraclePrice(address oracle, address token) internal view returns (uint256) {
    return IPriceOracle(oracle).tokenPrice(token);
}
```

No validation is performed on the oracle response (staleness, zero-price, extreme values).

**Impact:** A manipulated or malfunctioning oracle could cause evaluators to report incorrect progress, leading to unearned rewards or unjust slashing. The risk is bounded by the evaluator's `rewardShare` cap and the deal's `rewardsLimit`.

**Recommendation:**
- Add sanity checks on oracle responses (non-zero, within reasonable bounds)
- Consider supporting Chainlink-style oracle interfaces with staleness checking
- Document oracle requirements and trust assumptions for module developers

---

#### L-04: `_freeBalance` Underflow Reverts on Invariant Violation

**Location:** `NativeAssetController.sol:339-341`, `ExistingTokenAssetController.sol:356-358`

**Description:**
```solidity
function _freeBalance(address token) internal view returns (uint256) {
    return treasuryBalances[token] - committedBalances[token];
}
```

If `committedBalances[token]` ever exceeds `treasuryBalances[token]` due to an accounting edge case, this subtraction reverts via Solidity 0.8 underflow protection, blocking all treasury operations that call `_freeBalance` (funding approvals, dividend payouts, minting).

**Impact:** Low. The invariant `treasuryBalances >= committedBalances` is maintained by the contract logic. However, a bug in commitment tracking (e.g., double-committing) would make the treasury permanently non-functional for that token rather than gracefully degrading.

**Recommendation:** Consider adding a view function to detect invariant violations for monitoring, or using a `>=` check with a zero floor to preserve partial functionality.

---

#### L-05: No Timelock on Governance Parameter Changes

**Location:** `DACCell.sol:467-601`, `NativeGovernanceSchema.sol:146-165`

**Description:**
Governance configuration changes (voting config, legal wrapper, module additions/removals, governance strategy) take effect immediately upon proposal execution. There is no delay between vote completion and parameter activation.

```solidity
function _executeVotingConfigUpdate(uint256 id, IManagementProposal prop) internal {
    IGovernanceSchema(governanceSchema).setVotingConfig(abi.decode(prop.data(), (VotingConfig)));
    // Takes effect immediately
}
```

**Impact:** A governance attack that lowers quorum requirements could cascade: a malicious quorum reduction is immediately effective, making subsequent malicious proposals easier to pass. The `executionValidityDuration` window provides some protection, but a coordinated attack within a single voting cycle could be effective.

**Recommendation:** Consider a separate timelock or a two-step process for sensitive parameter changes (quorum reduction, module removal, governance oracle changes). This is a common pattern in DAO governance (e.g., OpenZeppelin TimelockController).

---

### INFORMATIONAL

#### I-01: Typo in Function Name `rewokeAgent`

**Location:** `Permit2Treasury.sol:129`

```solidity
function rewokeAgent(
```

Should be `revokeAgent`. This is a public function and will be part of the ABI.

---

#### I-02: `DealManager.onMainDelegate` Declared as `view` but Calls External `view`

**Location:** `DealManager.sol:305-308`

```solidity
function onMainDelegate(address from, address to) external view {
    require(msg.sender == address(mainToken), DACErrorsLib.NotAuthorized());
    IAssetController(assetController).onMainDelegate(from, to);
}
```

The function is `view` and calls `IAssetController.onMainDelegate` which is also `view`. This is correct but slightly unusual. The `view` modifier correctly indicates no state changes.

---

#### I-03: `claimDividend` Is Permissionless by Design

**Location:** `DACCell.sol:439-455`

The function has no caller restriction. Anyone can submit a valid Merkle proof to claim dividends on behalf of a receiver. This is intentional - it enables meta-transaction relaying of dividend claims. The receiver (not the caller) receives the tokens, as enforced by the Merkle proof.

---

#### I-04: `DealCell.onAgentTokenStaked` Lacks `nonReentrant`

**Location:** `DealCell.sol:209-222`

This external function calls `deal.onVoluntaryStake(staker, amount)` which is a callback to module code. While the function is access-controlled to `agentTokenAddr || dacCell`, a malicious deal contract could theoretically reenter. The risk is mitigated because:
- The deal is deployed by a module-approved factory
- The staker's agent tokens are already transferred before this call
- The StakedAgent mint is the only state change after the callback

---

#### I-05: `CoreModuleFactory` Accepts Any Evaluator-Deal Cross-Module Combination

**Location:** `CoreModuleFactory.sol:64-71`

```solidity
function dealAcceptsEvaluator(bytes4, bytes4, address) external pure returns (bool) {
    return true;
}
function evaluatorAcceptsDeal(bytes4, bytes4, address) external pure returns (bool) {
    return true;
}
```

The core module accepts all evaluator-deal combinations from any approved module. This is a permissive design choice that relies on the module approval governance process for security.

---

#### I-06: Assembly Usage Is Minimal and Correct

Three assembly blocks exist in the codebase:

1. **`MathLib.mulDiv`** (lines 21-40) - Gas-optimized multiplication-division with overflow protection
2. **`RevenueBasedEvaluator.evaluateDeal`** (line 182) - Dynamic array resizing: `assembly { mstore(results, resultIndex) }`
3. **`MilestoneBasedEvaluator.evaluateDeal`** (line 195) - Same array resizing pattern

All three uses are standard optimization patterns with no security implications.

---

## 6. Gas Optimizations

These are non-security observations that could reduce gas costs:

| # | Location | Observation |
|---|---|---|
| G-01 | `DealCellGovernanceLib.stake:54-58` | Linear duplicate check could use a `mapping(address => bool)` lookup |
| G-02 | `DACCellGovernanceLib.evaluateDeal:474-484` | Evaluation result loop allocates array upfront; could use dynamic sizing |
| G-03 | `DACFactory.startDAC` | Missing `delete sleepingCells[deferInitCell]` forfeits ~4,800 gas refund |
| G-04 | Multiple contracts | `address(0)` checks could use custom errors instead of generic `NotAllowed()` for better debugging |

---

## 7. Test Coverage

### 7.1 Test Suite Results

```
Total tests:    168
Passing:        168
Failing:          0
Skipped:          0
```

### 7.2 Test Categories

| Category | Tests | Description |
|---|---|---|
| DealGovernanceFlowTest | 23 | Proposal lifecycle, voting, execution, veto challenges |
| Permit2TreasuryTest | 17 | Agent spend/receive, Permit2 flows, revocation |
| RevenueBasedEvaluatorTest | 17 | Revenue cycles, slashing, auto-close, grace periods |
| DealCellGovernanceLibBranchTest | 16 | Branch coverage for deal governance edge cases |
| DealEvaluationRecoveryTest | 14 | Evaluation + recovery flow, deal closure |
| MilestoneBasedEvaluatorTest | 12 | Milestone progress, curves, extensions, FDV mode |
| MathLibTest | 12 | Fixed-point arithmetic, edge cases, signed math |
| HybridDACManagementProposalTest | 8 | Multi-phase voting, oracle, fallback, emergency |
| DACGovernanceControlTest | 7 | Config updates, blocking quorum, capability checks |
| DirectAccessControlTest | 5 | Unauthorized access rejection across all entry points |
| Fuzz tests (3 suites) | 7 | Accounting obligations, capital accounting, DAC accounting |
| Other test suites | 30 | Deployment, tokens, dividends, existing-token mode |

### 7.3 Coverage Observations

**Well covered:**
- Deal creation → approval → evaluation → close lifecycle
- Governance proposal full lifecycle (create, vote, execute, expire)
- Hybrid governance multi-phase flow (oracle → warmup → fallback)
- Agent staking and unstaking with access control
- Permit2Treasury agent operations
- Evaluator reward/slash calculations with curves
- Mathematical operations including edge cases
- Access control rejection (5 dedicated tests)
- Veto challenge mechanism

**Recommended additional coverage:**
- Edge cases around `_freeBalance` when balances approach zero
- Non-standard ERC20 behavior (fee-on-transfer, rebasing tokens)
- Very large `agentsLimit` values and gas consumption
- Concurrent deal operations within a single DAC
- Module addition/removal during active deals

---

## 8. Contract Interaction Map

```
                    External User
                         |
                    [DACFactory]
                         |
     +-------------------+-------------------+
     |                                       |
 [DACCell]                           [WrappedMainToken]
     |                                       |
     +---- [GovernanceSchema] ----+          [Underlying ERC20]
     |         (Native or Hybrid)  |
     +---- [AssetController] -----+
     |         (Native or Existing)|
     +---- [ModuleRegistry] ------+
     |
 [DealManager]
     |
     +---- [DealCell #1] --+-- [StakedAgent]
     |         |            +-- [Deal (DACDeal)]
     |         |            +-- [Evaluator (Milestone)]
     |
     +---- [DealCell #2] --+-- [StakedAgent]
               |            +-- [Deal (TreasuryDeal)]
               |            |      +-- [Permit2Treasury]
               |            +-- [Evaluator (Revenue)]
```

---

## 9. Conclusion

The DAC Cloud contracts demonstrate mature security architecture and careful implementation. The dual-token governance model with challenge mechanisms, evaluator-capped rewards, and module isolation provides robust safeguards against common DeFi attack vectors.

**Key strengths:**
- Zero use of dangerous primitives (`delegatecall`, `selfdestruct`, `tx.origin`, `unchecked`)
- Comprehensive event logging (88 events) for off-chain monitoring
- Immutable deployment model with no admin keys or upgrade paths
- Double-capped reward system preventing runaway minting
- Snapshot-based voting immune to flash-loan manipulation
- Well-structured test suite with 100% pass rate including fuzz tests

**Key recommendations before mainnet deployment:**
1. Add SafeERC20 wrappers to all token transfer calls in AssetControllers and governance libraries (M-01)
2. Document or enforce a practical `agentsLimit` ceiling to prevent gas exhaustion (M-02)
3. Add oracle response validation in evaluators (L-03)
4. Consider timelock or two-step process for quorum-reduction proposals (L-05)
5. Fix `rewokeAgent` typo before ABI is locked (I-01)
6. Expand test coverage for edge cases noted in Section 7.3

---

*This audit was performed by an automated system and should be complemented by manual review from specialized security auditors before production deployment. The findings represent the auditor's best assessment at the time of review and do not constitute a guarantee of security.*
