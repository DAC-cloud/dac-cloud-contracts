// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {DealParams, EvaluationResult, LegalWrapper, ProposalParams, VotingConfig} from "../src/interfaces/Structs.sol";
import {IEvaluator} from "../src/interfaces/IEvaluator.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealFactory} from "../src/interfaces/modules/IDealFactory.sol";
import {IEvaluatorFactory} from "../src/interfaces/modules/IEvaluatorFactory.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {DealManager} from "../src/kernel/DealManager.sol";
import {ModuleFactory} from "../src/kernel/ModuleFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {CoreDealType} from "../src/modules/core/CoreModuleDeals.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {StakedAgentFactory} from "../src/kernel/tokens/factories/TokenFactories.sol";

bytes4 constant DAC_TEST_EVALUATOR_SELECTOR = bytes4(keccak256("DAC_TEST_EVALUATOR"));

contract MockNoopEvaluator is IEvaluator {
    function permitMint(address, address, uint256) external pure returns (bool permit) {
        return true;
    }

    function evaluateDeal(uint256, address, address, address)
        external
        pure
        returns (EvaluationResult[] memory results)
    {
        results = new EvaluationResult[](0);
    }
}

contract MockNoopEvaluatorFactory is IEvaluatorFactory {
    function deployEvaluator(
        address,
        uint256,
        address,
        DealParams calldata,
        bytes calldata
    ) external returns (address evaluatorAddr) {
        evaluatorAddr = address(new MockNoopEvaluator());
    }
}

contract MockGovernanceModuleFactory is ModuleFactory {
    error DealKindNotSupported(bytes4 kind);
    error EvaluatorKindNotSupported(bytes4 selector);

    address public immutable treasuryDealFactory;
    address public immutable mockEvaluatorFactory;

    constructor(address permit2) ModuleFactory(address(new DealCellFactory()), address(new StakedAgentFactory())) {
        treasuryDealFactory = address(new TreasuryDealFactory(permit2));
        mockEvaluatorFactory = address(new MockNoopEvaluatorFactory());
    }

    function isActive() external pure returns (bool) { return true; }
    function safetyCheck(address) external pure returns (bool) { return true; }

    function getDealFactory(bytes4 dealKind) internal view override returns (IDealFactory factory) {
        if (dealKind != CoreDealType.PERMIT2_TREASURY) revert DealKindNotSupported(dealKind);
        factory = IDealFactory(treasuryDealFactory);
    }

    function getEvaluatorFactory(bytes4, bytes4 evaluatorSelector)
        internal
        view
        override
        returns (IEvaluatorFactory factory)
    {
        if (evaluatorSelector != DAC_TEST_EVALUATOR_SELECTOR) revert EvaluatorKindNotSupported(evaluatorSelector);
        factory = IEvaluatorFactory(mockEvaluatorFactory);
    }
}

contract DACGovernanceControlTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public wrapper = makeAddr("legal-wrapper");
    address public outsider = makeAddr("outsider");

    MockGovernanceModuleFactory mockModule;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);

        vm.prank(moduleOwner);
        mockModule = new MockGovernanceModuleFactory(permit2);
    }

    function test_holdersCannotCreateApproveDealProposalDirectly() public {
        vm.startPrank(founder);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.APPROVE_DEAL,
                target: address(0),
                i: 0,
                data: bytes("")
            })
        );
        vm.stopPrank();
    }

    function test_invalidVotingConfigRejectedAtProposalCreation() public {
        VotingConfig memory invalidConfig = VotingConfig({
            quorumPercent: 0,
            blockingPercent: 0,
            highQuorumPercent: 1,
            duration: 7 days,
            qualification: 0
        });

        vm.startPrank(founder);
        vm.expectRevert(DACErrorsLib.InvalidVotingConfig.selector);
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG,
                target: address(0),
                i: 0,
                data: abi.encode(invalidConfig)
            })
        );
        vm.stopPrank();
    }

    function test_toggleDividends_requiresLegalWrapperExecution() public {
        _setLegalWrapper();

        uint256 proposalId = _createPassedDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.TOGGLE_DIVIDENDS,
                target: address(0),
                i: 0,
                data: abi.encode(true)
            })
        );

        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.LegalWrapperExecutionExpected.selector);
        dac.executeDACProposal(proposalId);

        vm.prank(wrapper);
        dac.executeDACProposal(proposalId);

        vm.prank(founder);
        uint256 dividendProposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.DIVIDEND_PAYOUT,
                target: address(0),
                i: 0,
                data: abi.encode(address(usdc), uint256(1_000e6), bytes32(uint256(123)))
            })
        );

        assertGt(dividendProposalId, 0);
    }

    function test_removeModule_requiresLegalWrapperExecutionAndDisablesFutureDeals() public {
        _approveModule(address(mockModule));

        _createMockTreasuryDeal(agent1, address(mockModule));

        _setLegalWrapper();

        uint256 proposalId = _createPassedDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.REMOVE_MODULE,
                target: address(mockModule),
                i: 0,
                data: bytes("")
            })
        );

        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.LegalWrapperExecutionExpected.selector);
        dac.executeDACProposal(proposalId);

        vm.prank(wrapper);
        dac.executeDACProposal(proposalId);

        vm.expectRevert(DACErrorsLib.ModuleNotApproved.selector);
        _createMockTreasuryDeal(agent1, address(mockModule));
    }

    function test_removeCoreModule_revertsEvenWithWrapper() public {
        _setLegalWrapper();

        uint256 proposalId = _createPassedDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.REMOVE_MODULE,
                target: address(coreModule),
                i: 0,
                data: bytes("")
            })
        );

        vm.prank(wrapper);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        dac.executeDACProposal(proposalId);
    }

    function test_logLegalWrapperMessage_requiresConfiguredWrapper() public {
        bytes4 messageKind = bytes4(keccak256("LEGAL_LOG"));
        bytes memory message = abi.encode("wrapper ping");

        vm.prank(wrapper);
        vm.expectRevert(DACErrorsLib.LegalWrapperNotSet.selector);
        dac.logLegalWrapperMessage(messageKind, message);

        _setLegalWrapper();

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.LegalWrapperExecutionExpected.selector);
        dac.logLegalWrapperMessage(messageKind, message);

        vm.prank(wrapper);
        dac.logLegalWrapperMessage(messageKind, message);
    }

    function test_dealManagerLegalWrapperMessage_requiresWrapperAndForwardsToDeal() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        bytes4 messageKind = bytes4(keccak256("DEAL_WRAPPER"));
        bytes memory message = abi.encode(uint256(42));

        vm.prank(wrapper);
        vm.expectRevert(DACErrorsLib.LegalWrapperNotSet.selector);
        DealManager(dealManager).legalWrapperMessage(handle.dealId, messageKind, message);

        _setLegalWrapper();

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.LegalWrapperExecutionExpected.selector);
        DealManager(dealManager).legalWrapperMessage(handle.dealId, messageKind, message);

        vm.recordLogs();
        vm.prank(wrapper);
        DealManager(dealManager).legalWrapperMessage(handle.dealId, messageKind, message);

        assertTrue(
            _hasLog(keccak256("LegalWrapperMessageReceived(address,bytes4,bytes)")),
            "expected deal legal-wrapper event"
        );
    }

    function _setLegalWrapper() internal {
        uint256 proposalId = _createPassedDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_LEGAL_WRAPPER,
                target: address(0),
                i: 0,
                data: abi.encode(
                    LegalWrapper({
                        wrapperAddr: wrapper,
                        operatingAgreementIPFS: "ipfs://dac-wrapper",
                        registeredAgent: "Wrapper Agent LLC",
                        data: bytes("wrapper-data")
                    })
                )
            })
        );

        vm.prank(founder);
        dac.executeDACProposal(proposalId);
    }

    function _approveModule(address moduleFactory) internal {
        uint256 proposalId = _createPassedDACProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE,
                target: moduleFactory,
                i: 0,
                data: bytes("")
            })
        );

        vm.prank(founder);
        dac.executeDACProposal(proposalId);
    }

    function _createPassedDACProposal(ProposalParams memory params) internal returns (uint256 proposalId) {
        vm.startPrank(founder);
        proposalId = dac.createManagementProposal(params);
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(proposalId)).vote(true);
        vm.stopPrank();
    }

    function _createMockTreasuryDeal(address proposer, address moduleFactory) internal returns (DealHandle memory handle) {
        vm.recordLogs();
        vm.startPrank(proposer);

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Governance Module Deal",
            description: "Deal created through add/remove module tests",
            linkHash: "0x00gov",
            moduleFactory: moduleFactory,
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: proposer,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: DAC_TEST_EVALUATOR_SELECTOR,
            dealConfig: abi.encode("module test"),
            evaluatorConfig: bytes("")
        });

        (handle.dealId, handle.dealCell, handle.dealAddr, handle.evaluatorAddr) =
            DealManager(dealManager).createDealProposal(params);

        vm.stopPrank();
    }

    function _hasLog(bytes32 topic0) internal returns (bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic0) {
                return true;
            }
        }
    }
}
