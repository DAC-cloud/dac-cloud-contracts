// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {UUPSProxy} from "../src/kernel/proxies/UUPSProxy.sol";
import {DealCellGovernanceLib, IDealCellGovernanceAdapter} from "../src/kernel/libraries/DealCellGovernanceLib.sol";
import {IDeal} from "../src/interfaces/IDeal.sol";
import {ProposalParams, VotingConfig, DealParams, Tranche, LegalWrapper} from "../src/interfaces/Structs.sol";
import {TreasurySpendAllowance} from "../src/modules/core/interfaces/Structs.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {AbstractDealManagementType} from "../src/kernel/governance/AbstractDealManagementProposals.sol";
import {DealState} from "../src/kernel/interfaces/Structs.sol";
import {IModuleFactory} from "../src/interfaces/IModuleFactory.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";

contract LibTestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDealManagerForLib {
    address public validDealCell;
    address public validDeal;
    uint256 public lastDealId;
    uint256 public lastTrancheId;

    function configure(address dealCell, address dealAddr) external {
        validDealCell = dealCell;
        validDeal = dealAddr;
    }

    function state(address dealCell) external view returns (DealState memory dealState) {
        if (dealCell == validDealCell) {
            address[] memory evaluators = new address[](0);
            dealState = DealState({
                id: 1,
                deal: validDeal,
                module: IModuleFactory(address(0)),
                active: false,
                liquidated: false,
                rewardsLimit: 0,
                rewardsUnlocked: 0,
                rewardsPaid: 0,
                evaluators: evaluators,
                initParams: bytes("")
            });
        }
    }

    function createTrancheProposal(uint256 dealId, uint256 trancheId) external {
        lastDealId = dealId;
        lastTrancheId = trancheId;
    }
}

contract MockDACCellForLib {
    address public dealManager;
    mapping(address => uint256) public deposited;

    constructor(address manager) {
        dealManager = manager;
    }

    function depositTreasury(address token, uint256 amount) external {
        ERC20(token).transferFrom(msg.sender, address(this), amount);
        deposited[token] += amount;
    }

    function getMainToken() external pure returns (address) {
        return address(0);
    }

    function getAgentToken() external pure returns (address) {
        return address(0);
    }

    function getDealManager() external view returns (address) {
        return dealManager;
    }
}

contract MockDealForLib is IDeal {
    ProposalParams public lastProposal;
    uint256 public proposalCalls;
    uint256 public beforeWithdrawCalls;
    uint256 public afterWithdrawCalls;
    uint256 public unstakeCalls;

    function approveToken(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }

    function getProposal(uint256) external pure returns (address) {
        return address(0);
    }

    function createStakedAgentProposal(ProposalParams calldata params) external returns (uint256 proposalId) {
        lastProposal = params;
        proposalId = ++proposalCalls;
    }

    function beforeInitialize(DealParams calldata, VotingConfig calldata) external pure {}
    function afterInitialize(DealParams calldata, VotingConfig calldata) external pure {}
    function onVoluntaryStake(address, uint256) external pure {}
    function beforeEveryStake(address, uint256) external pure {}
    function afterEveryStake(address, uint256) external pure {}
    function beforeApproveFunding(uint256) external pure {}
    function afterApproveFunding(uint256) external pure {}
    function onInvite(address, bool) external pure {}

    function onUnstake(address, uint256) external {
        unstakeCalls += 1;
    }

    function beforeWithdrawCapital() external {
        beforeWithdrawCalls += 1;
    }

    function afterWithdrawCapital() external {
        afterWithdrawCalls += 1;
    }

    function onMarkAsSuccess(uint256) external pure {}
    function onMarkAsFailed(uint256) external pure {}
    function onExtendDeadline(uint256, uint256) external pure {}
    function beforeClose() external pure {}
    function afterRecovery(address, uint256) external pure {}
    function beforeRecovery(address, uint256) external pure {}
    function beforeClaimMainToken(address, uint256) external pure {}
    function afterClaimMainToken(address, uint256) external pure {}
    function onMessageDeal(bytes4, bytes calldata) external pure returns (bool) { return true; }
    function onLegalWrapperMessage(address, bytes4, bytes calldata) external pure {}
}

contract CheckProposalCaller {
    function callCheck(
        address dealCell,
        ProposalParams calldata params,
        VotingConfig calldata votingConfig
    ) external view returns (bool) {
        return DealCellGovernanceLib.checkStakedAgentProposal(params, dealCell, votingConfig);
    }
}

contract DealCellGovernanceHarness is IDealCellGovernanceAdapter {
    address public manager;
    address public dacCell;

    MockDealForLib public dealContract;
    AgentToken public agentToken;
    StakedAgent public stakeTokenContract;

    bool public approved;
    bool public closed;
    bool public recovery;
    bool public earlyReturns;
    bool public vetoEnabled;

    uint256 public approveDeadlineValue;
    uint256 public dealDeadlineValue;

    address[] internal fundingTokensList;
    mapping(uint256 => Tranche) internal fundingTranchesMap;
    mapping(address => uint256) internal returnedCapital;
    mapping(address => uint256) internal investedCapital;
    address[] internal holders;

    uint256 public inviteCalls;

    constructor(address managerAddr, address dacCellAddr) {
        manager = managerAddr;
        dacCell = dacCellAddr;

        dealContract = new MockDealForLib();

        bytes memory agentInit = abi.encodeWithSelector(
            AgentToken.initialize.selector,
            address(this),
            "Harness Agent",
            "HAG"
        );
        agentToken = AgentToken(address(new UUPSProxy(address(new AgentToken()), agentInit)));
        agentToken.dacInit(managerAddr);

        bytes memory stakeInit = abi.encodeWithSelector(
            StakedAgent.initialize.selector,
            address(this),
            "Harness Stake",
            "HST"
        );
        stakeTokenContract = StakedAgent(address(new UUPSProxy(address(new StakedAgent()), stakeInit)));
    }

    function mintStake(address holder, uint256 amount) external {
        stakeTokenContract.mint(holder, amount);
    }

    function mintEscrowedAgent(uint256 amount) external {
        agentToken.mint(address(this), amount);
    }

    function setApproved(bool value) external {
        approved = value;
    }

    function setClosed(bool value) external {
        closed = value;
    }

    function setRecovery(bool value) external {
        recovery = value;
    }

    function setEarlyReturns(bool value) external {
        earlyReturns = value;
    }

    function setVetoEnabled(bool value) external {
        vetoEnabled = value;
    }

    function setDeadlines(uint256 approveDeadline_, uint256 dealDeadline_) external {
        approveDeadlineValue = approveDeadline_;
        dealDeadlineValue = dealDeadline_;
    }

    function pushFundingToken(address token) external {
        fundingTokensList.push(token);
    }

    function setFundingTranche(uint256 trancheId, address token, uint256 amount, bool settled) external {
        fundingTranchesMap[trancheId] = Tranche({
            token: token,
            amount: amount,
            settled: settled
        });
    }

    function pushHolder(address holder) external {
        holders.push(holder);
    }

    function callCheckStakedAgentProposal(
        ProposalParams calldata params,
        VotingConfig calldata votingConfig
    ) external view returns (bool) {
        return DealCellGovernanceLib.checkStakedAgentProposal(params, address(this), votingConfig);
    }

    function callApproveFunding(uint256 dealId, uint256 trancheId) external {
        DealCellGovernanceLib.approveFunding(
            dacCell,
            dealId,
            trancheId,
            approved,
            approveDeadlineValue,
            IDeal(address(dealContract)),
            fundingTranchesMap,
            investedCapital
        );
    }

    function callWithdrawCapital(uint256 dealId) external {
        DealCellGovernanceLib.withdrawCapital(
            dealId,
            earlyReturns,
            dacCell,
            dealDeadlineValue,
            stakeTokenContract,
            IDeal(address(dealContract)),
            fundingTokensList,
            returnedCapital
        );
    }

    function callUnstakeAgent(uint256 dealId) external {
        DealCellGovernanceLib.unstakeAgent(
            dacCell,
            dealId,
            IDeal(address(dealContract)),
            closed,
            approved,
            recovery,
            approveDeadlineValue,
            address(agentToken),
            stakeTokenContract
        );
    }

    function callWhitelistHolders() external {
        DealCellGovernanceLib.whitelistHolders(holders);
    }

    function invite(address, bool) external {
        inviteCalls += 1;
    }

    function deal() external view returns (IDeal) {
        return IDeal(address(dealContract));
    }

    function name() external pure returns (string memory) { return "Harness"; }
    function description() external pure returns (string memory) { return "Harness"; }
    function startTime() external view returns (uint256) { return block.timestamp; }
    function stakeToken() external view returns (address) { return address(stakeTokenContract); }
    function claimMainToken(uint256) external pure {}
    function unstake() external pure {}
    function fundingTranche(uint256 trancheId) external view returns (Tranche memory tranche) { tranche = fundingTranchesMap[trancheId]; }
    function fundingTokens() external view returns (address[] memory) { return fundingTokensList; }
    function getReturnedCapital(address token) external view returns (uint256) { return returnedCapital[token]; }
    function getInvestedCapital(address token) external view returns (uint256) { return investedCapital[token]; }
    function getMainRewardsLimit() external pure returns (uint256) { return 0; }
    function rewardsConvertedPct() external pure returns (uint256) { return 0; }
    function allowEarlyReturns() external view returns (bool) { return earlyReturns; }
    function allowDACVeto() external view returns (bool) { return vetoEnabled; }
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external view returns (bool) { return approved; }
    function isClosed() external view returns (bool) { return closed; }
    function approveDeadline() external view returns (uint256) { return approveDeadlineValue; }
    function dealDeadline() external view returns (uint256) { return dealDeadlineValue; }
}

contract DealCellGovernanceLibBranchTest is Test {
    DealCellGovernanceHarness internal harness;
    MockDealManagerForLib internal manager;
    MockDACCellForLib internal dacCell;
    CheckProposalCaller internal caller;
    LibTestToken internal fundingToken;

    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal outsider = makeAddr("outsider");

    VotingConfig internal votingConfig;

    function setUp() public {
        manager = new MockDealManagerForLib();
        dacCell = new MockDACCellForLib(address(manager));
        caller = new CheckProposalCaller();
        harness = new DealCellGovernanceHarness(address(manager), address(dacCell));
        fundingToken = new LibTestToken("Funding Token", "FUND");

        manager.configure(address(harness), address(harness.dealContract()));

        votingConfig = VotingConfig({
            quorumPercent: MathLib.atScale(50),
            blockingPercent: MathLib.atScale(25),
            highQuorumPercent: MathLib.atScale(80),
            duration: 7 days,
            qualification: 10
        });

        harness.setApproved(true);
        harness.setDeadlines(block.timestamp + 1 days, block.timestamp + 30 days);
    }

    function test_checkProposal_revertsForOutsiderWithoutStake() public {
        ProposalParams memory params = ProposalParams({
            typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS,
            target: address(0),
            i: 0,
            data: abi.encode(true)
        });

        vm.expectRevert(DACErrorsLib.NotStakedAgent.selector);
        vm.prank(outsider);
        harness.callCheckStakedAgentProposal(params, votingConfig);
    }

    function test_checkProposal_agentCannotDirectlyCreateSpecialProposal() public {
        harness.mintStake(agent, 100);

        ProposalParams memory params = ProposalParams({
            typ: AbstractDealManagementType.PERMIT_UNSTAKE,
            target: agent,
            i: 0,
            data: bytes("")
        });

        vm.expectRevert(DACErrorsLib.ProposalNotSupported.selector);
        vm.prank(agent);
        harness.callCheckStakedAgentProposal(params, votingConfig);
    }

    function test_checkProposal_managerOnlySupportsPermitEvaluatorAdd() public {
        ProposalParams memory okParams = ProposalParams({
            typ: AbstractDealManagementType.PERMIT_EVALUATOR_ADD,
            target: address(0),
            i: 0,
            data: bytes("")
        });

        vm.prank(address(manager));
        assertTrue(harness.callCheckStakedAgentProposal(okParams, votingConfig));

        ProposalParams memory badParams = ProposalParams({
            typ: AbstractDealManagementType.REQUEST_TRANCHE,
            target: address(fundingToken),
            i: bytes32(uint256(100)),
            data: bytes("")
        });

        vm.expectRevert(DACErrorsLib.ProposalNotSupported.selector);
        vm.prank(address(manager));
        harness.callCheckStakedAgentProposal(badParams, votingConfig);
    }

    function test_checkProposal_dealCellOnlySupportsPermitUnstake() public {
        ProposalParams memory okParams = ProposalParams({
            typ: AbstractDealManagementType.PERMIT_UNSTAKE,
            target: agent,
            i: 0,
            data: bytes("")
        });

        vm.prank(address(harness));
        assertTrue(caller.callCheck(address(harness), okParams, votingConfig));

        ProposalParams memory badParams = ProposalParams({
            typ: AbstractDealManagementType.PERMIT_EVALUATOR_ADD,
            target: address(0),
            i: 0,
            data: bytes("")
        });

        vm.expectRevert(DACErrorsLib.ProposalNotSupported.selector);
        vm.prank(address(harness));
        caller.callCheck(address(harness), badParams, votingConfig);
    }

    function test_checkProposal_unapprovedDealRejectsRequestTranche() public {
        harness.setApproved(false);
        harness.mintStake(agent, 100);

        ProposalParams memory params = ProposalParams({
            typ: AbstractDealManagementType.REQUEST_TRANCHE,
            target: address(fundingToken),
            i: bytes32(uint256(100)),
            data: bytes("")
        });

        vm.expectRevert(DACErrorsLib.DealIsNotApproved.selector);
        vm.prank(agent);
        harness.callCheckStakedAgentProposal(params, votingConfig);
    }

    function test_checkProposal_rejectsInvalidVotingConfig() public {
        harness.mintStake(agent, 100);

        VotingConfig memory invalidConfig = VotingConfig({
            quorumPercent: MathLib.SCALE + 1,
            blockingPercent: MathLib.atScale(25),
            highQuorumPercent: MathLib.atScale(80),
            duration: 7 days,
            qualification: 10
        });

        ProposalParams memory params = ProposalParams({
            typ: AbstractDealManagementType.UPDATE_VOTING_CONFIG,
            target: address(0),
            i: 0,
            data: abi.encode(invalidConfig)
        });

        vm.expectRevert(DACErrorsLib.InvalidVotingConfig.selector);
        vm.prank(agent);
        harness.callCheckStakedAgentProposal(params, votingConfig);
    }

    function test_approveFunding_revertsWhenTrancheZeroExpired() public {
        harness.setApproved(false);
        harness.setDeadlines(block.timestamp - 1, block.timestamp + 30 days);
        harness.setFundingTranche(0, address(fundingToken), 1_000, false);

        vm.expectRevert(DACErrorsLib.DeadlineNotPassed.selector);
        harness.callApproveFunding(1, 0);
    }

    function test_approveFunding_revertsForMissingAndSettledTranches() public {
        vm.expectRevert(DACErrorsLib.TrancheNotExists.selector);
        harness.callApproveFunding(1, 7);

        harness.setFundingTranche(2, address(fundingToken), 500, true);

        vm.expectRevert(DACErrorsLib.TrancheAlreadySettled.selector);
        harness.callApproveFunding(1, 2);
    }

    function test_withdrawCapital_revertsForNonStakedCaller() public {
        harness.pushFundingToken(address(fundingToken));

        vm.expectRevert(DACErrorsLib.NotStakedAgent.selector);
        vm.prank(outsider);
        harness.callWithdrawCapital(1);
    }

    function test_withdrawCapital_revertsBeforeDeadlineWithoutEarlyReturns() public {
        harness.pushFundingToken(address(fundingToken));
        harness.mintStake(agent, 100);

        vm.expectRevert(DACErrorsLib.DeadlineNotPassed.selector);
        vm.prank(agent);
        harness.callWithdrawCapital(1);
    }

    function test_withdrawCapital_stakedAgentCanWithdrawWithEarlyReturns() public {
        harness.pushFundingToken(address(fundingToken));
        harness.setEarlyReturns(true);
        harness.mintStake(agent, 100);

        fundingToken.mint(address(harness.dealContract()), 700);
        harness.dealContract().approveToken(address(fundingToken), address(harness), 700);

        vm.prank(agent);
        harness.callWithdrawCapital(1);

        assertEq(harness.getReturnedCapital(address(fundingToken)), 700);
        assertEq(dacCell.deposited(address(fundingToken)), 700);
        assertEq(harness.dealContract().beforeWithdrawCalls(), 1);
        assertEq(harness.dealContract().afterWithdrawCalls(), 1);
    }

    function test_withdrawCapital_managerCanWithdrawAfterDeadline() public {
        harness.pushFundingToken(address(fundingToken));
        harness.setDeadlines(block.timestamp + 1 days, block.timestamp - 1);

        fundingToken.mint(address(harness.dealContract()), 900);
        harness.dealContract().approveToken(address(fundingToken), address(harness), 900);

        vm.prank(address(manager));
        harness.callWithdrawCapital(1);

        assertEq(harness.getReturnedCapital(address(fundingToken)), 900);
        assertEq(dacCell.deposited(address(fundingToken)), 900);
    }

    function test_unstakeAgent_approvedDealCreatesPermitProposal() public {
        harness.mintStake(agent, 100);
        harness.mintStake(agent2, 100);

        vm.prank(agent);
        harness.callUnstakeAgent(1);

        assertEq(harness.dealContract().proposalCalls(), 1);

        (
            bytes4 typ,
            address target,
            bytes32 amount,
            bytes memory data
        ) = harness.dealContract().lastProposal();

        assertEq(typ, AbstractDealManagementType.PERMIT_UNSTAKE);
        assertEq(target, agent);
        assertEq(uint256(amount), 100);
        assertEq(abi.decode(data, (uint256)), 0);
    }

    function test_unstakeAgent_closedDealReleasesPrincipal() public {
        harness.setClosed(true);
        harness.mintStake(agent, 150);
        harness.mintEscrowedAgent(150);

        vm.prank(agent);
        harness.callUnstakeAgent(1);

        assertEq(harness.stakeTokenContract().balanceOf(agent), 0);
        assertEq(harness.agentToken().balanceOf(agent), 150);
        assertEq(harness.dealContract().unstakeCalls(), 1);
    }

    function test_unstakeAgent_recoveryBlocksExitAfterClose() public {
        harness.setClosed(true);
        harness.setRecovery(true);
        harness.mintStake(agent, 150);

        vm.expectRevert(DACErrorsLib.DealInLiquidation.selector);
        vm.prank(agent);
        harness.callUnstakeAgent(1);
    }

    function test_whitelistHolders_invitesEachHistoricalHolder() public {
        harness.pushHolder(agent);
        harness.pushHolder(agent2);

        harness.callWhitelistHolders();

        assertEq(harness.inviteCalls(), 2);
    }
}
