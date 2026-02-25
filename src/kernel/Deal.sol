// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/Structs.sol";
import "../interfaces/IDACCellAdapter.sol";
import "../interfaces/IDealCore.sol";
import "../interfaces/IDealAdmin.sol";
import "../interfaces/IDealManagementProposalFactory.sol";
import "./tokens/MPToken.sol";
import "./tokens/LPToken.sol";
import "./governance/DealManagementProposal.sol";
import "./governance/AbstractDealManagementProposals.sol";

abstract contract Deal is ERC20, ReentrancyGuard, IDealCore, IDealAdmin {
    address public immutable factory;
    
    uint256 public immutable id;
    address public immutable dacCell;
    address public immutable governanceFactory;
    
    address public immutable mpTokenAddr;
    address public immutable lpTokenAddr;

    address public immutable proposer;

    // Entities in the DAC paradigm are analogue of the "balance sheets"
    // Can store and manage capital on long term basis.
    // While Deal can have capital on it's "contract balance", Deal is not a storage
    // for it, and only escrow capital within the Deal logic.

    // Entity connected on initialization to enable Create2 address prediction
    // of the Deal for bootstrapping child-DACs
    address internal managedEntity;
    
    uint256 private _lpRewardsLimit;
    
    uint256 private startTime;
    uint256 private _approveDeadline;
    uint256 private _dealDeadline;

    // Link with document management system
    string public linkHash;

    // Funding
    address[] private _fundingTokens;
    mapping(address => uint256) private _requestedFunding;

    struct Tranche {
        address token;
        uint256 amount;
        bool settled;
    }

    // Tranches indexed by proposalId
    mapping(uint256 => Tranche) private _fundingTranches;

    // Deal state
    bool private approved;
    bool private closed;
    bool private recovery;
    bool private isWhitelistOnly; 
    
    bool internal earlyReturns;
    
    // General metrics for abstract Deal
    uint256 private rewardsConverted;

    // Indexed by funding token
    mapping(address => uint256) internal investedCapital;
    mapping(address => uint256) internal returnedCapital;

    // MP tokens staking
    uint256 private _totalStakedMP;
    mapping(address => uint256) private stakedRealMP;
    mapping(address => uint256) private stakedMPBalance;
    mapping(address => uint256) private claimableLP;

    // Whitelist
    mapping(address => bool) private isWhitelisted;
    mapping(address => bool) private canInviteOthers;

    address[] private holders; // only for claimable tracking

    // Governance
    uint256 private nextId = 1;
    mapping(uint256 => address) private stakedMPProposals;

    VotingConfig private _votingConfig;
    
    // Events
    event DealInitialized(uint256 indexed id, DealParams params);
    event StakedMPMinted(address indexed staker, uint256 amount);
    event DealActivated(uint256 indexed id);
    event TrancheRequested(uint256 indexed tranche, address indexed token, uint256 amount);
    event StakesTransformed(uint256 rewardLP);
    event StakesSlashed(uint256 slashAmount);
    event LPClaimed(address indexed holder, uint256 amount);
    event CapitalReturned(address indexed token, uint256 amount);
    event DeadlineExtended(uint256 newDeadline);
    event DealClosed(uint256 totalMP);
    event DealRecovered(address indexed liquidator);
    event MessageReceived(bytes4 messageKind, bytes message);
    event LegalWrapperMessageReceived(address indexed wrapper, bytes4 messageKind, bytes message);
    event Invited(address indexed invitee, bool canInvite);
    event DealManagementProposalCreated(uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);
    event DealManagementProposalExecuted(uint256 indexed id, bytes4 indexed typ);
    event VotingConfigUpdate(uint256 indexed id, VotingConfig config);
    event EarlyReturnsToggled(bool enabled);

    constructor(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _mpToken,
        address _lpToken,
        address _proposer
    ) ERC20("Staked MP for Deal", "sMP") {
        factory = msg.sender;
        id = _id;
        governanceFactory = _governanceFactory;
        dacCell = _dac;
        mpTokenAddr = _mpToken;
        lpTokenAddr = _lpToken;
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
        require(msg.sender == factory, "Only factory");
        require(startTime == 0, "Already initialized");

        _beforeInitialize(params, defaultVotingConfig);

        startTime = block.timestamp;

        linkHash = params.linkHash;
        _lpRewardsLimit = params.lpRewardsLimit;
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

        emit DealInitialized(id, params);

        _afterInitialize(params, defaultVotingConfig);
    }
 
    function totalSupply() public view override returns (uint256) { return _totalStakedMP; }
    function balanceOf(address account) public view override returns (uint256) { return stakedMPBalance[account]; }
    function transfer(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function transferFrom(address, address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function approve(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }

    function _beforeVoluntaryStake(address staker, uint256 amount) internal virtual {}
    function _afterVoluntaryStake(address staker, uint256 amount) internal virtual {}

    function onMPStaked(address staker, uint256 amount) external {
        require(msg.sender == mpTokenAddr || msg.sender == dacCell, "Unauthorized");

        // if the deal is approved no more direct stakes allowed
        require(!approved, "Already approved");

        if (isWhitelistOnly) {
            require(isWhitelisted[staker], "Not whitelisted for this deal");
        }

        _beforeVoluntaryStake(staker, amount);

        stake(staker, amount);

        _afterVoluntaryStake(staker, amount);
    }

    function _beforeEveryStake(address staker, uint256 amount) internal virtual {}
    function _afterEveryStake(address staker, uint256 amount) internal virtual {}

    function stake(address staker, uint256 amount) private {
        _beforeEveryStake(staker, amount);

        if (stakedMPBalance[staker] == 0) holders.push(staker);
        
        stakedRealMP[staker] += amount;
        stakedMPBalance[staker] += amount;
        _totalStakedMP += amount;
        _mint(staker, amount);
        
        emit StakedMPMinted(staker, amount);

        _afterEveryStake(staker, amount);
    }

    function _beforeApprove(uint256 trancheId) internal virtual {}
    function _afterApprove(uint256 trancheId) internal virtual {}

    function onApproved(uint256 trancheId) external {
        require(msg.sender == dacCell, "Only DAC");

        if (trancheId == 0) {
            require(!approved, "Already approved");
            require(block.timestamp > _approveDeadline, "Approve deadline not passed");
        }
        else {
            require(_fundingTranches[trancheId].amount > 0, "Tranche not exist");
            require(!_fundingTranches[trancheId].settled, "Tranche already settled");
        }
        
        _beforeApprove(trancheId);

        if (!approved) {
            approved = true;
        
            emit DealActivated(id);
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
        require(isWhitelistOnly, "Deal is not whitelist-only");

        if (msg.sender != address(this)) {
            require(isWhitelisted[msg.sender] && canInviteOthers[msg.sender], "Not authorized to invite");
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
            require(!approved, "Already approved");
            require(block.timestamp > _approveDeadline, "Approve deadline not passed");
        }
        else {
            // if the recovery is on, no more unstakes
            require(!recovery, "Deal recovered");
        }
        
        address staker = msg.sender;

        uint256 amount = stakedMPBalance[staker];
        require(amount > 0, "No stake");

        _beforeUnstake(staker, amount);

        stakedMPBalance[msg.sender] = 0;
        _totalStakedMP -= amount;
        MPToken(mpTokenAddr).burnFrom(address(this), amount); // burn StakedMP
        MPToken(mpTokenAddr).mint(msg.sender, amount);        // return real MP

        _afterUnstake(staker, amount);
    }

    function _beforeReturnCapitalToDAC() internal virtual {}
    function _afterReturnCapitalToDAC() internal virtual {}

    function returnCapitalToDAC() external {
        if (msg.sender == dacCell) {
            require(block.timestamp > _dealDeadline, "Deadline not passed");
        }
        else {
            require(stakedMPBalance[msg.sender] != 0, "Not a staked-MP holder");
            if (!earlyReturns) {
                require(block.timestamp > _dealDeadline, "Deadline not passed");
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
            
            emit CapitalReturned(_fundingToken, balance);
        }

        _afterReturnCapitalToDAC();
    }

    function _beforeMarkAsSuccess(uint256 rewardPercent) internal virtual {}
    function _afterMarkAsSuccess(uint256 rewardPercent) internal virtual {}

    function markAsSuccess(uint256 rewardPercent) external {
        require(msg.sender == dacCell, "Only DAC");
        require(!closed, "Deal is already closed");
        require(rewardsConverted + rewardPercent <= 100, "Insufficient remaining rewards");

        _beforeMarkAsSuccess(rewardPercent);

        uint256 rewardLP = (_lpRewardsLimit * rewardPercent) / 100;

        uint256 transformAmount = rewardLP; // for event

        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderShare = (stakedRealMP[h] * rewardLP) / _totalStakedMP;  // pro-rata on original stake
            claimableLP[h] = holderShare;
        }

        rewardsConverted += rewardPercent;

        // if all rewards were paid out, marking the deal as closed so MP tokens can withdraw stakes
        if (rewardsConverted == 100) {
            this.closeDeal();
        }

        emit StakesTransformed(transformAmount);
        
        _afterMarkAsSuccess(rewardPercent);
    }

    function _beforeMarkAsFailed(uint256 slashPercent) internal virtual {}
    function _afterMarkAsFailed(uint256 slashPercent) internal virtual {}

    function markAsFailed(uint256 slashPercent) external {
        require(msg.sender == dacCell, "Only DAC");
        require(!closed, "Deal is already closed");

        _beforeMarkAsFailed(slashPercent);

        uint256 slashAmount = (_totalStakedMP * slashPercent) / 100;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderSlash = (stakedMPBalance[h] * slashPercent) / 100;
            stakedMPBalance[h] -= holderSlash;
            claimableLP[h] = 0;
        }
        _totalStakedMP -= slashAmount;
        
        emit StakesSlashed(slashAmount);

        _afterMarkAsFailed(slashPercent);
    }

    function _beforeExtendDeadline(uint256 newDeadline) internal virtual {}
    function _afterExtendDeadline() internal virtual {}

    function extendDeadline(uint256 newDeadline) external {
        require(msg.sender == dacCell, "Only DAC");
        require(!closed, "Deal is already closed");
        
        _beforeExtendDeadline(newDeadline);

        _dealDeadline = newDeadline;
        
        emit DeadlineExtended(newDeadline);

        _afterExtendDeadline();
    }

    function _beforeClose() internal virtual {}

    function closeDeal() external {
        require(msg.sender == address(this) || msg.sender == dacCell, "Only DAC");
        require(!closed, "Deal is already closed");
        
        _beforeClose();

        closed = true;
        
        emit DealClosed(_totalStakedMP);
    }
 
    function _beforeRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}
    function _afterRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}

    function recoverDeal(address liquidator, uint256 liquidatorStake) external {
        require(msg.sender == dacCell, "Only DAC");
        require(closed, "Deal is not closed");
        
        _beforeRecovery(liquidator, liquidatorStake);

        recovery = true;

        stake(liquidator, liquidatorStake);
        
        emit DealRecovered(liquidator);

        _afterRecovery(liquidator, liquidatorStake);
    }

    function _beforeClaimLP(address grantee, uint256 amount) internal virtual {}
    function _afterClaimLP(address grantee, uint256 amount) internal virtual {}

    function claimLP() external {
        uint256 amount = claimableLP[msg.sender];
        require(amount > 0, "Nothing to claim");
        
        _beforeClaimLP(msg.sender, amount);

        claimableLP[msg.sender] = 0;
        IDACCellAdapter(dacCell).mintLP(address(this), msg.sender, amount);
        
        emit LPClaimed(msg.sender, amount);

        _afterClaimLP(msg.sender, amount);
    }

    function _beforeCreateProposal(ProposalParams calldata params) internal virtual {}
    function _afterCreateProposal(uint256 proposalId, ProposalParams calldata params) internal virtual {}

    function createStakedMPProposal(ProposalParams calldata params) external returns (uint256 proposalId) {
        if (msg.sender != address(this)) {
            _onlyStakedMPHolder();

            //todo: anti-spam qualification check
        }

        _beforeCreateProposal(params);

        if (!approved) {
            require(
                (
                    params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
                    params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
                    params.typ == AbstractDealManagementType.TOGGLE_WHITELIST
                ),
                "Proposal type available"
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
                "Governance proposal type not supported"
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

        stakedMPProposals[proposalId] = prop;

        emit DealManagementProposalCreated(proposalId, params.typ, params.target, params.i, params.data);

        _afterCreateProposal(proposalId, params);
    }

    function _toggleEarlyReturns(bool allowEarlyReturn) private {
        if (earlyReturns != allowEarlyReturn) {
            earlyReturns = allowEarlyReturn;
            emit EarlyReturnsToggled(earlyReturns);
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
        require(approved, "Deal not approved");

        require(
            IERC20(mpTokenAddr).transferFrom(staker, address(this), amount),
            "Token not transferred"
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
        _beforeExecuteProposal(proposalId);

        address prop = stakedMPProposals[proposalId];
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

            IDACCellAdapter(dacCell).createTrancheProposal(id, proposalId);
        }

        else if (typ == AbstractDealManagementType.ADD_STAKE) {
            address staker = DealManagementProposal(prop).target();
            uint256 stakeAmount = uint256(DealManagementProposal(prop).i());
            
            _stakeMP(staker, stakeAmount);
        }

        else if (typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS) {
            bool toggle = abi.decode(DealManagementProposal(prop).data(), (bool));
            _toggleEarlyReturns(toggle);
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
        revert("Unsupported management proposal type in base Deal");
    }

    function onMessageDeal(bytes4, bytes calldata) internal virtual returns (bool) {
        // Basic deal accepts all messages, assuming they pass for the governance perspective
        // and makes sense on chain.
        
        return true;
    }
    
    function messageDeal(bytes4 messageKind, bytes calldata message) external onlyDACCell {
        require(onMessageDeal(messageKind, message), "Message not accepted");

        emit MessageReceived(messageKind, message);
    }

    function onLegalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) internal virtual {}

    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external onlyDACCell {
        onLegalWrapperMessage(legalWrapper, messageKind, message);
        
        emit LegalWrapperMessageReceived(legalWrapper, messageKind, message);
    }

    function approveDeadline() external view returns (uint256) { return _approveDeadline; }
    function dealDeadline() external view returns (uint256) { return _dealDeadline; }

    function getStakedMPTotal() external view returns (uint256) { return _totalStakedMP; }
    function getReturnedCapital(address token) external view returns (uint256) { return returnedCapital[token]; }
    function getInvestedCapital(address token) external view returns (uint256) { return investedCapital[token]; }
    function getLPRewardsLimit() external view returns (uint256) { return _lpRewardsLimit; }
    
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external view returns (bool) { return approved; }
    function isClosed() external view returns (bool) { return closed; }

    function fundingTokens() public view returns (address[] memory) {
        return _fundingTokens;
    }
    function fundingSettled(uint256 trancheId) public view returns (bool) {
        Tranche memory tranche = _fundingTranches[trancheId];
        if (trancheId != 0) {
            require(tranche.amount > 0, "Invalid tranche");
        }
        return tranche.settled; 
    }
    function fundingToken(uint256 trancheId) public view returns (address) { 
        Tranche memory tranche = _fundingTranches[trancheId];
        if (trancheId != 0) {
            require(tranche.amount > 0, "Invalid tranche");
        }
        return tranche.token; 
    }
    function fundingAmount(uint256 trancheId) public view returns (uint256) { 
        Tranche memory tranche = _fundingTranches[trancheId];
        if (trancheId != 0) {
            require(tranche.amount > 0, "Invalid tranche");
        }
        return tranche.amount; 
    }

    function getProposal(uint256 proposalId) public view returns (address) {
        require(stakedMPProposals[proposalId] != address(0), "Invalid proposal");
        return stakedMPProposals[proposalId];
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
        require(msg.sender == dacCell, "Only DAC");
    }

    function _onlyStakedMPHolder() internal view {
        require(balanceOf(msg.sender) > 0, "Not staked MP holder");
    }
    
    function _onlyAfterStakedMPVote(uint256 proposalId) internal view {
        require(
            IVoting(stakedMPProposals[proposalId]).isResolved() &&
            IVoting(stakedMPProposals[proposalId]).outcome(),
            "Vote not passed"
        );
    }
}