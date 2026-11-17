// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DACCell} from "../../src/kernel/DACCell.sol";
import {DACFactory} from "../../src/kernel/DACFactory.sol";
import {Deal} from "../../src/kernel/Deal.sol";
import {DealManager} from "../../src/kernel/DealManager.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {IAssetController} from "../../src/interfaces/IAssetController.sol";
import {DACErrorsLib} from "../../src/interfaces/DACErrorsLib.sol";
import {IDACCell} from "../../src/interfaces/IDACCell.sol";
import {IVoting} from "../../src/interfaces/IVoting.sol";
import {IExecutableProposal} from "../../src/interfaces/IExecutableProposal.sol";
import {
    DACConfig,
    CapitalCall,
    ProposalParams,
    DealParams,
    EvaluationResult,
    Tranche
} from "../../src/interfaces/Structs.sol";
import {DealState} from "../../src/kernel/interfaces/Structs.sol";
import {IDealManagerAdapter} from "../../src/kernel/interfaces/IDealManagerAdapter.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {Proposal} from "../../src/kernel/governance/Proposal.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {DACManagementProposalFactory} from "../../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {NativeGovernanceSchemaFactory} from "../../src/kernel/governance/factories/NativeGovernanceSchemaFactory.sol";
import {HybridGovernanceSchemaFactory} from "../../src/kernel/governance/factories/HybridGovernanceSchemaFactory.sol";
import {GovernanceOracleFactory} from "../../src/kernel/governance/factories/GovernanceOracleFactory.sol";
import {
    HybridDACManagementProposalFactory
} from "../../src/kernel/governance/factories/HybridDACManagementProposalFactory.sol";
import {DACCellFactory} from "../../src/kernel/factories/DACCellFactory.sol";
import {DealManagerFactory} from "../../src/kernel/factories/DealManagerFactory.sol";
import {DealCellFactory} from "../../src/kernel/factories/DealCellFactory.sol";
import {ModuleRegistryFactory} from "../../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../../src/kernel/factories/AssetControllerFactory.sol";
import {ExistingTokenAssetControllerFactory} from "../../src/kernel/factories/ExistingTokenAssetControllerFactory.sol";
import {WrappedMainTokenFactory} from "../../src/kernel/tokens/factories/WrappedMainTokenFactory.sol";
import {
    MainTokenFactory,
    AgentTokenFactory,
    StakedAgentFactory
} from "../../src/kernel/tokens/factories/TokenFactories.sol";
import {MainToken} from "../../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../../src/kernel/tokens/StakedAgent.sol";

import {CoreDealType, CoreEvaluatorType} from "../../src/modules/core/CoreModuleDeals.sol";
import {CoreModuleFactory} from "../../src/modules/core/CoreModuleFactory.sol";
import {DACDealFactory} from "../../src/modules/core/deals/factories/DACDealFactory.sol";
import {AgentDealFactory} from "../../src/modules/core/deals/factories/AgentDealFactory.sol";
import {TreasuryDealFactory} from "../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {TreasuryDeal} from "../../src/modules/core/deals/TreasuryDeal.sol";
import {DACDeal} from "../../src/modules/core/deals/DACDeal.sol";
import {MilestoneEvaluatorFactory} from "../../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {
    CoreManagementProposalFactory
} from "../../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import {CoreDealManagementType} from "../../src/modules/core/governance/CoreDealManagementProposals.sol";

import {
    MockEvaluator,
    MockEvaluatorFactory,
    MockEvaluatorModuleFactory,
    MOCK_EVALUATOR_SELECTOR
} from "../DealEvaluationRecoveryTest.t.sol";

import {InvToken, InvPermit2, InvOracle} from "./InvMocks.sol";

/// Shared state, system deployment, ghost bookkeeping and governance fast paths
/// for the native-DAC invariant handler.
abstract contract NativeBase is Test {
    // Expiry given to every governance capital call: beyond any time a campaign reaches,
    // so the model of open calls is unaffected.
    uint256 internal constant CALL_EXPIRY = type(uint64).max;

    // ------------------------------------------------------------------ //
    // System under test                                                    //
    // ------------------------------------------------------------------ //
    DACFactory public dacFactory;
    CoreModuleFactory public coreModule;
    CoreManagementProposalFactory public coreDealGov;
    MockEvaluatorModuleFactory public mockModule;

    DACCell public dac;
    MainToken public mainToken;
    AgentToken public agentToken;
    DealManager public dealManager;
    address public controller;

    InvToken public usdc;
    InvToken public tok2;
    InvPermit2 public permit2;
    InvOracle public oracle;

    address public founder = makeAddr("founder");
    address public moduleOwner = makeAddr("module-owner");
    address[] public actors;
    address[] public sinks;

    // Every protocol address that can hold tokens at rest or in transit.
    address[] public perimeter;
    mapping(address => bool) public inPerimeter;

    // Controlled addresses known to the harness (for the votable-supply invariant).
    address[] public controlledList;

    // ------------------------------------------------------------------ //
    // Deals                                                                //
    // ------------------------------------------------------------------ //
    uint8 internal constant KIND_TREASURY = 0;
    uint8 internal constant KIND_DAC = 1;
    uint8 internal constant EVAL_MOCK = 0;
    uint8 internal constant EVAL_MILESTONE = 1;
    uint8 internal constant EVAL_REVENUE = 2;

    struct DealInfo {
        uint256 id;
        address cell;
        address deal;
        address evaluator;
        uint256 approvePid;
        uint8 kind;
        uint8 evalKind;
        address treasury; // Permit2Treasury (treasury deals)
        address childDac; // DAC deals
        address childMain;
        address childController;
        address stake;
        uint256 unbacked; // liquidator stake minted without agent-token backing
        bool everApproved;
        bool everClosed;
    }

    DealInfo[] internal _deals;
    mapping(uint256 => uint256) internal _dealIdxPlus1; // dealId => idx + 1
    mapping(uint256 => address[]) internal _stakers; // idx => everyone that ever held stake
    mapping(uint256 => mapping(address => bool)) internal _isStaker;
    mapping(uint256 => mapping(address => uint256)) public ghostInvested; // idx => token => settled tranche sum
    mapping(uint256 => uint256) public dealPropHigh; // idx => highest known deal proposal id
    mapping(uint256 => mapping(uint256 => uint256)) public dealPropExecCount; // idx => pid => executions
    mapping(uint256 => uint256) public ghostReleasedAtClose; // idx => obligations released when closed
    mapping(uint256 => address[]) internal _mockEvaluators; // idx => mock evaluators (id aligned when possible)

    // Spend rights granted by deal governance (agent allowances, Permit2 approvals).
    struct Grant {
        uint256 di;
        address who;
        address token;
        address counterparty;
    }

    Grant[] internal _spendGrants;
    Grant[] internal _permitGrants;

    // ------------------------------------------------------------------ //
    // DAC proposals / capital calls / dividends                            //
    // ------------------------------------------------------------------ //
    uint256 public dacPidHigh;
    mapping(uint256 => uint256) public dacExecCount;

    struct CallInfo {
        CapitalCall call;
        bool fulfilled;
    }

    CallInfo[] internal _calls;

    struct Payout {
        uint256 pid;
        address token;
        uint256 total;
        bytes32 root;
        bool active;
        bool exactSum;
        uint256 claimed;
        address[4] receivers;
        uint256[4] amounts;
        bool[4] leafClaimed;
        uint256 swept; // unclaimed remainder released after the claim window
    }

    Payout[] internal _payouts;
    mapping(uint256 => uint256) internal _payoutIdxPlus1; // dac pid => idx + 1

    // ------------------------------------------------------------------ //
    // Ghost accounting                                                     //
    // ------------------------------------------------------------------ //
    mapping(address => uint256) public ghostIn; // token => entered the protocol perimeter
    mapping(address => uint256) public ghostOut; // token => left through governed exits
    mapping(address => int256) public ghostTreasuryCredits; // token => controller credits not explained by deals
    mapping(address => uint256) public ghostDividendsClaimed;
    mapping(address => uint256) public ghostDividendsCommitted; // token => sum(total) of active payouts
    mapping(address => uint256) public ghostDividendsSwept; // token => unclaimed remainders released after their window
    uint256 public lockReverts; // moves refused because the votes behind them are locked

    uint256 public ghostMainMintedByCalls;
    uint256 public ghostMainTreasuryMinted;
    uint256 public ghostMainBurned;

    // ------------------------------------------------------------------ //
    // Call statistics                                                      //
    // ------------------------------------------------------------------ //
    struct Stat {
        uint256 calls;
        uint256 ok;
        uint256 skipped;
        uint256 reverted;
    }

    bytes32[] public statNames;
    mapping(bytes32 => Stat) public stats;
    mapping(bytes32 => bool) internal _statKnown;

    bytes32[] public revertKeys;
    mapping(bytes32 => uint256) public revertCount;
    mapping(bytes32 => bytes32) public revertKeyName;
    mapping(bytes32 => bytes4) public revertKeySel;

    uint256 public panicCount;
    bytes32 public lastPanicHandler;
    uint256 public lastPanicCode;

    // Liveness expectations broken during the run (a call that must succeed reverted).
    uint256 public strictFailures;
    bytes32 public lastStrictHandler;
    bytes4 public lastStrictSelector;
    bytes public lastStrictData;

    // Soundness expectations broken during the run (a call that must fail succeeded).
    uint256 public soundnessFailures;
    bytes32 public lastSoundnessTag;

    // Balances of every tracked account at the start of the current handler call,
    // and the accounts that call is allowed to debit.
    mapping(address => mapping(address => uint256)) internal _balSnap; // account => token => balance
    address[] internal _allowedLosers;
    bytes32 public currentHandler;

    // Tokens pushed into protocol addresses outside protocol flows (donations, spends to self).
    mapping(address => mapping(address => uint256)) public donatedTo; // target => token => amount

    modifier onlySelf() {
        require(msg.sender == address(this), "handler-internal");
        _;
    }

    // ------------------------------------------------------------------ //
    // Statistics helpers                                                   //
    // ------------------------------------------------------------------ //
    function _begin(bytes32 name) internal {
        if (!_statKnown[name]) {
            _statKnown[name] = true;
            statNames.push(name);
        }
        stats[name].calls += 1;
        currentHandler = name;
        _snapBalances();
    }

    function _trackedTokens() internal view returns (address[4] memory t) {
        t = [address(mainToken), address(agentToken), address(usdc), address(tok2)];
    }

    function _snapBalances() internal {
        delete _allowedLosers;
        address[4] memory t = _trackedTokens();
        for (uint256 a = 0; a <= actors.length; a++) {
            address who = a == actors.length ? founder : actors[a];
            for (uint256 i = 0; i < 4; i++) {
                _balSnap[who][t[i]] = IERC20(t[i]).balanceOf(who);
            }
        }
    }

    function _allowLoss(address who) internal {
        _allowedLosers.push(who);
    }

    /// True when the last handler call reduced a balance of an account that was
    /// not a declared participant of that call.
    function bystanderLoss()
        external
        view
        returns (bool lost, address who, address token, uint256 beforeBal, uint256 afterBal)
    {
        address[4] memory t = _trackedTokens();
        for (uint256 a = 0; a <= actors.length; a++) {
            who = a == actors.length ? founder : actors[a];
            bool allowed;
            for (uint256 k = 0; k < _allowedLosers.length; k++) {
                if (_allowedLosers[k] == who) allowed = true;
            }
            if (allowed) continue;
            for (uint256 i = 0; i < 4; i++) {
                afterBal = IERC20(t[i]).balanceOf(who);
                beforeBal = _balSnap[who][t[i]];
                if (afterBal < beforeBal) return (true, who, t[i], beforeBal, afterBal);
            }
        }
        return (false, address(0), address(0), 0, 0);
    }

    function _skip(bytes32 name) internal {
        stats[name].skipped += 1;
    }

    function _ok(bytes32 name) internal {
        stats[name].ok += 1;
    }

    function _selectorOf(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length >= 4) {
            assembly {
                sel := mload(add(err, 0x20))
            }
        }
    }

    function _fail(bytes32 name, bytes memory err) internal returns (bytes4 sel) {
        stats[name].reverted += 1;
        sel = _selectorOf(err);

        bytes32 key = keccak256(abi.encode(name, sel));
        if (revertCount[key] == 0) {
            revertKeys.push(key);
            revertKeyName[key] = name;
            revertKeySel[key] = sel;
        }
        revertCount[key] += 1;

        // Panic(uint256)
        if (sel == 0x4e487b71 && err.length >= 36) {
            uint256 code;
            assembly {
                code := mload(add(err, 0x24))
            }
            panicCount += 1;
            lastPanicHandler = name;
            lastPanicCode = code;
        }
    }

    function _strict(bytes32 name, bytes memory err) internal {
        // A move that would take locked votes away from their delegate is refused by
        // design (creator holds, challenge holds): not a liveness failure.
        if (_selectorOf(err) == DACErrorsLib.VotesLocked.selector) {
            lockReverts += 1;
            return;
        }
        strictFailures += 1;
        lastStrictHandler = name;
        lastStrictSelector = _selectorOf(err);
        lastStrictData = err;
    }

    function statCount() external view returns (uint256) {
        return statNames.length;
    }

    function revertKeyCount() external view returns (uint256) {
        return revertKeys.length;
    }

    // ------------------------------------------------------------------ //
    // Views for the invariant contract                                     //
    // ------------------------------------------------------------------ //
    function dealCount() external view returns (uint256) {
        return _deals.length;
    }

    function dealInfo(uint256 i) external view returns (DealInfo memory) {
        return _deals[i];
    }

    function stakersOf(uint256 i) external view returns (address[] memory) {
        return _stakers[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function perimeterCount() external view returns (uint256) {
        return perimeter.length;
    }

    function controlledCount() external view returns (uint256) {
        return controlledList.length;
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callInfo(uint256 i) external view returns (CallInfo memory) {
        return _calls[i];
    }

    function payoutCount() external view returns (uint256) {
        return _payouts.length;
    }

    function payoutInfo(uint256 i) external view returns (Payout memory) {
        return _payouts[i];
    }

    // ------------------------------------------------------------------ //
    // Raw storage readers (private accounting of the native controller)    //
    // ------------------------------------------------------------------ //
    function ctrlTreasury(address token) public view returns (uint256) {
        return uint256(vm.load(controller, keccak256(abi.encode(token, uint256(5)))));
    }

    function ctrlCommitted(address token) public view returns (uint256) {
        return uint256(vm.load(controller, keccak256(abi.encode(token, uint256(6)))));
    }

    function ctrlObligations() public view returns (uint256) {
        return uint256(vm.load(controller, bytes32(uint256(9))));
    }

    function ctrlUnreleased() public view returns (uint256) {
        return uint256(vm.load(controller, bytes32(uint256(10))));
    }

    function ctrlLocked(address a) public view returns (uint256) {
        return uint256(vm.load(controller, keccak256(abi.encode(a, uint256(11)))));
    }

    function cellClaimable(address cell, address who) public view returns (uint256) {
        return uint256(vm.load(cell, keccak256(abi.encode(who, uint256(28)))));
    }

    function ctrlFree(address token) public view returns (uint256) {
        uint256 t = ctrlTreasury(token);
        uint256 c = ctrlCommitted(token);
        return t >= c ? t - c : 0;
    }

    // ------------------------------------------------------------------ //
    // Small selectors                                                      //
    // ------------------------------------------------------------------ //
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _holder(uint256 seed) internal view returns (address) {
        uint256 k = seed % (actors.length + 1);
        return k == actors.length ? founder : actors[k];
    }

    function _cash(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? address(usdc) : address(tok2);
    }

    function _token3(uint256 seed) internal view returns (address) {
        uint256 k = seed % 3;
        if (k == 0) return address(usdc);
        if (k == 1) return address(tok2);
        return address(mainToken);
    }

    function _addPerimeter(address a) internal {
        if (a == address(0) || inPerimeter[a]) return;
        inPerimeter[a] = true;
        perimeter.push(a);
    }

    function _addStaker(uint256 di, address who) internal {
        if (_isStaker[di][who]) return;
        _isStaker[di][who] = true;
        _stakers[di].push(who);
    }

    function _state(uint256 di) internal returns (DealState memory) {
        return IDealManagerAdapter(address(dealManager)).state(_deals[di].cell);
    }

    // First staker (starting at seed) holding a live stake with voting weight.
    function _liveStaker(uint256 di, uint256 seed) internal view returns (address) {
        address[] storage s = _stakers[di];
        uint256 n = s.length;
        if (n == 0) return address(0);
        StakedAgent st = StakedAgent(_deals[di].stake);
        for (uint256 k = 0; k < n; k++) {
            address a = s[(seed % n + k) % n];
            if (st.balanceOf(a) > 0 && st.getVotes(a) > 0) return a;
        }
        return address(0);
    }

    // filter: 0 any, 1 not approved, 2 approved & open, 3 closed, 4 approved (open or closed)
    function _pickDeal(uint256 seed, uint8 filter) internal view returns (bool found, uint256 idx) {
        uint256 n = _deals.length;
        if (n == 0) return (false, 0);
        for (uint256 k = 0; k < n; k++) {
            idx = (seed % n + k) % n;
            IDealCell c = IDealCell(_deals[idx].cell);
            bool approved = c.isApproved();
            bool closed = c.isClosed();
            if (filter == 0) return (true, idx);
            if (filter == 1 && !approved) return (true, idx);
            if (filter == 2 && approved && !closed) return (true, idx);
            if (filter == 3 && closed) return (true, idx);
            if (filter == 4 && approved) return (true, idx);
        }
        return (false, 0);
    }

    function _pickDealKind(uint256 seed, uint8 filter, uint8 kind) internal view returns (bool found, uint256 idx) {
        uint256 n = _deals.length;
        for (uint256 k = 0; k < n; k++) {
            idx = (seed % n + k) % n;
            if (_deals[idx].kind != kind) continue;
            IDealCell c = IDealCell(_deals[idx].cell);
            bool approved = c.isApproved();
            bool closed = c.isClosed();
            if (filter == 0) return (true, idx);
            if (filter == 1 && !approved) return (true, idx);
            if (filter == 2 && approved && !closed) return (true, idx);
            if (filter == 3 && closed) return (true, idx);
            if (filter == 4 && approved) return (true, idx);
        }
        return (false, 0);
    }

    // ------------------------------------------------------------------ //
    // DAC governance fast path                                             //
    // ------------------------------------------------------------------ //
    function _syncDacPids() internal {
        while (dac.getProposalVoting(dacPidHigh + 1) != address(0)) {
            dacPidHigh += 1;
        }
    }

    function _tryVoteDac(address prop, address voter, uint256 snap, bool support) internal returns (bool executable) {
        if (Proposal(prop).voted(voter)) return false;
        if (mainToken.getPastVotes(voter, snap) == 0) return false;
        vm.prank(voter);
        IVoting(prop).vote(support);
        return IExecutableProposal(prop).isExecutableNow();
    }

    function _voteDacAll(address prop) internal {
        uint256 snap = Proposal(prop).snapshotTime();
        // voting opens the second after creation; the snapshot is the second before it
        if (block.timestamp <= snap + 1) vm.warp(snap + 2);
        if (block.timestamp > Proposal(prop).endTime()) return;
        if (IExecutableProposal(prop).isExecutableNow()) return;
        if (_tryVoteDac(prop, founder, snap, true)) return;
        for (uint256 i = 0; i < actors.length; i++) {
            if (_tryVoteDac(prop, actors[i], snap, true)) return;
        }
    }

    function _execDac(uint256 pid) internal {
        address prop = dac.getProposalVoting(pid);
        if (!IExecutableProposal(prop).isExecutableNow()) {
            uint256 endTime = Proposal(prop).endTime();
            if (block.timestamp <= endTime) vm.warp(endTime + 1);
        }
        _execDacNow(pid);
    }

    struct PreExec {
        uint256 treasuryBefore;
        uint256 obligationsBefore;
    }

    function _execDacNow(uint256 pid) internal {
        address prop = dac.getProposalVoting(pid);
        bytes4 typ = Proposal(prop).typ();
        dac.executeDACProposal(pid);
        dacExecCount[pid] += 1;
        _postDacExec(pid, prop, typ);
        _syncDacPids();
    }

    function _passDac(ProposalParams memory p, address creator) internal returns (uint256 pid) {
        vm.prank(creator);
        pid = dac.createManagementProposal(p);
        _syncDacPids();
        _voteDacAll(dac.getProposalVoting(pid));
        _execDac(pid);
    }

    function _postDacExec(uint256 pid, address prop, bytes4 typ) internal {
        if (typ == DACManagementProposalType.CAPITAL_CALL) {
            (address treasuryToken, uint256 cashAmount,) =
                abi.decode(Proposal(prop).data(), (address, uint256, uint256));
            _calls.push(
                CallInfo({
                    call: CapitalCall({
                        treasuryToken: treasuryToken,
                        nonce: pid,
                        tokenRecipient: Proposal(prop).target(),
                        tokenAmount: uint256(Proposal(prop).i()),
                        cashAmount: cashAmount
                    }),
                    fulfilled: false
                })
            );
        } else if (typ == DACManagementProposalType.MINT_MAIN_TOKENS) {
            uint256 amount = uint256(Proposal(prop).i());
            ghostMainTreasuryMinted += amount;
            ghostTreasuryCredits[address(mainToken)] += int256(amount);
        } else if (typ == DACManagementProposalType.BURN_MAIN_TOKENS) {
            uint256 amount = uint256(Proposal(prop).i());
            ghostMainBurned += amount;
            ghostTreasuryCredits[address(mainToken)] -= int256(amount);
        } else if (typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
            uint256 pi = _payoutIdxPlus1[pid];
            if (pi != 0) {
                Payout storage po = _payouts[pi - 1];
                po.active = true;
                ghostDividendsCommitted[po.token] += po.total;
            }
        } else if (typ == DACManagementProposalType.APPROVE_DEAL || typ == DACManagementProposalType.APPROVE_TRANCHE) {
            (uint256 dealId, uint256 trancheId,) = abi.decode(Proposal(prop).data(), (uint256, uint256, uint256));
            uint256 dip = _dealIdxPlus1[dealId];
            if (dip != 0) {
                uint256 di = dip - 1;
                Tranche memory t = IDealCell(_deals[di].cell).fundingTranche(trancheId);
                if (t.amount > 0) ghostInvested[di][t.token] += t.amount;
                _deals[di].everApproved = true;
            }
        } else if (typ == DACManagementProposalType.RECOVER_DEAL) {
            (uint256 dealId) = abi.decode(Proposal(prop).data(), (uint256));
            uint256 dip = _dealIdxPlus1[dealId];
            if (dip != 0) {
                uint256 di = dip - 1;
                _deals[di].unbacked += uint256(Proposal(prop).i());
                _addStaker(di, Proposal(prop).target());
            }
        } else if (typ == DACManagementProposalType.ADD_EVALUATOR) {
            (uint256 dealId,,) = abi.decode(Proposal(prop).data(), (uint256, address, bytes));
            uint256 dip = _dealIdxPlus1[dealId];
            if (dip != 0) _syncDealProps(dip - 1);
        } else if (typ == DACManagementProposalType.REVOKE_AGENT_TOKENS) {
            _allowLoss(Proposal(prop).target());
        }
    }

    // ------------------------------------------------------------------ //
    // Deal governance fast path                                            //
    // ------------------------------------------------------------------ //
    function _syncDealProps(uint256 di) internal {
        Deal d = Deal(_deals[di].deal);
        for (uint256 guard = 0; guard < 64; guard++) {
            try d.getProposal(dealPropHigh[di] + 1) returns (address) {
                dealPropHigh[di] += 1;
            } catch {
                break;
            }
        }
    }

    function _tryVoteDeal(uint256 di, address prop, address voter, uint256 snap, bool support)
        internal
        returns (bool executable)
    {
        if (Proposal(prop).voted(voter)) return false;
        if (StakedAgent(_deals[di].stake).getPastVotes(voter, snap) == 0) return false;
        vm.prank(voter);
        IVoting(prop).vote(support);
        return IExecutableProposal(prop).isExecutableNow();
    }

    function _voteDealAll(uint256 di, address prop) internal {
        uint256 snap = Proposal(prop).snapshotTime();
        // voting opens the second after creation; the snapshot is the second before it
        if (block.timestamp <= snap + 1) vm.warp(snap + 2);
        if (block.timestamp > Proposal(prop).endTime()) return;
        if (IExecutableProposal(prop).isExecutableNow()) return;
        address[] storage s = _stakers[di];
        for (uint256 i = 0; i < s.length; i++) {
            if (_tryVoteDeal(di, prop, s[i], snap, true)) return;
        }
    }

    function _execDeal(uint256 di, uint256 pid) internal {
        address prop = Deal(_deals[di].deal).getProposal(pid);
        if (!IExecutableProposal(prop).isExecutableNow()) {
            uint256 endTime = Proposal(prop).endTime();
            if (block.timestamp <= endTime) vm.warp(endTime + 1);
        }
        _execDealNow(di, pid);
    }

    function _execDealNow(uint256 di, uint256 pid) internal {
        address prop = Deal(_deals[di].deal).getProposal(pid);
        bytes4 typ = Proposal(prop).typ();
        Deal(_deals[di].deal).executeStakedAgentProposal(pid);
        dealPropExecCount[di][pid] += 1;
        _postDealExec(di, prop, typ);
        _syncDealProps(di);
        _syncDacPids();
        _noteClosed(di);
    }

    function _passDeal(uint256 di, address proposer, ProposalParams memory p) internal returns (uint256 pid) {
        vm.prank(proposer);
        pid = Deal(_deals[di].deal).createStakedAgentProposal(p);
        _syncDealProps(di);
        _voteDealAll(di, Deal(_deals[di].deal).getProposal(pid));
        _execDeal(di, pid);
    }

    function _postDealExec(uint256 di, address prop, bytes4 typ) internal {
        if (typ == CoreDealManagementType.APPROVE_DIRECT_SPEND) {
            (address spender, uint160 amount) = abi.decode(Proposal(prop).data(), (address, uint160));
            if (!inPerimeter[spender]) ghostOut[Proposal(prop).target()] += amount;
            else donatedTo[spender][Proposal(prop).target()] += amount;
        } else if (typ == AbstractDealManagementType.ADD_STAKE) {
            _addStaker(di, Proposal(prop).target());
            _allowLoss(Proposal(prop).target());
        } else if (typ == CoreDealManagementType.APPROVE_AGENT_SPEND) {
            (address agent, address dest) = abi.decode(Proposal(prop).data(), (address, address));
            _spendGrants.push(Grant({di: di, who: agent, token: Proposal(prop).target(), counterparty: dest}));
        } else if (typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND) {
            (address spender) = abi.decode(Proposal(prop).data(), (address));
            _permitGrants.push(Grant({di: di, who: spender, token: Proposal(prop).target(), counterparty: address(0)}));
        }
    }

    // Records the first observation of a closed deal (monotonicity is asserted by the invariants).
    function _noteClosed(uint256 di) internal {
        if (!_deals[di].everClosed && IDealCell(_deals[di].cell).isClosed()) {
            _deals[di].everClosed = true;
        }
    }

    function _noteAllClosed() internal {
        for (uint256 i = 0; i < _deals.length; i++) {
            _noteClosed(i);
        }
    }

    // ------------------------------------------------------------------ //
    // Merkle helpers (4 leaves, OZ commutative hashing)                    //
    // ------------------------------------------------------------------ //
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _leaf(uint256 index, address receiver, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(index, receiver, amount));
    }

    function _root(address[4] memory r, uint256[4] memory a) internal pure returns (bytes32) {
        return _hashPair(
            _hashPair(_leaf(0, r[0], a[0]), _leaf(1, r[1], a[1])), _hashPair(_leaf(2, r[2], a[2]), _leaf(3, r[3], a[3]))
        );
    }

    function _proof(address[4] memory r, uint256[4] memory a, uint256 index)
        internal
        pure
        returns (bytes32[] memory p)
    {
        p = new bytes32[](2);
        bytes32 l0 = _leaf(0, r[0], a[0]);
        bytes32 l1 = _leaf(1, r[1], a[1]);
        bytes32 l2 = _leaf(2, r[2], a[2]);
        bytes32 l3 = _leaf(3, r[3], a[3]);
        if (index == 0) {
            p[0] = l1;
            p[1] = _hashPair(l2, l3);
        } else if (index == 1) {
            p[0] = l0;
            p[1] = _hashPair(l2, l3);
        } else if (index == 2) {
            p[0] = l3;
            p[1] = _hashPair(l0, l1);
        } else {
            p[0] = l2;
            p[1] = _hashPair(l0, l1);
        }
    }
}
