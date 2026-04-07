// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {DACFactory} from "../../src/kernel/DACFactory.sol";
import {Deal} from "../../src/kernel/Deal.sol";
import {IDealManager} from "../../src/interfaces/IDealManager.sol";
import {IVoting} from "../../src/interfaces/IVoting.sol";
import {DACConfig, CapitalCall, ProposalParams, DealParams} from "../../src/interfaces/Structs.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {CoreDealType, CoreEvaluatorType} from "../../src/modules/core/CoreModuleDeals.sol";
import {CoreModuleFactory} from "../../src/modules/core/CoreModuleFactory.sol";
import {DACDealFactory} from "../../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneBasedEvaluator} from "../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {MilestoneEvaluatorFactory} from "../../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {CoreManagementProposalFactory} from "../../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import {DACCellFactory} from "../../src/kernel/factories/DACCellFactory.sol";
import {Milestone, DACDealConfig} from "../../src/modules/core/interfaces/Structs.sol";
import {DACManagementProposalFactory} from "../../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {DealManagerFactory} from "../../src/kernel/factories/DealManagerFactory.sol";
import {DealCellFactory} from "../../src/kernel/factories/DealCellFactory.sol";
import {ModuleRegistryFactory} from "../../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../../src/kernel/factories/AssetControllerFactory.sol";
import {ExistingTokenAssetControllerFactory} from "../../src/kernel/factories/ExistingTokenAssetControllerFactory.sol";
import {NativeGovernanceSchemaFactory} from "../../src/kernel/governance/factories/NativeGovernanceSchemaFactory.sol";
import {HybridGovernanceSchemaFactory} from "../../src/kernel/governance/factories/HybridGovernanceSchemaFactory.sol";
import {GovernanceOracleFactory} from "../../src/kernel/governance/factories/GovernanceOracleFactory.sol";
import {HybridDACManagementProposalFactory} from "../../src/kernel/governance/factories/HybridDACManagementProposalFactory.sol";
import {WrappedMainTokenFactory} from "../../src/kernel/tokens/factories/WrappedMainTokenFactory.sol";
import {MainToken} from "../../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../../src/kernel/tokens/factories/TokenFactories.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Crypto Dollars", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract DACTestBase is Test {

    address moduleOwner = makeAddr("module-owner");

    CoreModuleFactory coreModule;
    CoreManagementProposalFactory coreDealGovernanceFactory;
    
    DACManagementProposalFactory governanceFactory;
    DACFactory dacFactory;

    // Core contracts
    DACCell public dac;
    MainToken public mainToken;
    AgentToken public agentToken;
    address public dealManager;

    // Test accounts
    address public founder = makeAddr("founder");
    MockUSDC public usdc;

    address permit2 = makeAddr("permit2");

    // Deal data (automatically populated from events)
    struct DealHandle {
        uint256 dealId;
        address dealCell;
        address dealAddr;
        address evaluatorAddr;
        uint256 proposalId;
    }

    function setUpBase() internal {
        usdc = new MockUSDC();
        usdc.mint(founder, 100_000e6);

        vm.startPrank(moduleOwner);

        // Core module

        coreDealGovernanceFactory = new CoreManagementProposalFactory();

        address dealCellFactory_ = address(new DealCellFactory());
        address stakedAgentFactory_ = address(new StakedAgentFactory());

        coreModule = new CoreModuleFactory(
            address(new DACDealFactory()),
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
                address(coreModule),
                dealCellFactory_,
                stakedAgentFactory_
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
            founderCommitment: 20_000e6,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("MyFirstDAC-v1", block.timestamp));

        (address dacAddress, address mainTokenAddress, address agentTokenAddress) = dacFactory.deployDAC(
            config, salt, address(0)
        );

        mainToken = MainToken(mainTokenAddress);
        agentToken = AgentToken(agentTokenAddress);
        dac = DACCell(dacAddress);

        usdc.approve(dac.getAssetController(), 20_000e6);

        CapitalCall memory call = CapitalCall({
            treasuryToken: address(usdc),
            nonce: 0,
            tokenRecipient: founder,
            tokenAmount: 200_000_000e18,
            cashAmount: 20_000e6
        });

        dac.fulfillCapitalCall(call);
        mainToken.delegate(founder);

        vm.stopPrank();
    }

    function onboardAgent(address agent) internal {
        vm.startPrank(founder);

        // Mint agent token
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

        dealManager = dac.getDealManager();

        vm.stopPrank();
    }

    function createTreasuryDeal(address agent) internal returns (DealHandle memory handle) {
        vm.recordLogs();

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

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Test Treasury Deal",
            description: "Test Treasury Deal description",
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
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: abi.encode(evaluatorCfg),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) = IDealManager(dealManager).createDealProposal(params);

        vm.stopPrank();

        handle.dealId = dealId;
        handle.dealCell = dealCell;
        handle.dealAddr = dealAddr;
        handle.evaluatorAddr = evaluatorAddr;

        // Parse logs for DealCreated event to get proposalId for further automated voting
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }

    function createDACDeal(address agent) internal returns (DealHandle memory handle) {
        vm.recordLogs();
        
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
            config: abi.encode(address(dacFactory), address(0), salt, childDACConfig)
        });

        DealParams memory params = DealParams({
            dealKind: CoreDealType.DAC_DEAL,
            name: "Test DAC Deal",
            description: "Test DAC Deal description",
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
            evaluatorConfig: abi.encode(evaluatorCfg),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) = IDealManager(dealManager).createDealProposal(params);

        vm.stopPrank();

        handle.dealId = dealId;
        handle.dealCell = dealCell;
        handle.dealAddr = dealAddr;
        handle.evaluatorAddr = evaluatorAddr;

        // Parse logs for DealCreated event to get proposalId for further automated voting
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }
}
