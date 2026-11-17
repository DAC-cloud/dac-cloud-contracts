// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Which addresses a deal can take out of the electorate (M-07).
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {DACCell} from "../../../src/kernel/DACCell.sol";
import {WrappedMainToken} from "../../../src/kernel/tokens/WrappedMainToken.sol";
import {AgentToken} from "../../../src/kernel/tokens/AgentToken.sol";
import {ExistingTokenAssetController} from "../../../src/kernel/controllers/ExistingTokenAssetController.sol";
import {HybridDACManagementProposal} from "../../../src/kernel/governance/HybridDACManagementProposal.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {
    ExistingDACConfig,
    ProposalParams,
    CapitalCall,
    DealParams,
    VotingConfig
} from "../../../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig, ProposalPhase} from "../../../src/interfaces/GovernanceStructs.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IExecutableProposal} from "../../../src/interfaces/IExecutableProposal.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";

contract ControlledUnderlying is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// A passive custody contract with a permissive fallback (smart wallet, vault,
/// EIP-7702 delegate target...). It never speaks the Deal interface.
contract PassiveVault {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function delegateTo(address token, address to) external {
        require(msg.sender == owner);
        WrappedMainToken(token).delegate(to);
    }
    fallback() external payable {}
    receive() external payable {}
}

/// A custody contract built to pass for a Deal: it answers `getCell()` with whatever
/// cell it is told to name.
contract CellNamingVault is PassiveVault {
    address public cell;

    constructor(address _owner) PassiveVault(_owner) {}

    function setCell(address _cell) external {
        cell = _cell;
    }

    function getCell() external view returns (address) {
        return cell;
    }
}

/// Approved-but-hostile module: its "deal" is whatever address its operator chose.
contract EvilModule {
    address public nextDeal;

    function setNextDeal(address d) external {
        nextDeal = d;
    }

    function isActive() external pure returns (bool) {
        return true;
    }

    function supportsDealRewardPool(bytes4) external pure returns (bool) {
        return false;
    }

    function dealAcceptsEvaluator(bytes4, bytes4, address) external pure returns (bool) {
        return true;
    }

    function evaluatorAcceptsDeal(bytes4, bytes4, address) external pure returns (bool) {
        return true;
    }

    function dealAcceptsGovernanceFactory(bytes4, address) external pure returns (bool) {
        return true;
    }

    function deployDeal(uint256, DealParams calldata, address, address dealCell, VotingConfig calldata)
        external
        returns (address)
    {
        // A cooperating target is told which cell to name; anything else ignores the call.
        (bool ok,) = nextDeal.call(abi.encodeWithSignature("setCell(address)", dealCell));
        ok;
        return nextDeal;
    }

    function deployEvaluator(address, uint256, address, DealParams calldata, bytes4, bytes calldata)
        external
        view
        returns (address)
    {
        return address(this);
    }
}

contract ControlledAddress is DACTestBase {
    ControlledUnderlying internal underlying;
    DACCell internal xdac;
    WrappedMainToken internal wrapped;
    AgentToken internal xagent;
    ExistingTokenAssetController internal controller;

    address internal seeder = makeAddr("seeder");
    address internal alice = makeAddr("alice"); // honest wrapped holder
    address internal attacker = makeAddr("attacker");
    address internal lender = makeAddr("lender"); // lending market / flash source

    uint256 internal constant SEED = 1_000_000e18;
    uint256 internal constant W = 100_000e18; // honest wrapped supply

    function setUp() public {
        setUpBase(); // protocol factories

        underlying = new ControlledUnderlying();
        underlying.mint(seeder, SEED);
        underlying.mint(alice, W);
        underlying.mint(lender, 10_000_000e18);

        ExistingDACConfig memory config = ExistingDACConfig({
            symbol: "EXIST",
            name: "Existing DAC",
            description: "existing token governance",
            underlyingToken: address(underlying),
            treasurySeedAmount: SEED,
            governanceOracle: address(0),
            dividendsEnabled: true,
            governanceStrategy: GovernanceStrategyConfig({
                quorumPercent: MathLib.atScale(50),
                highQuorumPercent: MathLib.atScale(75),
                blockingPercent: MathLib.atScale(20),
                duration: 7 days,
                qualification: MathLib.atScale(5),
                executionValidityDuration: 1 days,
                oraclePublishDeadline: 0,
                fallbackWarmupDuration: 4 hours,
                fallbackDuration: 3 days,
                blockingOnAllProposals: false,
                blockingOnHighQuorum: true,
                oraclePrimaryEnabled: false,
                voteRetentionPercent: 0,
                voteLockDuration: 0
            })
        });

        vm.startPrank(seeder);
        underlying.approve(address(dacFactory), SEED);
        (address dacAddr, address wrappedAddr, address agentAddr) =
            dacFactory.deployExistingTokenDAC(abi.encode(config), bytes32("existing"));
        vm.stopPrank();

        xdac = DACCell(dacAddr);
        wrapped = WrappedMainToken(wrappedAddr);
        xagent = AgentToken(agentAddr);
        controller = ExistingTokenAssetController(xdac.getAssetController());

        vm.startPrank(alice);
        underlying.approve(address(wrapped), type(uint256).max);
        wrapped.wrap(W);
        vm.stopPrank();

        // Proposal qualification reads votes at the previous second.
        vm.warp(block.timestamp + 1);
    }

    function _passAsAlice(ProposalParams memory p) internal returns (uint256 id) {
        vm.prank(alice);
        id = xdac.createManagementProposal(p);
        HybridDACManagementProposal prop = HybridDACManagementProposal(xdac.getProposalVoting(id));
        vm.warp(prop.fallbackSnapshotTime() + 1);
        vm.prank(alice);
        prop.vote(true);
        xdac.executeDACProposal(id);
    }

    function _evilDealParams(address module) internal view returns (DealParams memory p) {
        p.dealKind = bytes4(keccak256("evil"));
        p.name = "attach";
        p.description = "attach";
        p.moduleFactory = module;
        p.governanceFactory = address(coreDealGovernanceFactory);
        p.proposer = attacker;
        p.approveDeadline = block.timestamp + 1 days;
        p.evaluationDeadline = block.timestamp + 2 days;
        p.dealDeadline = block.timestamp + 3 days;
    }

    // Governance approves the module and an agent seat while alice is the electorate;
    // the attacker parks half of alice's stake in a contract of its own, delegated to its EOA.
    function _hostileModuleAndDelegatedVault(bool cooperating)
        internal
        returns (EvilModule evil, PassiveVault vault, uint256 parked)
    {
        evil = new EvilModule();
        _passAsAlice(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(evil), i: bytes32(0), data: bytes("")
            })
        );
        _passAsAlice(
            ProposalParams({
                typ: DACManagementProposalType.MINT_AGENT_TOKENS,
                target: attacker,
                i: bytes32(uint256(1e18)),
                data: bytes("")
            })
        );

        parked = 50_000e18;
        vault = cooperating ? PassiveVault(payable(address(new CellNamingVault(attacker)))) : new PassiveVault(attacker);
        vm.prank(lender);
        underlying.transfer(attacker, parked + 1);
        vm.startPrank(attacker);
        underlying.approve(address(wrapped), parked + 1);
        wrapped.wrapTo(address(vault), parked);
        wrapped.wrap(1);
        vault.delegateTo(address(wrapped), attacker);
        vm.stopPrank();

        assertEq(controller.totalReleasedVotable(), W + parked + 1); // attacker: 33% of votes
    }

    /// The Deal a module returns is taken out of the electorate only if it is a contract
    /// bound to the very cell being created. An arbitrary contract (a wallet, a vault,
    /// somebody else's holdings) does not answer for that cell and is refused.
    function test_REG_M07_kernelPath_refusesAContractThatIsNotThisCellsDeal() public {
        (EvilModule evil, PassiveVault vault,) = _hostileModuleAndDelegatedVault(false);

        // An unrelated passive holder that never delegated.
        PassiveVault bystander = new PassiveVault(makeAddr("bystander-owner"));
        vm.prank(alice);
        wrapped.transfer(address(bystander), 10_000e18);
        uint256 votable = controller.totalReleasedVotable();

        address manager = xdac.getDealManager();
        vm.startPrank(attacker);
        evil.setNextDeal(address(vault));
        DealParams memory params = _evilDealParams(address(evil));
        vm.expectRevert();
        IDealManager(manager).createDealProposal(params);

        evil.setNextDeal(address(bystander));
        vm.expectRevert();
        IDealManager(manager).createDealProposal(params);
        vm.stopPrank();

        assertFalse(controller.isControlledAddress(address(vault)));
        assertFalse(controller.isControlledAddress(address(bystander)));
        assertEq(controller.totalReleasedVotable(), votable, "electorate unchanged");

        // The bystander keeps its right to delegate.
        vm.prank(makeAddr("bystander-owner"));
        bystander.delegateTo(address(wrapped), makeAddr("bystander-owner"));
    }

    /// A contract built to name the cell still has to satisfy the rule every module is held
    /// to: an address that has delegated is a voter, and a voter is never marked controlled.
    function test_REG_M07_kernelPath_refusesADelegatedContractEvenIfItNamesTheCell() public {
        (EvilModule evil, PassiveVault vault, uint256 parked) = _hostileModuleAndDelegatedVault(true);

        address manager = xdac.getDealManager();
        vm.startPrank(attacker);
        evil.setNextDeal(address(vault));
        DealParams memory params = _evilDealParams(address(evil));
        vm.expectRevert(DACErrorsLib.ControlledAddressHasVotingPower.selector);
        IDealManager(manager).createDealProposal(params);
        vm.stopPrank();

        assertFalse(controller.isControlledAddress(address(vault)));
        assertEq(controller.totalReleasedVotable(), W + parked + 1, "its balance stays in the electorate");
        assertEq(wrapped.getVotes(attacker), parked + 1, "where its votes are counted too");
    }
}
