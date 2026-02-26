// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/Structs.sol";
import "../interfaces/IDACCellAdapter.sol";
import "../interfaces/IDeal.sol";
import "../interfaces/IDealAdmin.sol";
import "../interfaces/IDealManagementProposalFactory.sol";
import "./interfaces/IDealCell.sol";
import "./interfaces/IDealManager.sol";
import "./tokens/MainToken.sol";
import "./tokens/AgentToken.sol";
import "./tokens/StakedAgent.sol";
import "./tokens/factories/TokenFactories.sol";
import "./governance/DealManagementProposal.sol";
import "./governance/AbstractDealManagementProposals.sol";
import "./libraries/DealCellGovernance.sol";

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
    error NoClaimableRewards();
    
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
    
    address internal immutable agentTokenAddr;
    address internal immutable mainTokenAddr;

    address private immutable proposer;

    IDeal private deal;
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
    bool internal isWhitelistOnly; 
    
    bool internal earlyReturns;
    
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
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external {
        require(msg.sender == factory, NotAuthorized());
        require(startTime == 0, AlreadyInitialized());

        token = StakedAgent(StakedAgentLib.deployStakedAgentToken(
            address(this),
            params.name,
            ERC20(agentTokenAddr).symbol()
        ));

        deal.beforeInitialize(params, defaultVotingConfig);

        startTime = block.timestamp;

        linkHash = params.linkHash;
        _tokenRewardsLimit = params.rewardsLimit;
        _approveDeadline = params.approveDeadline;
        _dealDeadline = params.dealDeadline;
        _votingConfig = defaultVotingConfig;

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

        isWhitelistOnly = true;
        isWhitelisted[proposer] = true;
        canInviteOthers[proposer] = true;
        emit Invited(proposer, true);

        emit DealInitialized(dacCell, id, params);

        deal.afterInitialize(params, defaultVotingConfig);
    }
 
    function stake(address staker, uint256 amount) internal {
        deal.beforeEveryStake(staker, amount);

        if (token.balanceOf(staker) == 0) {
            holders.push(staker);
        }
        
        token.mint(staker, amount);
        
        emit AgentTokensStaked(dacCell, id, staker, amount);

        deal.afterEveryStake(staker, amount);
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

    function approveFunding(uint256 trancheId) external onlyDACCell {
        if (trancheId == 0) {
            require(!approved, DealAlreadyApproved());
            require(block.timestamp > _approveDeadline, DeadlineNotPassed());
        }
        else {
            require(_fundingTranches[trancheId].amount > 0, TrancheNotExists());
            require(!_fundingTranches[trancheId].settled, TrancheAlreadySettled());
        }
        
        deal.beforeApproveFunding(trancheId);

        if (!approved) {
            approved = true;
        
            emit DealActivated(dacCell, id, token.totalSupply());
        }
        
        //todo: send money to Deal

        if (_fundingTranches[trancheId].amount > 0) {
            investedCapital[_fundingTranches[trancheId].token] += _fundingTranches[trancheId].amount;
        }
        _fundingTranches[trancheId].settled = true;

        deal.afterApproveFunding(trancheId);
    }

    function invite(address invitee, bool grantInviteRight) external {
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

    function unstake() external {
        // allow to unstake if the deal is closed
        if (!closed) {
            // of if the deal is not approved within deadline
            require(!approved || (block.timestamp > _approveDeadline), DeadlineNotPassed());
        }
        else {
            // if the recovery is on, no more unstakes
            require(!recovery, DealInLiquidation());
        }
        
        address agent = msg.sender;
        require(token.balanceOf(agent) > 0, NoStake());

        uint256 agentStake = token.balanceOf(agent);

        token.burn(agent, agentStake);

        AgentToken(agentTokenAddr).burnFrom(address(this), agentStake); // burn agent tokens on our balance
        AgentToken(agentTokenAddr).mint(agent, agentStake);             // return agent tokens back to agent

        emit AgentTokensReleased(dacCell, id, agent, agentStake);

        deal.onUnstake(agent, agentStake);
    }

    function requestTranche(
        DealManagementProposal prop
    ) external onlyDeal {
        address _fundingToken = DealManagementProposal(prop).target();
        uint256 amountFunding = uint256(DealManagementProposal(prop).i());

        // Creating tranche state
        if (_requestedFunding[_fundingToken] == 0) {
            _fundingTokens.push(_fundingToken);
        }
        _requestedFunding[_fundingToken] += amountFunding;
        
        _fundingTranches[prop.id()] = Tranche({
            token: _fundingToken,
            amount: amountFunding,
            settled: false
        });

        IDealManager(IDACCellAdapter(dacCell).dealManager()).createTrancheProposal(id, prop.id());
    }

    function withdrawCapital() external {
        DealCellGovernance.withdrawCapital(
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

    function markAsSuccess(uint256 rewardPercent) external onlyDACCell {
        require(!closed, DealIsClosed());
        
        DealCellGovernance.markAsSuccess(
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

    function markAsFailed(uint256 slashPercent) external onlyDACCell {
        require(!closed, DealIsClosed());

        DealCellGovernance.markAsFailed(
            slashPercent,
            id,
            dacCell,
            token,
            deal,
            holders
        );
    }

    function extendDeadline(uint256 newDeadline) external onlyDACCell {
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

    function recoverDeal(address liquidator, uint256 liquidatorStake) external onlyDACCell {
        require(closed, DealIsNotClosed());
        
        deal.beforeRecovery(liquidator, liquidatorStake);

        recovery = true;

        stake(liquidator, liquidatorStake);
        
        emit DealRecovered(dacCell, id, liquidator);

        deal.afterRecovery(liquidator, liquidatorStake);
    }

    function claimMainToken() external {
        uint256 amount = claimableRewards[msg.sender];
        require(amount > 0, NoClaimableRewards());
        
        deal.beforeClaimMainToken(msg.sender, amount);

        claimableRewards[msg.sender] = 0;
        IDealManager(IDACCellAdapter(dacCell).dealManager()).mintMain(address(this), msg.sender, amount);
        
        emit RewardsClaimed(dacCell, msg.sender, amount);

        deal.afterClaimMainToken(msg.sender, amount);
    }

    function toggleWhitelist(bool whitelistOnly) external onlyDeal {
        if (isWhitelistOnly != whitelistOnly) {
            isWhitelistOnly = whitelistOnly;
            
            if (isWhitelistOnly) {
                // Inviting all existing manager with invite capability
                for (uint256 i = 0; i < holders.length; i++) {
                    address manager = holders[i];
                    this.invite(manager, true);
                }
            }
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
    
    function messageDeal(bytes4 messageKind, bytes calldata message) external onlyDACCell {
        require(
            deal.onMessageDeal(messageKind, message), 
            MessageNotAccepted()
        );

        emit MessageReceived(messageKind, message);
    }

    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external onlyDACCell {
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

    modifier onlyDACCell() {
        _onlyDACCell();
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

    modifier onlyAfterStakedMPVote(uint256 proposalId) {
        _onlyAfterStakedMPVote(proposalId);
        _;
    }

    function _onlyDACCell() internal view {
        require(msg.sender == dacCell, NotAuthorized());
    }

    function _onlyDeal() internal view {
        require(msg.sender == address(deal), NotAuthorized());
    }

    function _onlyStakedMPHolder() internal view {
        require(token.balanceOf(msg.sender) > 0, NoStake());
    }
    
    function _onlyAfterStakedMPVote(uint256 proposalId) internal view {
        require(
            IVoting(proposals[proposalId]).isResolved() &&
            IVoting(proposals[proposalId]).outcome(),
            VoteNotPassed()
        );
    }
}
