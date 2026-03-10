// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACCell} from "../src/kernel/DACCell.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../src/kernel/tokens/factories/TokenFactories.sol";
import {DACManagementProposalFactory} from "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {DACCellFactory} from "../src/kernel/factories/DACCellFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {DealManagerFactory} from "../src/kernel/factories/DealManagerFactory.sol";
import {DACFactory} from "../src/kernel/DACFactory.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDACFactory} from "../src/interfaces/IDACFactory.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {DACConfig, CapitalCall, ProposalParams, DealParams} from "../src/interfaces/Structs.sol";
import {CoreModuleFactory} from "../src/modules/core/CoreModuleFactory.sol";
import {DACDealFactory} from "../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneEvaluatorFactory} from "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Crypto Dollars", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DACCellMainTest is Test {
    MockUSDC usdc;

    DACCell dac;
    MainToken mainToken;
    AgentToken agentToken;

    CoreModuleFactory coreModule;
    
    DACManagementProposalFactory governanceFactory;
    DACFactory dacFactory;
    
    address moduleOwner = makeAddr("bob");

    address founder = makeAddr("alice");

    address permit2 = makeAddr("permit2");

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(founder, 100_000);

        vm.startPrank(moduleOwner);

        coreModule = new CoreModuleFactory(
            address(new DealCellFactory()),
            address(new DACDealFactory()),
            address(new StakedAgentFactory()),
            address(new TreasuryDealFactory(permit2)),
            address(new MilestoneEvaluatorFactory()),
            address(new RevenueEvaluatorFactory())
        );
        
        governanceFactory = new DACManagementProposalFactory();

        dacFactory = new DACFactory(
            address(new MainTokenFactory()),
            address(new AgentTokenFactory()),
            address(new DACCellFactory()),
            address(new DealManagerFactory()),
            address(governanceFactory), 
            address(coreModule)
        );

        vm.stopPrank();

        vm.startPrank(founder);

        DACConfig memory config = DACConfig({
            symbol: "DACX",
            name: "DAC exchange",
            description: "future of finance",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: founder,
            founderAllocation: 200_000_000e18,
            treasuryToken: address(usdc),
            founderCommitment: 20_000,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("MyFirstDAC-v1", block.timestamp));

        (address dacAddress, address mainTokenAddress, address agentTokenAddress) = dacFactory.deployDAC(
            config, salt, address(0)
        );

        mainToken = MainToken(mainTokenAddress);
        agentToken = AgentToken(agentTokenAddress);

        dac = DACCell(dacAddress);

        vm.stopPrank();

        vm.startPrank(founder);

        usdc.approve(address(dac), 20_000);

        CapitalCall memory call = CapitalCall({
            treasuryToken: address(usdc),
            nonce: 0,
            tokenRecipient: founder,
            tokenAmount: 200_000_000e18,
            cashAmount: 20_000
        });

        dac.fulfillCapitalCall(call);

        mainToken.delegate(founder);

        vm.stopPrank();

        assertEq(mainToken.balanceOf(founder), 200_000_000e18, "Incorrect main token balance after capital call");
    }

    function testMainTokens() public {
        vm.startPrank(founder);

        ProposalParams memory params = ProposalParams({
            typ: DACManagementProposalType.MINT_MAIN_TOKENS,
            target: address(0),
            i: bytes32(uint256(600_000_000e18)),
            data: bytes("")
        });

        uint256 propId = dac.createManagementProposal(params);

        vm.warp(block.timestamp + 1);

        IVoting(dac.getProposalVoting(propId)).vote(true);

        dac.executeDACProposal(propId);

        vm.stopPrank();

        assertEq(mainToken.balanceOf(address(dac)), 600_000_000e18, "Incorrect main token balance after mint");

        vm.warp(block.timestamp + 1);

        vm.startPrank(founder);

        params = ProposalParams({
            typ: DACManagementProposalType.BURN_MAIN_TOKENS,
            target: address(0),
            i: bytes32(uint256(200_000_000e18)),
            data: bytes("")
        });

        propId = dac.createManagementProposal(params);

        vm.warp(block.timestamp + 1);

        IVoting(dac.getProposalVoting(propId)).vote(true);

        dac.executeDACProposal(propId);

        vm.stopPrank();

        assertEq(mainToken.balanceOf(address(dac)), 400_000_000e18, "Incorrect main token balance after revoke");

        assertEq(IDealManager(dac.getDealManager()).totalReleasedVotable(), 200_000_000e18, "Incorrect main token votable after revoke");
    }

    function test_RevertWhen_ExceedSupply() public {
        vm.startPrank(founder);

        ProposalParams memory params = ProposalParams({
            typ: DACManagementProposalType.MINT_MAIN_TOKENS,
            target: address(0),
            i: bytes32(uint256(800_000_001e18)),
            data: bytes("")
        });

        uint256 propId = dac.createManagementProposal(params);

        vm.warp(block.timestamp + 1);

        IVoting(dac.getProposalVoting(propId)).vote(true);

        vm.expectRevert(MainToken.MaxSupplyExceeded.selector);
        dac.executeDACProposal(propId);

        vm.stopPrank();
    }

    function test_RevertWhen_ExceedBalance() public {
        vm.startPrank(founder);

        ProposalParams memory params = ProposalParams({
            typ: DACManagementProposalType.MINT_MAIN_TOKENS,
            target: address(0),
            i: bytes32(uint256(600_000_000e18)),
            data: bytes("")
        });

        uint256 propId = dac.createManagementProposal(params);

        vm.warp(block.timestamp + 1);

        IVoting(dac.getProposalVoting(propId)).vote(true);

        dac.executeDACProposal(propId);

        vm.stopPrank();

        assertEq(mainToken.balanceOf(address(dac)), 600_000_000e18, "Incorrect main token balance after mint");

        vm.warp(block.timestamp + 1);

        vm.startPrank(founder);

        params = ProposalParams({
            typ: DACManagementProposalType.BURN_MAIN_TOKENS,
            target: address(0),
            i: bytes32(uint256(600_000_001e18)),
            data: bytes("")
        });

        propId = dac.createManagementProposal(params);

        vm.warp(block.timestamp + 1);

        IVoting(dac.getProposalVoting(propId)).vote(true);

        vm.expectRevert();
        dac.executeDACProposal(propId);

        vm.stopPrank();
    }
}