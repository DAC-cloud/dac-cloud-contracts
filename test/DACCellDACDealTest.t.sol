// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {DACCell} from "../src/kernel/DACCell.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {DACConfig, CapitalCall, ProposalParams, DealParams} from "../src/interfaces/Structs.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../src/kernel/tokens/factories/TokenFactories.sol";
import {DACManagementProposalFactory} from "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {DealManagerFactory} from "../src/kernel/factories/DealManagerFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {DACCellFactory} from "../src/kernel/factories/DACCellFactory.sol";
import {ModuleRegistryFactory} from "../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../src/kernel/factories/AssetControllerFactory.sol";
import {ExistingTokenAssetControllerFactory} from "../src/kernel/factories/ExistingTokenAssetControllerFactory.sol";
import {NativeGovernanceSchemaFactory} from "../src/kernel/governance/factories/NativeGovernanceSchemaFactory.sol";
import {HybridGovernanceSchemaFactory} from "../src/kernel/governance/factories/HybridGovernanceSchemaFactory.sol";
import {GovernanceOracleFactory} from "../src/kernel/governance/factories/GovernanceOracleFactory.sol";
import {HybridDACManagementProposalFactory} from "../src/kernel/governance/factories/HybridDACManagementProposalFactory.sol";
import {WrappedMainTokenFactory} from "../src/kernel/tokens/factories/WrappedMainTokenFactory.sol";
import {DACFactory} from "../src/kernel/DACFactory.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDACFactory} from "../src/interfaces/IDACFactory.sol";
import {CoreModuleFactory} from "../src/modules/core/CoreModuleFactory.sol";
import {DACDeal} from "../src/modules/core/deals/DACDeal.sol";
import {CoreDealType, CoreEvaluatorType} from "../src/modules/core/CoreModuleDeals.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";
import {DACDealFactory} from "../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneBasedEvaluator} from "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {MilestoneEvaluatorFactory} from "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {CoreManagementProposalFactory} from "../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import {DACDeal} from "../src/modules/core/deals/DACDeal.sol";
import {Milestone, DACDealConfig} from "../src/modules/core/interfaces/Structs.sol";
import {DACTestBase, MockUSDC} from "./base/DACTestBase.t.sol";

contract DACDealRewardForwardHarness is DACDeal {
    function setMainTokenForTest(address token) external {
        mainTokenAddr = token;
    }

    function setManagedEntityForTest(address entity) external {
        managedEntity = entity;
    }

    function exposeAfterClaimMainToken(address grantee, uint256 amount) external {
        _afterClaimMainToken(grantee, amount);
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

        coreDealGovernanceFactory = new CoreManagementProposalFactory();

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
            [
                address(new MainTokenFactory()),
                address(new AgentTokenFactory()),
                address(new DACCellFactory()),
                address(new DealManagerFactory()),
                address(new ModuleRegistryFactory()),
                address(new NativeAssetControllerFactory()),
                address(governanceFactory),
                address(new NativeGovernanceSchemaFactory()),
                address(coreModule)
            ],
            [
                address(new ExistingTokenAssetControllerFactory()),
                address(new HybridDACManagementProposalFactory()),
                address(new HybridGovernanceSchemaFactory()),
                address(new WrappedMainTokenFactory()),
                address(new GovernanceOracleFactory())
            ]
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

        usdc.approve(dac.getAssetController(), 20_000);

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
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode(dacDealConfig),
            evaluatorConfig: abi.encode(evaluatorCfg)
        });

        (,, address deal,) = IDealManager(dac.getDealManager()).createDealProposal(params);

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

    function testDACDeal_claimedRewardPoolForwardsToChildTreasury() public {
        DACDealRewardForwardHarness harness = new DACDealRewardForwardHarness();

        DACConfig memory childConfig = DACConfig({
            symbol: "CHILD",
            name: "Child DAC",
            description: "child",
            mainTokenMaxSupply: 1_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: founder,
            founderAllocation: 100_000e18,
            treasuryToken: address(usdc),
            founderCommitment: 10_000,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("child-dac-reward-forward", block.timestamp));

        vm.prank(founder);
        (address childDac, address childMainTokenAddr,) = dacFactory.deployDAC(childConfig, salt, address(0));

        vm.startPrank(founder);
        usdc.approve(DACCell(childDac).getAssetController(), 10_000);
        DACCell(childDac).fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: 0,
                tokenRecipient: founder,
                tokenAmount: 100_000e18,
                cashAmount: 10_000
            })
        );
        require(MainToken(childMainTokenAddr).transfer(address(harness), 1e18));
        require(mainToken.transfer(address(harness), 25e18));
        vm.stopPrank();

        harness.setManagedEntityForTest(childDac);
        harness.setMainTokenForTest(address(mainToken));

        address childAssetController = DACCell(childDac).getAssetController();
        uint256 childTreasuryBefore = mainToken.balanceOf(childAssetController);
        uint256 childCellBefore = mainToken.balanceOf(childDac);

        harness.exposeAfterClaimMainToken(address(harness), 25e18);

        assertEq(mainToken.balanceOf(address(harness)), 0);
        assertEq(mainToken.balanceOf(childDac), childCellBefore);
        assertEq(mainToken.balanceOf(childAssetController), childTreasuryBefore + 25e18);
    }
}
