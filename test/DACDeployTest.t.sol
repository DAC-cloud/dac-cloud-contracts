// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACCell} from "../src/kernel/DACCell.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {WrappedMainToken} from "../src/kernel/tokens/WrappedMainToken.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../src/kernel/tokens/factories/TokenFactories.sol";
import {DACManagementProposalFactory} from "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {DACCellFactory} from "../src/kernel/factories/DACCellFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {DealManagerFactory} from "../src/kernel/factories/DealManagerFactory.sol";
import {ModuleRegistryFactory} from "../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../src/kernel/factories/AssetControllerFactory.sol";
import {ExistingTokenAssetControllerFactory} from "../src/kernel/factories/ExistingTokenAssetControllerFactory.sol";
import {NativeGovernanceSchemaFactory} from "../src/kernel/governance/factories/NativeGovernanceSchemaFactory.sol";
import {HybridGovernanceSchemaFactory} from "../src/kernel/governance/factories/HybridGovernanceSchemaFactory.sol";
import {GovernanceOracleFactory} from "../src/kernel/governance/factories/GovernanceOracleFactory.sol";
import {HybridDACManagementProposalFactory} from "../src/kernel/governance/factories/HybridDACManagementProposalFactory.sol";
import {WrappedMainTokenFactory} from "../src/kernel/tokens/factories/WrappedMainTokenFactory.sol";
import {DACFactory} from "../src/kernel/DACFactory.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDACFactory} from "../src/interfaces/IDACFactory.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {DACConfig, CapitalCall, ProposalParams, DealParams, ExistingDACConfig} from "../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig} from "../src/interfaces/GovernanceStructs.sol";
import {CoreModuleFactory} from "../src/modules/core/CoreModuleFactory.sol";
import {DACDealFactory} from "../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneEvaluatorFactory} from "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";

contract MockUnderlyingToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DACDeployTest is Test {
    DACCell dac;
    MainToken mainToken;
    AgentToken agentToken;

    CoreModuleFactory coreModule;
    
    DACManagementProposalFactory governanceFactory;
    DACFactory dacFactory;
    
    address owner = address(1);
    address user = address(2);

    address permit2 = address(10);

    function setUp() public {
        vm.startPrank(owner);

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

        DACConfig memory config = DACConfig({
            symbol: "DACX",
            name: "DAC exchange",
            description: "future of finance",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: user,
            founderAllocation: 200_000_000e18,
            treasuryToken: address(0),
            founderCommitment: 20_000,
            dividendsEnabled: false
        });

        bytes32 salt = keccak256(abi.encode("MyFirstDAC-v1", block.timestamp));

        (address dacAddress, address lpAddress, address mpAddress) = dacFactory.deployDAC(
            config, salt, address(0)
        );

        mainToken = MainToken(lpAddress);
        agentToken = AgentToken(mpAddress);

        dac = DACCell(dacAddress);
    }

    function testDeployment() public {
        assertEq(dac.getMainToken(), address(mainToken), "Wrong main token");
    }

    function testDeployExistingTokenDAC() public {
        MockUnderlyingToken underlying = new MockUnderlyingToken();
        underlying.mint(user, 1_000_000e18);

        ExistingDACConfig memory config = ExistingDACConfig({
            symbol: "EXIST",
            name: "Existing DAC",
            description: "existing token governance",
            underlyingToken: address(underlying),
            treasurySeedAmount: 1_000e18,
            oracleAdmin: owner,
            initialOraclePublisher: owner,
            dividendsEnabled: false,
            governanceStrategy: GovernanceStrategyConfig({
                quorumPercent: MathLib.atScale(50),
                highQuorumPercent: MathLib.atScale(75),
                blockingPercent: MathLib.atScale(20),
                duration: 7 days,
                qualification: 0,
                executionValidityDuration: 1 days,
                oraclePublishDeadline: 1 days,
                fallbackWarmupDuration: 1 days,
                fallbackDuration: 3 days,
                blockingOnAllProposals: false,
                blockingOnHighQuorum: true,
                oraclePrimaryEnabled: true
            })
        });

        vm.startPrank(user);
        underlying.approve(address(dacFactory), config.treasurySeedAmount);
        vm.recordLogs();
        (address dacAddress, address wrappedAddress, address existingAgentToken, address oracleAddress) =
            dacFactory.deployExistingTokenDAC(abi.encode(config), bytes32("existing"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        DACCell existingDac = DACCell(dacAddress);
        WrappedMainToken wrapped = WrappedMainToken(wrappedAddress);

        assertEq(existingDac.getMainToken(), wrappedAddress);
        assertEq(existingDac.getAgentToken(), existingAgentToken);
        assertTrue(existingDac.getDealManager() != address(0));
        assertTrue(existingDac.getAssetController() != address(0));
        assertTrue(existingDac.getModuleRegistry() != address(0));
        assertTrue(oracleAddress != address(0));
        assertEq(existingDac.getVotingConfig().quorumPercent, MathLib.atScale(50));
        assertEq(wrapped.balanceOf(existingDac.getAssetController()), config.treasurySeedAmount);

        vm.prank(user);
        underlying.approve(wrappedAddress, type(uint256).max);

        vm.prank(user);
        wrapped.wrap(100e18);

        vm.prank(user);
        uint256 proposalId = existingDac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.MINT_AGENT_TOKENS,
                target: user,
                i: bytes32(uint256(10e18)),
                data: bytes("")
            })
        );

        assertEq(proposalId, 1);
        assertTrue(existingDac.getProposalVoting(proposalId) != address(0));

        vm.expectRevert();
        vm.prank(user);
        existingDac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.MINT_MAIN_TOKENS,
                target: address(0),
                i: bytes32(uint256(10e18)),
                data: bytes("")
            })
        );

        _assertExistingTokenDeployEvents(
            logs,
            config,
            dacAddress,
            wrappedAddress
        );
    }

    function _assertExistingTokenDeployEvents(
        Vm.Log[] memory logs,
        ExistingDACConfig memory config,
        address dacAddress,
        address wrappedToken
    ) internal view {
        bytes32 deploySig =
            keccak256("ExistingTokenDACDeployed(address,address,address,address,address,address,address,uint256)");
        bytes32 treasurySig = keccak256("TreasuryDeposit(address,uint256,address)");

        bool sawDeploy;
        bool sawTreasuryDeposit;

        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];

            if (log.topics.length > 0 && log.topics[0] == deploySig) {
                sawDeploy = true;
                assertEq(address(uint160(uint256(log.topics[1]))), dacAddress);
                assertEq(address(uint160(uint256(log.topics[2]))), config.underlyingToken);
                assertEq(address(uint160(uint256(log.topics[3]))), wrappedToken);
            }

            if (log.topics.length > 0 && log.topics[0] == treasurySig) {
                address token = address(uint160(uint256(log.topics[1])));
                address from = address(uint160(uint256(log.topics[2])));
                uint256 amount = abi.decode(log.data, (uint256));

                if (token == wrappedToken && from == user && amount == config.treasurySeedAmount) {
                    sawTreasuryDeposit = true;
                }
            }
        }

        assertTrue(sawDeploy, "missing existing token deploy event");
        assertTrue(sawTreasuryDeposit, "missing bootstrap treasury deposit event");
    }
}
