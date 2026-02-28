// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DealParams, VotingConfig} from "../interfaces/Structs.sol";
import {IVoting} from "../interfaces/IVoting.sol";
import {IDACCellAdapter} from "../interfaces/IDACCellAdapter.sol";
import {IDealManagerAdapter} from "./interfaces/IDealManagerAdapter.sol";
import {IDeal} from "../interfaces/IDeal.sol";
import {IDealAdmin} from "../interfaces/IDealAdmin.sol";
import {IDealCell} from "../interfaces/IDealCell.sol";
import {Tranche} from "./interfaces/Structs.sol";
import {StakedAgent} from "./tokens/StakedAgent.sol";
import {StakedAgentLib} from "./tokens/factories/TokenFactories.sol";
import {DealManagementProposal} from "./governance/DealManagementProposal.sol";
import {DealCellGovernanceLib} from "./libraries/DealCellGovernanceLib.sol";

contract DealCell is IDealCell, IDealAdmin, ReentrancyGuard {

    error NotAuthorized();
    error AlreadyInitialized();

    error DeadlineNotPassed();
    error DealAlreadyApproved();
    error NotWhitelistedAgent();

    error NotWhitelistDeal();
    error DealIsNotApproved();
    error DealIsClosed();
    error DealIsNotClosed();
    error DealInLiquidation();

    error InvalidTranche();

    error NoStake();
    
    error NotEnoughBalance();

    error TransferFailed();
    
    error ProposalNotSupported();
    error InvalidProposal();
    error AlreadyExecuted();

    error MessageNotAccepted();

    error VoteNotPassed();

    address private immutable factory;

    address public immutable manager;
    
    uint256 internal immutable id;
    address internal immutable dacCell;
    address internal immutable governanceFactory;
    
    address internal immutable agentTokenAddr;
    address internal immutable mainTokenAddr;

    address private immutable proposer;

    IDeal public deal;
    address internal managedEntity;

    StakedAgent internal token; 

    // Entities in the DAC paradigm are analogue of the "balance sheets"
    // Can store and manage capital on long term basis.
    // While Deal can have capital on it's "contract balance", Deal is not a storage
    // for it, and only escrow capital within the Deal logic.
    
    uint256 internal _tokenRewardsLimit;
    
    uint256 internal startTime;
    uint256 internal _approveDeadline;
    uint256 internal _dealDeadline;

    // Link with document management system
    string public linkHash;

    // Funding
    address[] internal _fundingTokens;
    mapping(address => uint256) internal _requestedFunding;

    // Tranches indexed by proposalId
    mapping(uint256 => Tranche) internal _fundingTranches;

    // Deal state
    bool internal approved;
    bool internal closed;
    bool internal recovery;

    bool internal vetoEnabled;
    bool internal earlyReturns;
    bool internal isWhitelistOnly; 
    
    // General metrics for abstract Deal
    uint256 internal rewardsConverted;

    // Indexed by funding token
    mapping(address => uint256) internal investedCapital;
    mapping(address => uint256) internal returnedCapital;

    // Rewards unlocked
    mapping(address => uint256) internal claimableRewards;

    // Whitelist
    mapping(address => bool) internal isWhitelisted;
    mapping(address => bool) internal canInviteOthers;

    address[] internal holders; // only for claimable tracking

    // Governance
    VotingConfig private _votingConfig;
    
    // Global events, indexed by DAC and deal id
    event DealInitialized(address indexed dac, uint256 indexed id, DealParams params);
    event DealActivated(address indexed dac, uint256 indexed id, uint256 totalAgentTokens);
    event TrancheRequested(address indexed dac, uint256 indexed id, uint256 tranche, address token, uint256 amount);
    
    event CapitalReturned(address indexed dac, uint256 indexed id, address token, uint256 amount);
    event DeadlineExtended(address indexed dac, uint256 indexed id, uint256 newDeadline);
    event DealClosed(address indexed dac, uint256 indexed id, uint256 totalAgentTokens);
    event DealRecovered(address indexed dac, uint256 indexed id, address liquidator);
    
    // Deal specific events, indexed by Deal address, proposal id, or agent
    event MessageReceived(bytes4 messageKind, bytes message);
    event LegalWrapperMessageReceived(address indexed wrapper, bytes4 messageKind, bytes message);
    event Invited(address indexed invitee, bool canInvite);
    
    event EarlyReturnsToggled(uint256 indexed id, bool enabled);
    event VetoRightEnabled(uint256 indexed id);

    constructor(
        uint256 _id,
        address _dac,
        address _dealManager,
        address _governanceFactory,
        address _agentToken,
        address _mainToken,
        address _proposer
    ) {
        factory = msg.sender;
        id = _id;
        governanceFactory = _governanceFactory;
        dacCell = _dac;
        manager = _dealManager;
        agentTokenAddr = _agentToken;
        mainTokenAddr = _mainToken;
        proposer = _proposer;
    }

    function initialize(
        address _deal,
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external {
        require(msg.sender == factory, NotAuthorized());
        require(startTime == 0, AlreadyInitialized());

        deal = IDeal(_deal);

        token = StakedAgent(StakedAgentLib.deployStakedAgentToken(
            address(this),
            params.name,
            ERC20(agentTokenAddr).symbol()
        ));

        startTime = block.timestamp;

        linkHash = params.linkHash;

        _tokenRewardsLimit = params.rewardsLimit;
        _approveDeadline = params.approveDeadline;
        _dealDeadline = params.dealDeadline;

        if (params.fundingAmount > 0) {
            if (_requestedFunding[params.fundingToken] == 0) {
                _fundingTokens.push(params.fundingToken);
            }
            _requestedFunding[params.fundingToken] = params.fundingAmount;
        }

        _fundingTranches[0] = Tranche({
            token: params.fundingToken,
            amount: params.fundingAmount,
            settled: false
        });

        vetoEnabled = params.vetoEnabled;

        isWhitelistOnly = true;
        isWhitelisted[proposer] = true;
        canInviteOthers[proposer] = true;

        emit Invited(proposer, true);

        deal.beforeInitialize(params, defaultVotingConfig);
    }
 
    function onDACInit(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external onlyDealManager {
        emit DealInitialized(dacCell, id, params);

        deal.afterInitialize(params, defaultVotingConfig);
    }

    function registerControlledAddress(address controlled) external onlyDeal {
        IDealManagerAdapter(manager).registerControlledAddress(controlled);
    }

    function stake(address staker, uint256 amount) internal {
        DealCellGovernanceLib.stake(
            dacCell,
            staker,
            amount,
            id,
            deal,
            token,
            holders
        );
    }

    function onAgentTokenStaked(address staker, uint256 amount) external {
        require(msg.sender == agentTokenAddr || msg.sender == dacCell, NotAuthorized());

        // if the deal is approved no more direct stakes allowed
        require(!approved, DealAlreadyApproved());

        if (isWhitelistOnly) {
            require(isWhitelisted[staker], NotWhitelistedAgent());
        }

        stake(staker, amount);

        deal.onVoluntaryStake(staker, amount);
    }

    function approveFunding(uint256 trancheId) external onlyDealManager {
        deal.beforeApproveFunding(trancheId);

        DealCellGovernanceLib.approveFunding(
            trancheId,
            approved,
            _approveDeadline,
            deal,
            _fundingTranches,
            investedCapital
        );

        if (!approved) {
            approved = true;
        
            emit DealActivated(dacCell, id, token.totalSupply());
        }

        deal.afterApproveFunding(trancheId);
    }

    function invite(address invitee, bool grantInviteRight) external nonReentrant {
        require(isWhitelistOnly, NotWhitelistDeal());

        if (msg.sender != address(this)) {
            require(isWhitelisted[msg.sender] && canInviteOthers[msg.sender], NotAuthorized());
        }
        
        if(!isWhitelisted[invitee]) {
            isWhitelisted[invitee] = true;
            canInviteOthers[invitee] = grantInviteRight;
            
            emit Invited(invitee, grantInviteRight);

            deal.onInvite(invitee, grantInviteRight);
        }   
    }

    function unstake() external nonReentrant {
        // allow to unstake if the deal is closed
        if (!closed) {
            // of if the deal is not approved within deadline
            require(!approved || (block.timestamp > _approveDeadline), DeadlineNotPassed());
        }
        else {
            // if the recovery is on, no more unstakes
            require(!recovery, DealInLiquidation());
        }
        
        DealCellGovernanceLib.unstake(
            dacCell,
            id,
            deal,
            agentTokenAddr,
            token
        );
    }

    function requestTranche(
        DealManagementProposal prop
    ) external onlyDeal {
        DealCellGovernanceLib.requestTranche(
            id,
            dacCell,
            prop,
            _fundingTranches,
            _fundingTokens,
            _requestedFunding
        );
    }

    function transferCapital(address _token, uint256 amount) external onlyDeal {
        require(IERC20(_token).transferFrom(address(deal), address(this), amount), TransferFailed());

        DealCellGovernanceLib.transferCapital(
            id,
            _token,
            amount,
            dacCell,
            returnedCapital
        );
    }

    function withdrawCapital() external nonReentrant {
        DealCellGovernanceLib.withdrawCapital(
            id,
            earlyReturns,
            dacCell,
            _dealDeadline,
            token,
            deal,
            _fundingTokens,
            returnedCapital
        );
    }

    function markAsSuccess(uint256 rewardPercent) external onlyDealManager {
        require(!closed, DealIsClosed());
        
        DealCellGovernanceLib.markAsSuccess(
            rewardPercent,
            id,
            dacCell,
            token,
            deal,
            rewardsConverted,
            _tokenRewardsLimit,
            holders,
            claimableRewards,
            address(this)
        );
    }

    function markAsFailed(uint256 slashPercent) external onlyDealManager {
        require(!closed, DealIsClosed());

        DealCellGovernanceLib.markAsFailed(
            slashPercent,
            id,
            dacCell,
            token,
            deal,
            holders
        );
    }

    function extendDeadline(uint256 newDeadline) external onlyDealManager {
        require(!closed, DealIsClosed());
        
        deal.onExtendDeadline(_dealDeadline, newDeadline);

        _dealDeadline = newDeadline;
        
        emit DeadlineExtended(dacCell, id, newDeadline);
    }

    function closeDeal() external {
        require(msg.sender == address(this) || msg.sender == dacCell, NotAuthorized());
        require(!closed, DealIsClosed());
        
        deal.beforeClose();

        closed = true;
        
        emit DealClosed(dacCell, id, token.totalSupply());
    }

    function recoverDeal(address liquidator, uint256 liquidatorStake) external onlyDealManager {
        require(closed, DealIsNotClosed());
        
        deal.beforeRecovery(liquidator, liquidatorStake);

        recovery = true;

        stake(liquidator, liquidatorStake);
        
        emit DealRecovered(dacCell, id, liquidator);

        deal.afterRecovery(liquidator, liquidatorStake);
    }

    function claimMainToken() external nonReentrant {
        DealCellGovernanceLib.claimMainToken(
            dacCell,
            deal,
            claimableRewards
        );
    }

    function toggleWhitelist(bool whitelistOnly) external onlyDeal {
        if (isWhitelistOnly != whitelistOnly) {
            isWhitelistOnly = whitelistOnly;
            
            if (isWhitelistOnly) {
                // Inviting all existing manager with invite capability
                for (uint256 i = 0; i < holders.length; i++) {
                    address agent = holders[i];
                    this.invite(agent, true);
                }
            }
        }
    }

    function toggleEarlyReturns(uint256 propId, bool _ealryReturns) external onlyDeal {
        earlyReturns = _ealryReturns;

        emit EarlyReturnsToggled(propId, earlyReturns);
    }

    function enableVeto() external onlyDeal {
        if (!vetoEnabled) {
            vetoEnabled = true;

            emit VetoRightEnabled(id);
        }
    }

    function addStake(address staker, uint256 amount) external onlyDeal {
        // if the deal is not approved adding stakes not allowed
        require(approved, DealIsNotApproved());

        require(
            IERC20(agentTokenAddr).transferFrom(staker, address(this), amount),
            TransferFailed()
        );

        stake(staker, amount);
    }
    
    function messageDeal(bytes4 messageKind, bytes calldata message) external onlyDealManager {
        require(
            deal.onMessageDeal(messageKind, message), 
            MessageNotAccepted()
        );

        emit MessageReceived(messageKind, message);
    }

    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external onlyDealManager {
        deal.onLegalWrapperMessage(legalWrapper, messageKind, message);
        
        emit LegalWrapperMessageReceived(legalWrapper, messageKind, message);
    }

    function approveDeadline() external view returns (uint256) { return _approveDeadline; }
    function dealDeadline() external view returns (uint256) { return _dealDeadline; }
    function stakeToken() external view returns (address) { return address(token); }
    function getStakedAgentTotal() external view returns (uint256) { return token.totalSupply(); }
    function getReturnedCapital(address _fundingToken) external view returns (uint256) { return returnedCapital[_fundingToken]; }
    function getInvestedCapital(address _fundingToken) external view returns (uint256) { return investedCapital[_fundingToken]; }
    function getMainRewardsLimit() external view returns (uint256) { return _tokenRewardsLimit; }
    
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external view returns (bool) { return approved; }
    function isClosed() external view returns (bool) { return closed; }

    function allowEarlyReturns() external view returns (bool) { return earlyReturns; }
    function allowDACVeto() external view returns (bool) { return vetoEnabled; }

    function fundingTokens() public view returns (address[] memory) {
        return _fundingTokens;
    }
    function fundingSettled(uint256 trancheId) public view returns (bool) {
        Tranche memory tranche = _fundingTranches[trancheId];
        if (trancheId != 0) {
            require(tranche.amount > 0, InvalidTranche());
        }
        return tranche.settled; 
    }
    function fundingToken(uint256 trancheId) public view returns (address) { 
        Tranche memory tranche = _fundingTranches[trancheId];
        if (trancheId != 0) {
            require(tranche.amount > 0, InvalidTranche());
        }
        return tranche.token; 
    }
    function fundingAmount(uint256 trancheId) public view returns (uint256) { 
        Tranche memory tranche = _fundingTranches[trancheId];
        if (trancheId != 0) {
            require(tranche.amount > 0, InvalidTranche());
        }
        return tranche.amount; 
    }

    modifier onlyDealManager() {
        _onlyDealManager();
        _;
    }

    modifier onlyDeal() {
        _onlyDeal();
        _;
    }

    modifier onlyStakedMPHolder() {
        _onlyStakedMPHolder();
        _;
    }

    function _onlyDealManager() internal view {
        require(msg.sender == manager, NotAuthorized());
    }

    function _onlyDeal() internal view {
        require(msg.sender == address(deal), NotAuthorized());
    }

    function _onlyStakedMPHolder() internal view {
        require(token.balanceOf(msg.sender) > 0, NoStake());
    }
}
