// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACCellGovernanceLib, IDACGovernanceAdapter} from "../src/kernel/libraries/DACCellGovernanceLib.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {DealState} from "../src/kernel/interfaces/Structs.sol";
import {DealParams, VotingConfig} from "../src/interfaces/Structs.sol";
import {IModuleFactory} from "../src/interfaces/IModuleFactory.sol";
import {IModuleRegistry} from "../src/interfaces/IModuleRegistry.sol";

contract MockModuleRegistry is IModuleRegistry {
    mapping(address => bool) internal approved;

    function setApproved(address moduleFactory, bool isApproved) external {
        approved[moduleFactory] = isApproved;
    }

    function isModuleApproved(address moduleFactory) external view returns (bool) {
        return approved[moduleFactory];
    }

    function approveModule(address moduleFactory) external {
        approved[moduleFactory] = true;
    }

    function removeModule(address moduleFactory) external {
        approved[moduleFactory] = false;
    }
}

contract DACCellGovernanceLibTest is Test {

    event DealCreated(address dac, uint256 indexed id, uint256 indexed proposalId, address creator, bytes4 kind, address cell, address deal);

    // Mocked state variables (we pass these to the library)
    mapping(uint256 => address) internal mockDeals;
    mapping(address => DealState) internal mockDealRegistry;
    MockModuleRegistry internal mockRegistry;

    // Mock addresses
    address mockDACCell = makeAddr("dacCell");
    address mockModuleFactory = makeAddr("moduleFactory");
    address mockDeal = makeAddr("deal");
    address mockDealCell = makeAddr("dealCell");
    address mockEvaluator = makeAddr("evaluator");

    // Test constants
    bytes4 constant MOCK_DEAL_KIND = bytes4(keccak256("TestDeal"));

    function setUp() public {
        // Set up mocks
        mockRegistry = new MockModuleRegistry();
        mockRegistry.setApproved(mockModuleFactory, true);
    }

    function test_createDealProposal() public {
        // Prepare input params
        DealParams memory params = DealParams({
            dealKind: MOCK_DEAL_KIND,
            name: "Test Deal",
            description: "Test Deal description",
            linkHash: "0x00112233",
            moduleFactory: mockModuleFactory,
            governanceFactory: makeAddr("governanceFactory"),
            dealTarget: makeAddr("target"),
            proposer: msg.sender,
            vetoEnabled: false,
            fundingToken: makeAddr("usdc"),
            fundingAmount: 1000e6,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: bytes4(keccak256("TestEvaluator")),
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: abi.encode("evaluator config"),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        VotingConfig memory votingConfig = VotingConfig({
            quorumPercent: MathLib.atScale(50),
            blockingPercent: MathLib.atScale(25),
            highQuorumPercent: MathLib.atScale(80),
            duration: 1 days,
            qualification: 1e6,
            executionValidityDuration: 1 days
        });

        // Mock external calls
        vm.mockCall(
            mockModuleFactory,
            abi.encodeWithSelector(IModuleFactory.deployDeal.selector),
            abi.encode(mockDealCell, mockDeal)
        );

        vm.mockCall(
            mockModuleFactory,
            abi.encodeWithSelector(IModuleFactory.isActive.selector),
            abi.encode(true)
        );

        vm.mockCall(
            mockModuleFactory,
            abi.encodeWithSelector(IModuleFactory.supportsEvaluatorKind.selector),
            abi.encode(true)
        );

        vm.mockCall(
            mockModuleFactory,
            abi.encodeWithSelector(IModuleFactory.deployEvaluator.selector),
            abi.encode(mockEvaluator)
        );

        vm.mockCall(
            mockDACCell,
            abi.encodeWithSelector(IDACGovernanceAdapter.createManagementProposal.selector),
            abi.encode(1)  // mock proposal ID
        );

        // vm.expectEmit(true, true, true, true);
        // emit DealCreated(mockDACCell, 1, 1, msg.sender, MOCK_DEAL_KIND, mockDealCell, mockDeal);

        // Call the library function
        (uint256 id, address dealCell, address dealAddr, address evaluatorAddr) = DACCellGovernanceLib.createDealProposal(
            mockDACCell,
            1, // nextId = 1
            params,
            votingConfig,
            mockRegistry,
            mockDeals,
            mockDealRegistry
        );
        vm.stopPrank();

        // Assertions
        assertEq(id, 1, "id");
        assertEq(dealAddr, mockDeal, "deal addr");
        assertEq(dealCell, mockDealCell, "deal cell addr");
        assertEq(mockDeals[1], mockDealCell, "deal cell by id");
        assertEq(mockDealRegistry[mockDealCell].id, 1, "id in registry");
        assertEq(address(mockDealRegistry[mockDealCell].module), mockModuleFactory, "module set");
    }
}
