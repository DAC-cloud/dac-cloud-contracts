// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/kernel/libraries/MathLib.sol";
import "../src/kernel/DACCell.sol";
import "../src/kernel/tokens/MainToken.sol";
import "../src/kernel/tokens/AgentToken.sol";
import "../src/kernel/tokens/factories/TokenFactories.sol";
import "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import "../src/kernel/factories/DealManagerFactory.sol";
import "../src/kernel/factories/DealCellFactory.sol";
import "../src/kernel/DACFactory.sol";
import "../src/kernel/Deal.sol";
import "../src/kernel/libraries/MathLib.sol";
import "../src/interfaces/IDACFactory.sol";
import "../src/interfaces/Structs.sol";
import "../src/modules/core/CoreModuleFactory.sol";
import "../src/modules/core/deals/factories/DACDealFactory.sol";
import "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import "../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import "../src/modules/core/interfaces/Structs.sol";
import "../src/modules/core/deals/DACDeal.sol";
import "./base/DACTestBase.t.sol";

contract DACCellDealTest is Test {
    MockUSDC usdc;

    DACCell dac;
    MainToken mainToken;
    AgentToken agentToken;

    CoreModuleFactory coreModule;
    CoreManagementProposalFactory coreDealGovernanceFactory;
    
    DACManagementProposalFactory governanceFactory;
    DACFactory dacFactory;
    
    address moduleOwner = makeAddr("bob");

    address founder = makeAddr("alice");

    address agent = makeAddr("claw");

    address accoucher = makeAddr("dac-deal-deployer");

    address permit2 = makeAddr("permit2");

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(founder, 100_000);

        vm.startPrank(moduleOwner);

        // Core module

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

        // DAC entity

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

        vm.startPrank(founder);

        ProposalParams memory params = ProposalParams({
            typ: DACManagementProposalType.MINT_AGENT_TOKENS,
            target: agent,
            i: bytes32(uint256(100_000)),
            data: bytes("")
        });

        uint256 propId = dac.createManagementProposal(params);

        vm.warp(block.timestamp + 1);

        IVoting(dac.getProposalVoting(propId)).vote(true);

        dac.executeDACProposal(propId);

        vm.stopPrank();

        assertEq(agentToken.balanceOf(agent), 100_000, "Incorrect agent token balance after mint");
    }

    function testDACDealSleeping() public {
        vm.startPrank(agent);

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
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18;
        milestones[0].penaltyCurve[0] = 1e18;

        MilestoneBasedEvaluator.Config memory evaluatorCfg = MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones);

        DACConfig memory childDACConfig = DACConfig({
            symbol: "DAC-L2",
            name: "DAC L2",
            description: "future of finance",
            mainTokenMaxSupply: 1_000_000,
            defaultQuorum: 50,
            founder: founder, // will be replaced
            founderAllocation: 100_000,
            treasuryToken: address(usdc),
            founderCommitment: 10_000,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("DAC-L2", block.timestamp));

        DACDealConfig memory dacDealConfig = DACDealConfig({
            managedEquity: 100_000,
            capitalCallId: 0,
            config: abi.encode(address(dacFactory), accoucher, salt, childDACConfig)
        });

        DealParams memory params = DealParams({
            dealKind: CoreDealType.DAC_DEAL,
            name: "Test DAC Deal",
            description: "Test DAC Deal description #2",
            linkHash: "0x00112233",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode(dacDealConfig),
            evaluatorConfig: abi.encode(evaluatorCfg)
        });

        (uint256 dealId, address dealCell, address deal, address evaluator) = IDealManager(dac.getDealManager()).createDealProposal(params);

        vm.warp(block.timestamp + 1);

        vm.startPrank(accoucher);

        address sleepingDacCell = Deal(deal).managedEntity();

        (address dacMain, address dacAgent) = DACDeal(deal).dacCellDNA();

        childDACConfig.founder = deal;

        dacFactory.startDAC(
            sleepingDacCell,
            childDACConfig,
            dacMain,
            dacAgent
        );
        
        vm.stopPrank();
    }
} 