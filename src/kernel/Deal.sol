// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/Structs.sol";
import "../interfaces/IDealCell.sol";
import "../interfaces/IDealManager.sol";
import "../interfaces/IDACCellAdapter.sol";
import "../interfaces/IDeal.sol";
import "../interfaces/IDealAdmin.sol";
import "../interfaces/IDealManagementProposalFactory.sol";
import "./interfaces/IDealCellAdapter.sol";
import "./tokens/MainToken.sol";
import "./tokens/AgentToken.sol";
import "./tokens/StakedAgent.sol";
import "./libraries/DealCellGovernance.sol";
import "./governance/DealManagementProposal.sol";
import "./governance/AbstractDealManagementProposals.sol";

abstract contract Deal is IDeal, ReentrancyGuard {

    error NotAuthorized();
    error AlreadyInitialized();

    error DeadlineNotPassed();
    error DealAlreadyApproved();
    error NotWhitelistedAgent();

    error NotStakedAgent();

    error NotWhitelistDeal();
    error DealIsNotApproved();
    error DealIsClosed();
    error DealIsNotClosed();
    error DealInLiquidation();

    error InvalidTranche();

    error NoStake();
    error NoClaimableRewards();
    error InsufficientRewards();

    error NotEnoughBalance();

    error TrancheNotExists();
    error TrancheAlreadySettled();
    error TransferFailed();
    
    error ProposalNotSupported();
    error InvalidProposal();
    error AlreadyExecuted();

    error MessageNotAccepted();

    error VoteNotPassed();

    address private immutable factory;
    
    uint256 internal immutable id;
    address internal immutable dacCell;
    address internal immutable governanceFactory;

    address internal dealCell;

    address internal immutable agentTokenAddr;
    address internal immutable mainTokenAddr;

    address private immutable proposer;

    address internal managedEntity;

    // Entities in the DAC paradigm are analogue of the "balance sheets"
    // Can store and manage capital on long term basis.
    // While Deal can have capital on it's "contract balance", Deal is not a storage
    // for it, and only escrow capital within the Deal logic.

    // Link with document management system
    string public linkHash;

    // Deal state
    bool internal approved;
    bool internal closed;
    bool internal recovery;
    bool internal earlyReturns;

    // Governance
    uint256 private nextId = 1;
    mapping(uint256 => address) private proposals;
    mapping(uint256 => bool) private executed;

    VotingConfig private _votingConfig;
    
    // Global events, indexed by DAC and deal id
    event DealInitialized(address indexed dac, uint256 indexed id, DealParams params);
    event AgentTokensStaked(address indexed dac, uint256 indexed id, address indexed agent, uint256 amount);
    event AgentTokensReleased(address indexed dac, uint256 indexed id, address indexed agent, uint256 amount);
    event DealActivated(address indexed dac, uint256 indexed id, uint256 totalAgentTokens);
    event TrancheRequested(address indexed dac, uint256 indexed id, uint256 tranche, address token, uint256 amount);
    event RewardsAllocated(address indexed dac, uint256 indexed id, uint256 reward);
    event StakesSlashed(address indexed dac, uint256 indexed id, uint256 slashAmount);
    event RewardsClaimed(address indexed dac, address indexed agent, uint256 amount);
    event CapitalReturned(address indexed dac, uint256 indexed id, address token, uint256 amount);
    event DeadlineExtended(address indexed dac, uint256 indexed id, uint256 newDeadline);
    event DealClosed(address indexed dac, uint256 indexed id, uint256 totalAgentTokens);
    event DealRecovered(address indexed dac, uint256 indexed id, address liquidator);
    
    // Deal specific events, indexed by Deal address, proposal id, or agent
    event MessageReceived(bytes4 messageKind, bytes message);
    event LegalWrapperMessageReceived(address indexed wrapper, bytes4 messageKind, bytes message);
    event Invited(address indexed invitee, bool canInvite);
    
    event DealManagementProposalCreated(uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);
    event DealManagementProposalExecuted(uint256 indexed id, bytes4 indexed typ);
    event VotingConfigUpdate(uint256 indexed id, VotingConfig config);
    event EarlyReturnsToggled(uint256 indexed id, bool enabled);

    constructor(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _agentToken,
        address _mainToken,
        address _proposer
    ) {
        factory = msg.sender;
        id = _id;
        governanceFactory = _governanceFactory;
        dacCell = _dac;
        agentTokenAddr = _agentToken;
        mainTokenAddr = _mainToken;
        proposer = _proposer;
    }

    function initialize(
        address _dealCell
    ) external {
        dealCell = _dealCell;
    }

    function _beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) internal virtual {}
    function beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external onlyDealCell {
        _beforeInitialize(params, defaultVotingConfig);
    }

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) internal virtual {}
    function afterInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external onlyDealCell {
        _afterInitialize(params, defaultVotingConfig);
    }
 
    function _onVoluntaryStake(address staker, uint256 amount) internal virtual {}
    function onVoluntaryStake(address staker, uint256 amount) external onlyDealCell {
        _onVoluntaryStake(staker, amount);
    }

    function _beforeEveryStake(address staker, uint256 amount) internal virtual {}
    function beforeEveryStake(address staker, uint256 amount) external onlyDealCell {
        _beforeEveryStake(staker, amount);
    }

    function _afterEveryStake(address staker, uint256 amount) internal virtual {}
    function afterEveryStake(address staker, uint256 amount) external onlyDealCell {
        _afterEveryStake(staker, amount);
    }

    function _beforeApprove(uint256 trancheId) internal virtual {}
    function beforeApproveFunding(uint256 trancheId) external onlyDealCell {
        _beforeApprove(trancheId);
    }
    
    function _afterApprove(uint256 trancheId) internal virtual {}
    function afterApproveFunding(uint256 trancheId) external onlyDealCell {
        _afterApprove(trancheId);
    }

    function _afterInvite(address invitee, bool grantInviteRight) internal virtual {}
    function onInvite(address invitee, bool grantInviteRight) external onlyDealCell {
        _afterInvite(invitee, grantInviteRight);
    }

    function _afterUnstake(address staker, uint256 amount) internal virtual {}
    function onUnstake(address staker, uint256 amount) external onlyDealCell {
        _afterUnstake(staker, amount);
    }

    function _beforeWithdrawCapital() internal virtual {}
    function beforeWithdrawCapital() external onlyDealCell {
        _beforeWithdrawCapital();
        DealCellGovernance.prepareWithdrawal(dealCell);
    }

    function _afterWithdrawCapital() internal virtual {}
    function afterWithdrawCapital() external onlyDealCell {
        _afterWithdrawCapital();
    }

    function _beforeMarkAsSuccess(uint256 rewardPercent) internal virtual {}
    function onMarkAsSuccess(uint256 rewardPercent) external onlyDealCell {
        _beforeMarkAsSuccess(rewardPercent);
    }

    function _afterMarkAsFailed(uint256 slashPercent) internal virtual {}
    function onMarkAsFailed(uint256 slashPercent) external onlyDealCell {
        _afterMarkAsFailed(slashPercent);
    }

    function _beforeExtendDeadline(uint256 oldDeadline, uint256 newDeadline) internal virtual {}
    function onExtendDeadline(uint256 oldDeadline, uint256 newDeadline) external onlyDealCell {
        _beforeExtendDeadline(oldDeadline, newDeadline);
    }

    function _beforeClose() internal virtual {}
    function beforeClose() external onlyDealCell {
        _beforeClose();
    }

    function _beforeRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}
    function beforeRecovery(address liquidator, uint256 liquidatorStake) external onlyDealCell {
        _beforeRecovery(liquidator, liquidatorStake);
    }

    function _afterRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}
    function afterRecovery(address liquidator, uint256 liquidatorStake) external onlyDealCell {
        _afterRecovery(liquidator, liquidatorStake);
    }

    function _beforeClaimMainToken(address grantee, uint256 amount) internal virtual {}
    function beforeClaimMainToken(address grantee, uint256 amount) external onlyDealCell {
        _beforeClaimMainToken(grantee, amount);
    }

    function _afterClaimMainToken(address grantee, uint256 amount) internal virtual {}
    function afterClaimMainToken(address grantee, uint256 amount) external onlyDealCell {
        _afterClaimMainToken(grantee, amount);
    }

    function _beforeCreateProposal(ProposalParams calldata params) internal virtual {}
    function _afterCreateProposal(uint256 proposalId, ProposalParams calldata params) internal virtual {}

    function createStakedMPProposal(ProposalParams calldata params) external returns (uint256 proposalId) {
        if (msg.sender != address(this)) {
            _onlyStakedMPHolder();

            require(
                IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > votingConfig().qualification,
                NotEnoughBalance()
            );
        }

        _beforeCreateProposal(params);

        if (!approved) {
            require(
                (
                    params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
                    params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
                    params.typ == AbstractDealManagementType.TOGGLE_WHITELIST
                ),
                DealIsNotApproved()
            );
        }

        if (!(
            params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
            params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
            params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
            params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
            params.typ == AbstractDealManagementType.ADD_STAKE
        )) {
            // If type is not a basic Deal governance type, requiering derived contracts to validate
            require(
                _checkStackedMPProposalSupported(params),
                ProposalNotSupported()
            );
        }

        proposalId = nextId++;

        address prop = IDealManagementProposalFactory(governanceFactory).deployProposal(
            proposalId,
            params,
            address(this),
            address(this),
            _votingConfig
        );

        proposals[proposalId] = prop;

        emit DealManagementProposalCreated(proposalId, params.typ, params.target, params.i, params.data);

        _afterCreateProposal(proposalId, params);
    }

    function _checkStackedMPProposalSupported(ProposalParams calldata) internal virtual returns (bool supported) {
        // Concrete Deal implementation overrides this to indicate if the governance proposal is supported
        supported = false;
    }

    function _beforeExecuteProposal(uint256 proposalId) internal virtual {}
    function _afterExecuteProposal(uint256 proposalId) internal virtual {}

    function executeStakedMPProposal(uint256 proposalId) external onlyAfterStakedMPVote(proposalId) {
        require(!executed[id], AlreadyExecuted());
        executed[id] = true;

        _beforeExecuteProposal(proposalId);

        address prop = proposals[proposalId];
        bytes4 typ = DealManagementProposal(prop).typ();

        if (typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG) {
            _votingConfig = abi.decode(
                DealManagementProposal(prop).data(), 
                (VotingConfig)
            );

            emit VotingConfigUpdate(proposalId, _votingConfig);
        }

        else if (typ == AbstractDealManagementType.REQUEST_TRANCHE) {
            IDealCellAdapter(dealCell).requestTranche(DealManagementProposal(prop));
        }

        else if (typ == AbstractDealManagementType.ADD_STAKE) {
            address staker = DealManagementProposal(prop).target();
            uint256 stakeAmount = uint256(DealManagementProposal(prop).i());
            
            IDealCellAdapter(dealCell).addStake(staker, stakeAmount);
        }

        else if (typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS) {
            earlyReturns = abi.decode(DealManagementProposal(prop).data(), (bool));

            emit EarlyReturnsToggled(proposalId, earlyReturns);
        }

        else if (typ == AbstractDealManagementType.TOGGLE_WHITELIST) {
            IDealCellAdapter(dealCell).toggleWhitelist(
                abi.decode(DealManagementProposal(prop).data(), (bool))
            );
        }

        else {
            // Forward to module for specific types
            _executeModuleManagementProposal(DealManagementProposal(prop));
        }
        
        emit DealManagementProposalExecuted(proposalId, typ);

        _afterExecuteProposal(proposalId);
    }

    function _executeModuleManagementProposal(DealManagementProposal) internal virtual {
        // Children override this to handle their specific proposals
        require(false, ProposalNotSupported());
    }

    function _onMessageDeal(bytes4, bytes calldata) internal virtual returns (bool) { return true; }
    function onMessageDeal(bytes4 message, bytes calldata data) external onlyDealCell returns (bool) {
        return _onMessageDeal(message, data);
    }
    
    function _onLegalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) internal virtual {}
    function onLegalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external onlyDealCell {
        _onLegalWrapperMessage(legalWrapper, messageKind, message);
    }

    function getCell() external view returns (address) { return dealCell; }
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external view returns (bool) { return approved; }
    function isClosed() external view returns (bool) { return closed; }

    function getProposal(uint256 proposalId) public view returns (address) {
        require(proposals[proposalId] != address(0), InvalidProposal());
        return proposals[proposalId];
    }

    function votingConfig() public view returns (VotingConfig memory) { return _votingConfig; }

    modifier onlyDealCell() {
        _onlyDealCell();
        _;
    }

    modifier onlyStakedMPHolder() {
        _onlyStakedMPHolder();
        _;
    }

    modifier onlyAfterStakedMPVote(uint256 proposalId) {
        _onlyAfterStakedMPVote(proposalId);
        _;
    }

    function _onlyDealCell() internal view {
        require(msg.sender == dealCell, NotAuthorized());
    }

    function _onlyStakedMPHolder() internal view {
        require(IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > 0, NoStake());
    }
    
    function _onlyAfterStakedMPVote(uint256 proposalId) internal view {
        require(
            IVoting(proposals[proposalId]).isResolved() &&
            IVoting(proposals[proposalId]).outcome(),
            VoteNotPassed()
        );
    }
}
