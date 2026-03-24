// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACCell} from "../src/kernel/DACCell.sol";
import {DACFactory} from "../src/kernel/DACFactory.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {DACConfig, CapitalCall, ProposalParams} from "../src/interfaces/Structs.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {DACManagementProposalFactory} from "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {CoreModuleFactory} from "../src/modules/core/CoreModuleFactory.sol";
import {DACDealFactory} from "../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneEvaluatorFactory} from "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {DACCellFactory} from "../src/kernel/factories/DACCellFactory.sol";
import {DealManagerFactory} from "../src/kernel/factories/DealManagerFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {ModuleRegistryFactory} from "../src/kernel/factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "../src/kernel/factories/AssetControllerFactory.sol";
import {ExistingTokenAssetControllerFactory} from "../src/kernel/factories/ExistingTokenAssetControllerFactory.sol";
import {NativeGovernanceSchemaFactory} from "../src/kernel/governance/factories/NativeGovernanceSchemaFactory.sol";
import {HybridGovernanceSchemaFactory} from "../src/kernel/governance/factories/HybridGovernanceSchemaFactory.sol";
import {GovernanceOracleFactory} from "../src/kernel/governance/factories/GovernanceOracleFactory.sol";
import {HybridDACManagementProposalFactory} from "../src/kernel/governance/factories/HybridDACManagementProposalFactory.sol";
import {WrappedMainTokenFactory} from "../src/kernel/tokens/factories/WrappedMainTokenFactory.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {MainTokenFactory, AgentTokenFactory, StakedAgentFactory} from "../src/kernel/tokens/factories/TokenFactories.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../src/interfaces/DACEventsLib.sol";
import {MockUSDC} from "./base/DACTestBase.t.sol";

contract DividendPayoutTest is Test {
    address moduleOwner = makeAddr("module-owner");
    address founder = makeAddr("founder");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");
    address permit2 = makeAddr("permit2");

    DACFactory dacFactory;
    MockUSDC usdc;

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(founder, 100_000e6);

        vm.startPrank(moduleOwner);

        CoreModuleFactory coreModule = new CoreModuleFactory(
            address(new DealCellFactory()),
            address(new DACDealFactory()),
            address(new StakedAgentFactory()),
            address(new TreasuryDealFactory(permit2)),
            address(new MilestoneEvaluatorFactory()),
            address(new RevenueEvaluatorFactory())
        );

        DACManagementProposalFactory governanceFactory = new DACManagementProposalFactory();

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
    }

    function test_dividendPayout_claimsWithMerkleProof() public {
        (DACCell dac,,) = _deployDAC(true, "DIV");

        (bytes32 root, bytes32[] memory proof1, bytes32[] memory proof2) = _buildTwoLeafTree(
            recipient1,
            3_000e6,
            recipient2,
            2_000e6
        );

        uint256 proposalId = _executeDividendPayoutProposal(dac, root, 5_000e6);

        uint256 before1 = usdc.balanceOf(recipient1);
        uint256 before2 = usdc.balanceOf(recipient2);

        vm.expectEmit(true, true, true, true, address(dac));
        emit DACEventsLib.DividendClaimed(proposalId, address(usdc), recipient1, 3_000e6);
        vm.prank(recipient1);
        dac.claimDividend(proposalId, 0, recipient1, 3_000e6, proof1);

        vm.prank(recipient2);
        dac.claimDividend(proposalId, 1, recipient2, 2_000e6, proof2);

        assertEq(usdc.balanceOf(recipient1), before1 + 3_000e6);
        assertEq(usdc.balanceOf(recipient2), before2 + 2_000e6);
        assertEq(usdc.balanceOf(dac.getAssetController()), 15_000e6);
    }

    function test_dividendPayout_cannotDoubleClaim() public {
        (DACCell dac,,) = _deployDAC(true, "DIV-DOUBLE");

        (bytes32 root, bytes32[] memory proof1,) = _buildTwoLeafTree(
            recipient1,
            3_000e6,
            recipient2,
            2_000e6
        );

        uint256 proposalId = _executeDividendPayoutProposal(dac, root, 5_000e6);

        vm.prank(recipient1);
        dac.claimDividend(proposalId, 0, recipient1, 3_000e6, proof1);

        vm.prank(recipient1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DACErrorsLib.DividendAlreadyClaimed.selector,
                proposalId,
                recipient1
            )
        );
        dac.claimDividend(proposalId, 0, recipient1, 3_000e6, proof1);
    }

    function test_dividendPayout_invalidProofReverts() public {
        (DACCell dac,,) = _deployDAC(true, "DIV-BAD");

        (bytes32 root, bytes32[] memory proof1,) = _buildTwoLeafTree(
            recipient1,
            3_000e6,
            recipient2,
            2_000e6
        );

        uint256 proposalId = _executeDividendPayoutProposal(dac, root, 5_000e6);

        vm.prank(recipient1);
        vm.expectRevert(DACErrorsLib.InvalidMerkleProof.selector);
        dac.claimDividend(proposalId, 0, recipient1, 3_001e6, proof1);
    }

    function test_dividendPayout_revertsWhenDividendsDisabled() public {
        (DACCell dac,,) = _deployDAC(false, "DIV-OFF");

        (bytes32 root,,) = _buildTwoLeafTree(
            recipient1,
            3_000e6,
            recipient2,
            2_000e6
        );

        vm.startPrank(founder);
        vm.expectRevert(DACErrorsLib.DividendsNotEnabled.selector);
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.DIVIDEND_PAYOUT,
                target: address(0),
                i: 0,
                data: abi.encode(address(usdc), uint256(5_000e6), root)
            })
        );
        vm.stopPrank();
    }

    function _deployDAC(bool dividendsEnabled, string memory saltLabel)
        internal
        returns (DACCell dac, MainToken mainToken, AgentToken agentToken)
    {
        vm.startPrank(founder);

        DACConfig memory config = DACConfig({
            symbol: "DACX",
            name: "Dividend DAC",
            description: "dividend test dac",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: founder,
            founderAllocation: 200_000_000e18,
            treasuryToken: address(usdc),
            founderCommitment: 20_000e6,
            dividendsEnabled: dividendsEnabled
        });

        bytes32 salt = keccak256(abi.encode(saltLabel, block.timestamp));
        (address dacAddress, address mainTokenAddress, address agentTokenAddress) = dacFactory.deployDAC(
            config,
            salt,
            address(0)
        );

        dac = DACCell(dacAddress);
        mainToken = MainToken(mainTokenAddress);
        agentToken = AgentToken(agentTokenAddress);

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

    function _executeDividendPayoutProposal(DACCell dac, bytes32 root, uint256 totalPayout) internal returns (uint256 proposalId) {
        vm.startPrank(founder);

        proposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.DIVIDEND_PAYOUT,
                target: address(0),
                i: 0,
                data: abi.encode(address(usdc), totalPayout, root)
            })
        );

        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(proposalId)).vote(true);
        dac.executeDACProposal(proposalId);

        vm.stopPrank();
    }

    function _buildTwoLeafTree(
        address account1,
        uint256 amount1,
        address account2,
        uint256 amount2
    ) internal pure returns (bytes32 root, bytes32[] memory proof1, bytes32[] memory proof2) {
        bytes32 leaf1 = _leaf(0, account1, amount1);
        bytes32 leaf2 = _leaf(1, account2, amount2);

        root = _hashPair(leaf1, leaf2);

        proof1 = new bytes32[](1);
        proof1[0] = leaf2;

        proof2 = new bytes32[](1);
        proof2[0] = leaf1;
    }

    function _leaf(uint256 index, address receiver, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(index, receiver, amount));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
