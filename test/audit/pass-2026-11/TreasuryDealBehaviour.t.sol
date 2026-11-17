// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). TreasuryDeal and Permit2Treasury against the real Permit2 runtime.
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.
//   test_NOTE_*    intended behaviour that audit.md documents as an operating note.
//   test_VERIFY_*  a property checked against the canonical Permit2 bytecode.

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {DealParams, ProposalParams} from "../../../src/interfaces/Structs.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {Deal} from "../../../src/kernel/Deal.sol";
import {DealCell} from "../../../src/kernel/DealCell.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {StakedAgent} from "../../../src/kernel/tokens/StakedAgent.sol";
import {AbstractDealManagementType} from "../../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {CoreDealManagementType} from "../../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {TreasuryDeal} from "../../../src/modules/core/deals/TreasuryDeal.sol";
import {Permit2Treasury} from "../../../src/modules/core/deals/Permit2Treasury.sol";
import {CoreDealType, CoreEvaluatorType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {MilestoneBasedEvaluator} from "../../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {Milestone, TreasurySpendAllowance} from "../../../src/modules/core/interfaces/Structs.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {IPermit2} from "../../../src/lib/IPermit2.sol";
import {Permit2Runtime} from "./Permit2Runtime.sol";

interface IRealPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
    function transferFrom(address from, address to, uint160 amount, address token) external;
    function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external;
    function permitTransferFrom(
        IPermit2.PermitTransferFrom memory permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

/// Token whose owner can switch transfers off (stand-in for an attacker token, or
/// for a blacklist / pause on a real one).
contract SwitchableToken is ERC20 {
    address public owner;
    bool public blocked;

    constructor() ERC20("Switchable", "SWT") {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(bool value) external {
        require(msg.sender == owner, "owner");
        blocked = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked, "blocked");
        super._update(from, to, value);
    }
}

/// Token whose owner can make every transfer burn all the gas it is given.
contract GasBurnerToken is ERC20 {
    address public owner;
    bool public burning;

    constructor() ERC20("Burner", "BRN") {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurning(bool value) external {
        require(msg.sender == owner, "owner");
        burning = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (burning) {
            while (true) {}
        }
        super._update(from, to, value);
    }
}

/// Allowances are 96 bits wide, as in UNI and COMP style tokens: `approve` accepts a
/// value that fits, or exactly 2^256 - 1 as shorthand for the maximum.
contract NarrowAllowanceToken {
    mapping(address => mapping(address => uint96)) internal allowances;

    function approve(address spender, uint256 rawAmount) external returns (bool) {
        uint96 amount;
        if (rawAmount == type(uint256).max) {
            amount = type(uint96).max;
        } else {
            require(rawAmount <= type(uint96).max, "amount exceeds 96 bits");
            // forge-lint: disable-next-line(unsafe-typecast)
            amount = uint96(rawAmount);
        }
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address account, address spender) external view returns (uint256) {
        return allowances[account][spender];
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract TreasuryDealBehaviour is DACTestBase {
    address internal agent1 = makeAddr("agent1");
    address internal router = makeAddr("router");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant CAPITAL_RETURN_FAILED = keccak256("CapitalReturnFailed(address,uint256,address,address)");

    function setUp() public {
        setUpBase();
        // Real Uniswap Permit2 runtime (allowance expiry, nonces, ERC-1271 checks).
        vm.etch(permit2, Permit2Runtime.CODE);
        onboardAgent(agent1);
    }

    /*//////////////////////////////////////////////////////////////
        M-05 (operating note): what a deal granted stays granted
    //////////////////////////////////////////////////////////////*/

    // A healthy deal sets up ordinary operating permissions, then misses its milestone:
    // one agent-spend allowance, one Permit2 allowance, and a direct-spend proposal that
    // is still open when the slash lands. Returns the deal, its treasury and that proposal.
    function _slashedDealWithStandingRights()
        internal
        returns (DealHandle memory h, address treasury, uint256 inFlight)
    {
        h = _createSlashableTreasuryDeal(agent1);
        uint256 t0 = block.timestamp;

        vm.warp(block.timestamp + 1);
        _stake(agent1, h.dealCell, 20_000);
        _approveDeal(h);
        vm.warp(block.timestamp + 1);

        treasury = TreasuryDeal(h.dealAddr).managedEntity();
        assertEq(usdc.balanceOf(treasury), 10_000);

        _passDealProposal(
            h,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_AGENT_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(
                    agent1,
                    address(0),
                    TreasurySpendAllowance({totalAmount: 4_000, singleTxAmount: 4_000, clockLimit: 0, duration: 0})
                )
            })
        );
        _passDealProposal(
            h,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(router, uint160(3_000), uint48(block.timestamp + 60 days))
            })
        );

        // The milestone is missed. Just before anyone evaluates, the agent opens a
        // direct-spend proposal and leaves it unvoted.
        vm.warp(t0 + 2 days + 10);
        vm.prank(agent1);
        inFlight = Deal(h.dealAddr)
            .createStakedAgentProposal(
                ProposalParams({
                    typ: CoreDealManagementType.APPROVE_DIRECT_SPEND,
                    target: address(usdc),
                    i: 0,
                    data: abi.encode(agent1, uint160(3_000))
                })
            );

        vm.warp(block.timestamp + 1);

        // A holder evaluates: 100% slash, stake supply hits zero, the deal closes.
        vm.prank(founder);
        DealManager(dealManager).evaluateDeal(h.dealId, 0);

        StakedAgent stake = StakedAgent(IDealCell(h.dealCell).stakeToken());
        assertTrue(IDealCell(h.dealCell).isClosed());
        assertEq(stake.totalSupply(), 0);
    }

    /// Slashing takes the stake, not the permissions the deal already handed out. Until
    /// the capital is returned, a standing agent allowance, a standing Permit2 allowance
    /// and a proposal opened before the slash (it votes with its pre-slash snapshot) all
    /// still work.
    function test_NOTE_M05_spendRightsOutliveTheStake_untilCapitalIsReturned() public {
        (DealHandle memory h, address treasury, uint256 inFlight) = _slashedDealWithStandingRights();
        uint256 agentBefore = usdc.balanceOf(agent1);

        vm.prank(agent1);
        Permit2Treasury(treasury).executeAgentSpend(address(usdc), agent1, 4_000);

        vm.prank(router);
        IRealPermit2(permit2).transferFrom(treasury, router, 3_000, address(usdc));

        address inFlightProposal = Deal(h.dealAddr).getProposal(inFlight);
        vm.prank(agent1);
        IVoting(inFlightProposal).vote(true);
        Deal(h.dealAddr).executeStakedAgentProposal(inFlight);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(agent1), agentBefore + 7_000);
        assertEq(usdc.balanceOf(router), 3_000);
    }

    /// The DAC's answer is the capital return, which any holder can call the moment a
    /// deal is closed with no stake left: sent together with the evaluation, it leaves
    /// those permissions nothing to spend.
    function test_NOTE_M05_evaluateThenReturnCapital_leavesNothingToSpend() public {
        (DealHandle memory h, address treasury, uint256 inFlight) = _slashedDealWithStandingRights();
        uint256 controllerBefore = usdc.balanceOf(dac.getAssetController());

        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(h.dealId);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(dac.getAssetController()), controllerBefore + 10_000);

        vm.prank(agent1);
        vm.expectRevert();
        Permit2Treasury(treasury).executeAgentSpend(address(usdc), agent1, 4_000);

        vm.prank(router);
        vm.expectRevert();
        IRealPermit2(permit2).transferFrom(treasury, router, 3_000, address(usdc));

        address inFlightProposal = Deal(h.dealAddr).getProposal(inFlight);
        vm.prank(agent1);
        IVoting(inFlightProposal).vote(true);
        vm.expectRevert();
        Deal(h.dealAddr).executeStakedAgentProposal(inFlight);
    }

    /*//////////////////////////////////////////////////////////////
        M-08: funding tokens are returned one by one
    //////////////////////////////////////////////////////////////*/

    // A live treasury deal funded with 10_000 USDC plus a 1-wei tranche of `token`.
    function _dealWithSecondFundingToken(address token) internal returns (DealHandle memory h, address treasury) {
        h = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stake(agent1, h.dealCell, 20_000);
        _approveDeal(h);
        vm.warp(block.timestamp + 1);

        treasury = TreasuryDeal(h.dealAddr).managedEntity();
        assertEq(usdc.balanceOf(treasury), 10_000);

        // Anyone can put a token on the DAC's books: donate + permissionless recoverERC20.
        dac.recoverERC20(token);

        // The deal asks for a 1-wei tranche in that token ...
        vm.prank(agent1);
        uint256 trancheId = Deal(h.dealAddr)
            .createStakedAgentProposal(
                ProposalParams({
                    typ: AbstractDealManagementType.REQUEST_TRANCHE,
                    target: token,
                    i: bytes32(uint256(1)),
                    data: abi.encode(uint256(0))
                })
            );
        vm.warp(block.timestamp + 1);
        address trancheProposal = Deal(h.dealAddr).getProposal(trancheId);
        vm.prank(agent1);
        IVoting(trancheProposal).vote(true);

        vm.recordLogs();
        Deal(h.dealAddr).executeStakedAgentProposal(trancheId);
        uint256 dacProposalId =
            _topic3(vm.getRecordedLogs(), keccak256("TrancheCreated(address,uint256,uint256,uint256)"));

        // ... and the DAC approves it.
        vm.warp(block.timestamp + 1);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(dacProposalId)).vote(true);
        dac.executeDACProposal(dacProposalId);
        vm.stopPrank();

        assertEq(IDealCell(h.dealCell).fundingTokens().length, 2);
    }

    function _failedReturns(Vm.Log[] memory logs, address token) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CAPITAL_RETURN_FAILED && abi.decode(logs[i].data, (address)) == token) {
                count++;
            }
        }
    }

    /// One funding token whose transfers revert (frozen, paused, hostile) no longer holds
    /// the others: they return, the stuck one is reported and can be retried later.
    function test_REG_M08_stuckFundingToken_doesNotHoldTheOthers() public {
        vm.startPrank(attacker);
        SwitchableToken swt = new SwitchableToken();
        swt.mint(address(dac), 1);
        vm.stopPrank();

        (DealHandle memory h, address treasury) = _dealWithSecondFundingToken(address(swt));
        uint256 controllerBefore = usdc.balanceOf(dac.getAssetController());

        vm.prank(attacker);
        swt.setBlocked(true);

        vm.warp(IDealCell(h.dealCell).dealDeadline() + 1);

        vm.recordLogs();
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(h.dealId);

        assertEq(usdc.balanceOf(treasury), 0, "USDC left the deal");
        assertEq(usdc.balanceOf(dac.getAssetController()), controllerBefore + 10_000, "and is back in the DAC treasury");
        assertEq(_failedReturns(vm.getRecordedLogs(), address(swt)), 1, "the stuck token is reported");
        assertEq(swt.balanceOf(treasury), 1);

        // Once the token moves again, the same call brings it home.
        vm.prank(attacker);
        swt.setBlocked(false);
        vm.prank(founder);
        DealManager(dealManager).forceReturnCapital(h.dealId);
        assertEq(swt.balanceOf(treasury), 0);
        assertEq(swt.balanceOf(dac.getAssetController()), 1);
    }

    /// A funding token that burns every unit of gas it is given costs its own stipend and
    /// nothing else: the return of the other tokens stays far inside a transaction.
    function test_REG_M08_gasBurningFundingToken_costsOnlyItsOwnStipend() public {
        vm.startPrank(attacker);
        GasBurnerToken brn = new GasBurnerToken();
        brn.mint(address(dac), 1);
        vm.stopPrank();

        (DealHandle memory h, address treasury) = _dealWithSecondFundingToken(address(brn));
        uint256 controllerBefore = usdc.balanceOf(dac.getAssetController());

        vm.prank(attacker);
        brn.setBurning(true);

        vm.warp(IDealCell(h.dealCell).dealDeadline() + 1);

        vm.recordLogs();
        vm.prank(founder);
        uint256 g = gasleft();
        DealManager(dealManager).forceReturnCapital(h.dealId);
        uint256 used = g - gasleft();
        emit log_named_uint("capital return with one gas-burning funding token, gas", used);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(dac.getAssetController()), controllerBefore + 10_000);
        assertGe(_failedReturns(vm.getRecordedLogs(), address(brn)), 1);
        assertLt(used, 2_800_000, "bounded by the per-token stipends");
    }

    /// The caller cannot make a token's turn fail by sending too little gas: the
    /// stipend is guaranteed or the whole call reverts.
    function test_REG_M08_callerCannotStarveATokensTurn() public {
        vm.startPrank(attacker);
        SwitchableToken swt = new SwitchableToken();
        swt.mint(address(dac), 1);
        vm.stopPrank();

        (DealHandle memory h, address treasury) = _dealWithSecondFundingToken(address(swt));
        vm.warp(IDealCell(h.dealCell).dealDeadline() + 1);

        vm.prank(founder);
        try DealManager(dealManager).forceReturnCapital{gas: 600_000}(h.dealId) {
            revert("went through with less than one stipend");
        } catch {}

        assertEq(usdc.balanceOf(treasury), 10_000, "nothing moved, nothing skipped");
    }

    /*//////////////////////////////////////////////////////////////
        L-06: Permit2 approval for tokens with narrow allowances
    //////////////////////////////////////////////////////////////*/

    function test_REG_L06_narrowAllowanceToken_canBeApprovedForPermit2() public {
        DealHandle memory h = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);
        _stake(agent1, h.dealCell, 20_000);
        _approveDeal(h);
        vm.warp(block.timestamp + 1);

        address treasury = TreasuryDeal(h.dealAddr).managedEntity();
        NarrowAllowanceToken uni = new NarrowAllowanceToken();

        _passDealProposal(
            h,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
                target: address(uni),
                i: 0,
                data: abi.encode(router, uint160(3_000), uint48(block.timestamp + 60 days))
            })
        );

        assertEq(uni.allowance(treasury, permit2), type(uint96).max);
        (uint160 amount,,) = IRealPermit2(permit2).allowance(treasury, address(uni), router);
        assertEq(amount, 3_000);
    }

    /*//////////////////////////////////////////////////////////////
        real Permit2: revocation and signature paths
    //////////////////////////////////////////////////////////////*/

    /// Against the canonical Permit2 runtime:
    ///  - nobody can move treasury funds through a Permit2 signature (the treasury
    ///    exposes no ERC-1271, so both `permit` and `permitTransferFrom` revert);
    ///  - REVOKE_AGENT really zeroes the Permit2 allowance of the named spender.
    function test_VERIFY_realPermit2_signaturePathsClosed_revokeEffective() public {
        DealHandle memory h = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stake(agent1, h.dealCell, 20_000);
        _approveDeal(h);
        vm.warp(block.timestamp + 1);

        address treasury = TreasuryDeal(h.dealAddr).managedEntity();

        _passDealProposal(
            h,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(router, uint160(3_000), uint48(block.timestamp + 60 days))
            })
        );

        (uint160 amount,,) = IRealPermit2(permit2).allowance(treasury, address(usdc), router);
        assertEq(amount, 3_000);
        // The ERC-20 approval to Permit2 is unlimited, for good; Permit2's own allowance is the limit.
        assertEq(usdc.allowance(treasury, permit2), type(uint256).max);

        bytes memory junkSig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        // SignatureTransfer against the treasury: no ERC-1271 -> revert.
        vm.prank(attacker);
        vm.expectRevert();
        IRealPermit2(permit2)
            .permitTransferFrom(
                IPermit2.PermitTransferFrom({
                    permitted: IPermit2.TokenPermissions({token: address(usdc), amount: 10_000}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                IPermit2.SignatureTransferDetails({to: attacker, requestedAmount: 10_000}),
                treasury,
                junkSig
            );

        // AllowanceTransfer.permit against the treasury: same.
        vm.prank(attacker);
        vm.expectRevert();
        IRealPermit2(permit2)
            .permit(
                treasury,
                IRealPermit2.PermitSingle({
                    details: IRealPermit2.PermitDetails({
                        token: address(usdc),
                        amount: type(uint160).max,
                        expiration: uint48(block.timestamp + 1 days),
                        nonce: 0
                    }),
                    spender: attacker,
                    sigDeadline: block.timestamp + 1 days
                }),
                junkSig
            );

        // The approved spender works within its allowance ...
        vm.prank(router);
        IRealPermit2(permit2).transferFrom(treasury, router, 1_000, address(usdc));

        // ... until REVOKE_AGENT names it.
        _passDealProposal(
            h,
            agent1,
            ProposalParams({
                typ: CoreDealManagementType.REVOKE_AGENT,
                target: address(usdc),
                i: 0,
                data: abi.encode(router, address(0))
            })
        );

        (amount,,) = IRealPermit2(permit2).allowance(treasury, address(usdc), router);
        assertEq(amount, 0);

        vm.prank(router);
        vm.expectRevert();
        IRealPermit2(permit2).transferFrom(treasury, router, 1, address(usdc));

        assertEq(usdc.balanceOf(treasury), 9_000);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _stake(address agent, address dealCell, uint256 amount) internal {
        vm.prank(agent);
        agentToken.stakeToDeal(dealCell, amount);
    }

    function _approveDeal(DealHandle memory h) internal {
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(h.proposalId)).vote(true);
        dac.executeDACProposal(h.proposalId);
        vm.stopPrank();
    }

    function _passDealProposal(DealHandle memory h, address agent, ProposalParams memory params) internal {
        vm.prank(agent);
        uint256 pid = Deal(h.dealAddr).createStakedAgentProposal(params);
        vm.warp(block.timestamp + 1);
        address proposal = Deal(h.dealAddr).getProposal(pid);
        vm.prank(agent);
        IVoting(proposal).vote(true);
        Deal(h.dealAddr).executeStakedAgentProposal(pid);
        vm.warp(block.timestamp + 1);
    }

    function _topic3(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                return uint256(logs[i].topics[3]);
            }
        }
        revert("event not found");
    }

    /// Treasury deal whose single milestone pays nothing and slashes 100% when missed.
    function _createSlashableTreasuryDeal(address agent) internal returns (DealHandle memory handle) {
        vm.recordLogs();

        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 1 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0,
            excludePrincipal: false
        });
        milestones[0].rewardCurve[0] = 0;
        milestones[0].penaltyCurve[0] = 1e18;

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Slashable Treasury Deal",
            description: "milestone with a real penalty",
            linkHash: "0x00",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 2 days,
            dealDeadline: block.timestamp + 30 days,
            dealConfig: abi.encode("deal config"),
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            evaluatorConfig: abi.encode(MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones)),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        vm.prank(agent);
        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) =
            IDealManager(dealManager).createDealProposal(params);

        handle.dealId = dealId;
        handle.dealCell = dealCell;
        handle.dealAddr = dealAddr;
        handle.evaluatorAddr = evaluatorAddr;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }
}
