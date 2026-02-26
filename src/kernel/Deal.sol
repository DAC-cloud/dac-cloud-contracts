// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/Structs.sol";
import "../interfaces/IDACCellAdapter.sol";
import "../interfaces/IDealCore.sol";
import "../interfaces/IDealAdmin.sol";
import "../interfaces/IDealManagementProposalFactory.sol";
import "./interfaces/IDealManager.sol";
import "./tokens/MainToken.sol";
import "./tokens/AgentToken.sol";
import "./tokens/StakedAgent.sol";
import "./governance/DealManagementProposal.sol";
import "./governance/AbstractDealManagementProposals.sol";

abstract contract Deal is IDealCore, IDealAdmin, ReentrancyGuard {

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
    
    address internal immutable agentTokenAddr;
    address internal immutable mainTokenAddr;

    address private immutable proposer;

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

    struct Tranche {
        address token;
        uint256 amount;
        bool settled;
    }

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

    function _beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) internal virtual {}

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) internal virtual {}

    function initialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external {
        require(msg.sender == factory, NotAuthorized());
        require(startTime == 0, AlreadyInitialized());

        _beforeInitialize(params, defaultVotingConfig);

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

        _afterInitialize(params, defaultVotingConfig);
    }
 
    function _beforeVoluntaryStake(address staker, uint256 amount) internal virtual {}
    function _afterVoluntaryStake(address staker, uint256 amount) internal virtual {}

    function onAgentTokenStaked(address staker, uint256 amount) external {
        require(msg.sender == agentTokenAddr || msg.sender == dacCell, NotAuthorized());

        // if the deal is approved no more direct stakes allowed
        require(!approved, DealAlreadyApproved());

        if (isWhitelistOnly) {
            require(isWhitelisted[staker], NotWhitelistedAgent());
        }

        _beforeVoluntaryStake(staker, amount);

        stake(staker, amount);

        _afterVoluntaryStake(staker, amount);
    }

    function _beforeEveryStake(address staker, uint256 amount) internal virtual {}
    function _afterEveryStake(address staker, uint256 amount) internal virtual {}

    function stake(address staker, uint256 amount) private {
        _beforeEveryStake(staker, amount);

        if (token.balanceOf(staker) == 0) {
            holders.push(staker);
        }
        
        token.mint(staker, amount);
        
        emit AgentTokensStaked(dacCell, id, staker, amount);

        _afterEveryStake(staker, amount);
    }

    function _beforeApprove(uint256 trancheId) internal virtual {}
    function _afterApprove(uint256 trancheId) internal virtual {}

    function onApproved(uint256 trancheId) external onlyDACCell {
        if (trancheId == 0) {
            require(!approved, DealAlreadyApproved());
            require(block.timestamp > _approveDeadline, DeadlineNotPassed());
        }
        else {
            require(_fundingTranches[trancheId].amount > 0, TrancheNotExists());
            require(!_fundingTranches[trancheId].settled, TrancheAlreadySettled());
        }
        
        _beforeApprove(trancheId);

        if (!approved) {
            approved = true;
        
            emit DealActivated(dacCell, id, token.totalSupply());
        }
        
        if (_fundingTranches[trancheId].amount > 0) {
            investedCapital[_fundingTranches[trancheId].token] += _fundingTranches[trancheId].amount;
        }
        _fundingTranches[trancheId].settled = true;

        _afterApprove(trancheId);
    }

    function _beforeInvite(address invitee, bool grantInviteRight) internal virtual {}
    function _afterInvite(address invitee, bool grantInviteRight) internal virtual {}

    function invite(address invitee, bool grantInviteRight) external {
        require(isWhitelistOnly, NotWhitelistDeal());

        if (msg.sender != address(this)) {
            require(isWhitelisted[msg.sender] && canInviteOthers[msg.sender], NotAuthorized());
        }
        
        if(!isWhitelisted[invitee]) {
            isWhitelisted[invitee] = true;
            canInviteOthers[invitee] = grantInviteRight;
            
            emit Invited(invitee, grantInviteRight);
        }   
    }

    function _beforeUnstake(address staker, uint256 amount) internal virtual {}
    function _afterUnstake(address staker, uint256 amount) internal virtual {}

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

        _beforeUnstake(agent, agentStake);

        token.burn(agent, agentStake);

        AgentToken(agentTokenAddr).burnFrom(address(this), agentStake); // burn agent tokens on our balance
        AgentToken(agentTokenAddr).mint(agent, agentStake);             // return agent tokens back to agent

        emit AgentTokensReleased(dacCell, id, agent, agentStake);

        _afterUnstake(agent, agentStake);
    }

    function _beforeReturnCapitalToDAC() internal virtual {}
    function _afterReturnCapitalToDAC() internal virtual {}

    function returnCapitalToDAC() external {
        if (msg.sender == dacCell) {
            require(block.timestamp > _dealDeadline, DeadlineNotPassed());
        }
        else {
            require(token.balanceOf(msg.sender) != 0, NotStakedAgent());
            if (!earlyReturns) {
                require(block.timestamp > _dealDeadline, DeadlineNotPassed());
            }
        }
        
        _beforeReturnCapitalToDAC();

        // Iterate through all funding tokens and return every balance
        for (uint256 i = 0; i < _fundingTokens.length; i++) {
            address _fundingToken = _fundingTokens[i];

            uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
            if (balance == 0) continue;

            IERC20(_fundingToken).approve(dacCell, balance);

            IDACCellAdapter(dacCell).depositTreasury(_fundingToken, balance);
            returnedCapital[_fundingToken] += balance;
            
            emit CapitalReturned(dacCell, id, _fundingToken, balance);
        }

        _afterReturnCapitalToDAC();
    }

    function _beforeMarkAsSuccess(uint256 rewardPercent) internal virtual {}
    function _afterMarkAsSuccess(uint256 rewardPercent) internal virtual {}

    function markAsSuccess(uint256 rewardPercent) external onlyDACCell {
        require(!closed, DealIsClosed());
        require(rewardsConverted + rewardPercent <= 100, InsufficientRewards());

        _beforeMarkAsSuccess(rewardPercent);

        uint256 reward = (_tokenRewardsLimit * rewardPercent) / 100;

        uint256 transformAmount = reward; // for event

        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderShare = (token.balanceOf(h) * reward) / token.totalSupply();  // pro-rata on original stake
            claimableRewards[h] = holderShare;
        }

        rewardsConverted += rewardPercent;

        // if all rewards were paid out, marking the deal as closed so MP tokens can withdraw stakes
        if (rewardsConverted == 100) {
            this.closeDeal();
        }

        emit RewardsAllocated(dacCell, id, transformAmount);
        
        _afterMarkAsSuccess(rewardPercent);
    }

    function _beforeMarkAsFailed(uint256 slashPercent) internal virtual {}
    function _afterMarkAsFailed(uint256 slashPercent) internal virtual {}

    function markAsFailed(uint256 slashPercent) external onlyDACCell {
        require(!closed, DealIsClosed());

        _beforeMarkAsFailed(slashPercent);

        uint256 slashAmount = (token.totalSupply() * slashPercent) / 100;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderSlash = (token.balanceOf(h) * slashPercent) / 100;
            token.burn(h, holderSlash);
        }
        
        emit StakesSlashed(dacCell, id, slashAmount);

        _afterMarkAsFailed(slashPercent);
    }

    function _beforeExtendDeadline(uint256 newDeadline) internal virtual {}
    function _afterExtendDeadline() internal virtual {}

    function extendDeadline(uint256 newDeadline) external onlyDACCell {
        require(!closed, DealIsClosed());
        
        _beforeExtendDeadline(newDeadline);

        _dealDeadline = newDeadline;
        
        emit DeadlineExtended(dacCell, id, newDeadline);

        _afterExtendDeadline();
    }

    function _beforeClose() internal virtual {}

    function closeDeal() external {
        require(msg.sender == address(this) || msg.sender == dacCell, NotAuthorized());
        require(!closed, DealIsClosed());
        
        _beforeClose();

        closed = true;
        
        emit DealClosed(dacCell, id, token.totalSupply());
    }
 
    function _beforeRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}
    function _afterRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}

    function recoverDeal(address liquidator, uint256 liquidatorStake) external onlyDACCell {
        require(closed, DealIsNotClosed());
        
        _beforeRecovery(liquidator, liquidatorStake);

        recovery = true;

        stake(liquidator, liquidatorStake);
        
        emit DealRecovered(dacCell, id, liquidator);

        _afterRecovery(liquidator, liquidatorStake);
    }

    function _beforeClaimMainToken(address grantee, uint256 amount) internal virtual {}
    function _afterClaimMainToken(address grantee, uint256 amount) internal virtual {}

    function claimMainToken() external {
        uint256 amount = claimableRewards[msg.sender];
        require(amount > 0, NoClaimableRewards());
        
        _beforeClaimMainToken(msg.sender, amount);

        claimableRewards[msg.sender] = 0;
        IDealManager(IDACCellAdapter(dacCell).dealManager()).mintMain(address(this), msg.sender, amount);
        
        emit RewardsClaimed(dacCell, msg.sender, amount);

        _afterClaimMainToken(msg.sender, amount);
    }

    function _beforeCreateProposal(ProposalParams calldata params) internal virtual {}
    function _afterCreateProposal(uint256 proposalId, ProposalParams calldata params) internal virtual {}

    function createStakedMPProposal(ProposalParams calldata params) external returns (uint256 proposalId) {
        if (msg.sender != address(this)) {
            _onlyStakedMPHolder();

            require(
                token.balanceOf(msg.sender) > votingConfig().qualification,
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

    function _toggleEarlyReturns(bool allowEarlyReturn) private {
        if (earlyReturns != allowEarlyReturn) {
            earlyReturns = allowEarlyReturn;
        }
    }

    function _toggleWhitelist(bool whitelistOnly) private {
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

    function _stakeMP(address staker, uint256 amount) private {
        // if the deal is not approved adding stakes not allowed
        require(approved, DealIsNotApproved());

        require(
            IERC20(agentTokenAddr).transferFrom(staker, address(this), amount),
            TransferFailed()
        );

        stake(staker, amount);
    }

    function _checkStackedMPProposalSupported(ProposalParams calldata) internal virtual returns (bool supported) {
        // Children override this to indicate if the governance proposal is supported
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
            address _fundingToken = DealManagementProposal(prop).target();
            uint256 amountFunding = uint256(DealManagementProposal(prop).i());

            // Creating tranche state
            if (_requestedFunding[_fundingToken] == 0) {
                _fundingTokens.push(_fundingToken);
            }
            _requestedFunding[_fundingToken] += amountFunding;
            
            _fundingTranches[proposalId] = Tranche({
                token: _fundingToken,
                amount: amountFunding,
                settled: false
            });

            IDealManager(IDACCellAdapter(dacCell).dealManager()).createTrancheProposal(id, proposalId);
        }

        else if (typ == AbstractDealManagementType.ADD_STAKE) {
            address staker = DealManagementProposal(prop).target();
            uint256 stakeAmount = uint256(DealManagementProposal(prop).i());
            
            _stakeMP(staker, stakeAmount);
        }

        else if (typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS) {
            bool toggle = abi.decode(DealManagementProposal(prop).data(), (bool));
            _toggleEarlyReturns(toggle);
            emit EarlyReturnsToggled(proposalId, earlyReturns);
        }

        else if (typ == AbstractDealManagementType.TOGGLE_WHITELIST) {
            bool toggle = abi.decode(DealManagementProposal(prop).data(), (bool));
            _toggleWhitelist(toggle);
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

    function onMessageDeal(bytes4, bytes calldata) internal virtual returns (bool) {
        // Basic deal accepts all messages, assuming they pass for the governance perspective
        // and makes sense on chain.
        
        return true;
    }
    
    function messageDeal(bytes4 messageKind, bytes calldata message) external onlyDACCell {
        require(onMessageDeal(messageKind, message), MessageNotAccepted());

        emit MessageReceived(messageKind, message);
    }

    function onLegalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) internal virtual {}

    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external onlyDACCell {
        onLegalWrapperMessage(legalWrapper, messageKind, message);
        
        emit LegalWrapperMessageReceived(legalWrapper, messageKind, message);
    }

    function approveDeadline() external view returns (uint256) { return _approveDeadline; }
    function dealDeadline() external view returns (uint256) { return _dealDeadline; }

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

    function getProposal(uint256 proposalId) public view returns (address) {
        require(proposals[proposalId] != address(0), InvalidProposal());
        return proposals[proposalId];
    }
    function votingConfig() public view returns (VotingConfig memory) { return _votingConfig; }

    modifier onlyDACCell() {
        _onlyDACCell();
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
