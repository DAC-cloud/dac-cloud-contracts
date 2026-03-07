// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/kernel/DACCell.sol";
import "../src/kernel/tokens/MainToken.sol";
import "../src/kernel/tokens/AgentToken.sol";
import "../src/kernel/tokens/factories/TokenFactories.sol";
import "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import "../src/kernel/factories/DACCellFactory.sol";
import "../src/kernel/factories/DealCellFactory.sol";
import "../src/kernel/factories/DealManagerFactory.sol";
import "../src/kernel/DACFactory.sol";
import "../src/kernel/libraries/MathLib.sol";
import "../src/interfaces/IDACFactory.sol";
import "../src/interfaces/Structs.sol";
import "../src/modules/core/CoreModuleFactory.sol";
import "../src/modules/core/deals/factories/DACDealFactory.sol";
import "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Crypto Dollars", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DACCellAgentTest is Test {
    MockUSDC usdc;

    DACCell dac;
    MainToken mainToken;
    AgentToken agentToken;

    CoreModuleFactory coreModule;
    
    DACManagementProposalFactory governanceFactory;
    DACFactory dacFactory;
    
    address moduleOwner = makeAddr("bob");

    address founder = makeAddr("alice");

    address agent = makeAddr("claw");

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

    function testAgentTokens() public {
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

        vm.warp(block.timestamp + 1);

        vm.startPrank(founder);

        params = ProposalParams({
            typ: DACManagementProposalType.REVOKE_AGENT_TOKENS,
            target: agent,
            i: bytes32(uint256(50_000)),
            data: bytes("")
        });

        propId = dac.createManagementProposal(params);

        vm.warp(block.timestamp + 1);

        IVoting(dac.getProposalVoting(propId)).vote(true);

        dac.executeDACProposal(propId);

        vm.stopPrank();

        assertEq(agentToken.balanceOf(agent), 50_000, "Incorrect agent token balance after revoke");
    }
} 