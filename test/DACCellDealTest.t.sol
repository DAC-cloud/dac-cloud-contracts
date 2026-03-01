// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/kernel/DACCell.sol";
import "../src/kernel/tokens/MainToken.sol";
import "../src/kernel/tokens/AgentToken.sol";
import "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import "../src/kernel/factories/DealManagerFactory.sol";
import "../src/kernel/factories/DealCellFactory.sol";
import "../src/kernel/DACFactory.sol";
import "../src/kernel/Deal.sol";
import "../src/interfaces/IDACFactory.sol";
import "../src/interfaces/Structs.sol";
import "../src/modules/core/CoreModuleFactory.sol";
import "../src/modules/core/factories/DACDealFactory.sol";
import "../src/modules/core/factories/TreasuryDealFactory.sol";
import "../src/modules/core/factories/BasicEvaluatorFactory.sol";
import "../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import "../src/modules/core/interfaces/Structs.sol";
import "../src/modules/core/deals/DACDeal.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Crypto Dollars", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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
            address(new TreasuryDealFactory(permit2)),
            address(new BasicEvaluatorFactory())
        );
        
        governanceFactory = new DACManagementProposalFactory();

        dacFactory = new DACFactory(
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
            defaultQuorum: 50,
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

    function testTreasuryDeal() public {
        vm.startPrank(agent);

        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            timestamp: block.timestamp + 1 days,
            expectedReturnPercent: 100,
            rewardPercentage: 100,
            penalty: 0
        });

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Test Treasury Deal",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            linkHash: "0x00112233",
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.BASIC_REVENUE_MILESTONES,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: abi.encode(milestones)
        });

        (uint256 dealId, address dealCell, address deal, address evaluator) = IDealManager(dac.dealManager()).createDealProposal(params);

        vm.stopPrank();

        // IVoting(dac.getProposalVoting(propId)).vote(true);

        // dac.executeDACProposal(propId);

        
        // assertEq(agentToken.balanceOf(agent), 50_000, "Incorrect agent token balance after revoke");
    }

    function testDACDeal() public {
        vm.startPrank(agent);

        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            timestamp: block.timestamp + 1 days,
            expectedReturnPercent: 100,
            rewardPercentage: 100,
            penalty: 0
        });

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
            config: abi.encode(address(dacFactory), address(0), salt, childDACConfig)
        });

        DealParams memory params = DealParams({
            dealKind: CoreDealType.DAC_DEAL,
            name: "Test DAC Deal",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            linkHash: "0x00112233",
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.BASIC_REVENUE_MILESTONES,
            dealConfig: abi.encode(dacDealConfig),
            evaluatorConfig: abi.encode(milestones)
        });

        (uint256 dealId, address dealCell, address deal, address evaluator) = IDealManager(dac.dealManager()).createDealProposal(params);

        vm.warp(block.timestamp + 1);

        // IVoting(dac.getProposalVoting(propId)).vote(true);

        // dac.executeDACProposal(propId);


        // assertEq(agentToken.balanceOf(agent), 50_000, "Incorrect agent token balance after revoke");
    }

    function testDACDealSleeping() public {
        vm.startPrank(agent);

        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            timestamp: block.timestamp + 1 days,
            expectedReturnPercent: 100,
            rewardPercentage: 100,
            penalty: 0
        });

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
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            linkHash: "0x00112233",
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.BASIC_REVENUE_MILESTONES,
            dealConfig: abi.encode(dacDealConfig),
            evaluatorConfig: abi.encode(milestones)
        });

        (uint256 dealId, address dealCell, address deal, address evaluator) = IDealManager(dac.dealManager()).createDealProposal(params);

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


        // IVoting(dac.getProposalVoting(propId)).vote(true);

        // dac.executeDACProposal(propId);


        // assertEq(agentToken.balanceOf(agent), 50_000, "Incorrect agent token balance after revoke");
    }
} 