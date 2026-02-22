// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MPToken.sol";
import "./IDealCore.sol";
import "./IDealAdmin.sol";
import "./Interfaces.sol";
import "./LPToken.sol";
import "./IDACEntityAdapter.sol";
import "./StakedMPProposal.sol";

interface IStakedMPProposalFactory {
    function deployProposal(
        uint256 id,
        StakedMPParams calldata params,
        address dac,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address);
}

abstract contract Deal is ERC20, ReentrancyGuard, IDealCore, IDealAdmin {
    address public immutable factory;
    
    uint256 public immutable id;
    address public immutable dacEntity;
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
    address public managedEntity;
    
    uint256 private _lpRewardsLimit;
    
    uint256 private startTime;
    uint256 public approveDeadline;
    uint256 public dealDeadline;

    // Link with document management system
    string public linkHash;

    // Funding
    address[] public fundingTokens;
    mapping(address => uint256) public _requestedFunding;

    struct Tranche {
        address token;
        uint256 amount;
        bool settled;
    }

    // Tranches indexed by proposalId
    mapping(uint256 => Tranche) private _fundingTranches;

    // Deal state
    bool public approved;
    bool public closed;
    bool public recovery;
    bool public earlyReturns;
    bool public isWhitelistOnly; 
    
    // General metrics for abstract Deal
    uint256 public rewardsConverted;

    // Indexed by funding token
    mapping(address => uint256) public investedCapital;
    mapping(address => uint256) public returnedCapital;

    // MP tokens staking
    uint256 private _totalStakedMP;
    mapping(address => uint256) public stakedRealMP;
    mapping(address => uint256) public stakedMPBalance;
    mapping(address => uint256) public claimableLP;

    // Whitelist
    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public canInviteOthers;

    address[] public holders; // only for claimable tracking

    // Governance
    uint256 public nextId = 1;
    mapping(uint256 => address) public stakedMPProposals;

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
    event Invited(address indexed invitee, bool canInvite);
    event StakedMPProposalCreated(uint256 indexed id, StakedMPManagementType typ, address target, uint256 targetId, bytes data);
    event StakedMPProposalExecuted(uint256 indexed id, StakedMPManagementType typ);
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
        dacEntity = _dac;
        mpTokenAddr = _mpToken;
        lpTokenAddr = _lpToken;
        proposer = _proposer;
    }

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
        startTime = block.timestamp;

        linkHash = params.linkHash;
        _lpRewardsLimit = params.lpRewardsLimit;
        approveDeadline = params.approveDeadline;
        dealDeadline = params.dealDeadline;
        _votingConfig = defaultVotingConfig;

        if (_requestedFunding[params.fundingToken] == 0) fundingTokens.push(params.fundingToken);
        _requestedFunding[params.fundingToken] = params.fundingAmount;

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
    }

    function totalSupply() public view override returns (uint256) { return _totalStakedMP; }
    function balanceOf(address account) public view override returns (uint256) { return stakedMPBalance[account]; }
    function transfer(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function transferFrom(address, address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function approve(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }

    function _beforeVoluntaryStake(address staker, uint256 amount) internal virtual {}
    function _afterVoluntaryStake(address staker, uint256 amount) internal virtual {}

    function onMPStaked(address staker, uint256 amount) external {
        require(msg.sender == mpTokenAddr || msg.sender == dacEntity, "Unauthorized");

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

    function stake(address staker, uint256 amount) internal {
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
        require(msg.sender == dacEntity, "Only DAC");

        if (trancheId == 0) {
            require(!approved, "Already approved");
            require(block.timestamp > approveDeadline, "Approve deadline not passed");
        }
        else {
            require(_fundingTranches[trancheId].amount > 0, "Tranche not exist");
            require(!_fundingTranches[trancheId].settled, "Tranche not exist");
        }
        
        _beforeApprove(trancheId);

        if (!approved) {
            approved = true;
        
            emit DealActivated(id);
        }
        
        investedCapital[_fundingTranches[trancheId].token] += _fundingTranches[trancheId].amount;
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
            require(block.timestamp > approveDeadline, "Approve deadline not passed");
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
        if (msg.sender == dacEntity) {
            require(block.timestamp > dealDeadline, "Deadline not passed");
        }
        else {
            require(stakedMPBalance[msg.sender] != 0, "Not a staked-MP holder");
            if (!earlyReturns) {
                require(block.timestamp > dealDeadline, "Deadline not passed");
            }
        }
        
        _beforeReturnCapitalToDAC();

        // Iterate through all funding tokens and return every balance
        for (uint256 i = 0; i < fundingTokens.length; i++) {
            address _fundingToken = fundingTokens[i];

            uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
            if (balance == 0) continue;

            IDACEntityAdapter(dacEntity).depositTreasury(_fundingToken, balance);
            returnedCapital[_fundingToken] += balance;
            
            emit CapitalReturned(_fundingToken, balance);
        }

        _afterReturnCapitalToDAC();
    }

    function _beforeMarkAsSuccess(uint256 rewardPercent) internal virtual {}
    function _afterMarkAsSuccess(uint256 rewardPercent) internal virtual {}

    function markAsSuccess(uint256 rewardPercent) external {
        require(msg.sender == dacEntity, "Only DAC");
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
        require(msg.sender == dacEntity, "Only DAC");
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
        require(msg.sender == dacEntity, "Only DAC");
        require(!closed, "Deal is already closed");
        
        _beforeExtendDeadline(newDeadline);

        dealDeadline = newDeadline;
        
        emit DeadlineExtended(newDeadline);

        _afterExtendDeadline();
    }

    function _beforeClose() internal virtual {}

    function closeDeal() external {
        require(msg.sender == address(this) || msg.sender == dacEntity, "Only DAC");
        require(!closed, "Deal is already closed");
        
        _beforeClose();

        closed = true;
        
        emit DealClosed(_totalStakedMP);
    }
 
    function _beforeRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}
    function _afterRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}

    function recoverDeal(address liquidator, uint256 liquidatorStake) external {
        require(msg.sender == dacEntity, "Only DAC");
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
        IDACEntityAdapter(dacEntity).mintLP(address(this), msg.sender, amount);
        
        emit LPClaimed(msg.sender, amount);

        _afterClaimLP(msg.sender, amount);
    }

    function _beforeCreateProposal(StakedMPParams calldata params) internal virtual {}
    function _afterCreateProposal(uint256 proposalId, StakedMPParams calldata params) internal virtual {}

    function createStakedMPProposal(StakedMPParams calldata params) external returns (uint256 proposalId) {
        if (msg.sender != address(this)) {
            _onlyStakedMPHolder();
        }

        _beforeCreateProposal(params);

        if (!approved) {
            require(
                (
                    params.typ == StakedMPManagementType.UpdateVotingConfig ||
                    params.typ == StakedMPManagementType.ToggleEarlyReturns ||
                    params.typ == StakedMPManagementType.ToggleWhitelist
                ),
                "Proposal type available"
            );
        }

        if (!(
            params.typ == StakedMPManagementType.UpdateVotingConfig ||
            params.typ == StakedMPManagementType.ToggleEarlyReturns ||
            params.typ == StakedMPManagementType.ToggleWhitelist ||
            params.typ == StakedMPManagementType.RequestTranche ||
            params.typ == StakedMPManagementType.AddStake
        )) {
            // If type is not a basic Deal governance type, requiering derived contracts to validate
            require(
                _checkStackedMPProposalSupported(params),
                "Governance proposal type not supported"
            );
        }

        proposalId = nextId++;

        address prop = IStakedMPProposalFactory(governanceFactory).deployProposal(
            proposalId,
            params,
            address(this),
            address(this),
            _votingConfig
        );

        stakedMPProposals[proposalId] = prop;

        emit StakedMPProposalCreated(proposalId, params.typ, params.target, params.id, params.data);

        _afterCreateProposal(proposalId, params);
    }

    function _toggleEarlyReturns(bool allowEarlyReturn) internal {
        if (earlyReturns != allowEarlyReturn) {
            earlyReturns = allowEarlyReturn;
            emit EarlyReturnsToggled(earlyReturns);
        }
    }

    function _toggleWhitelist(bool whitelistOnly) internal {
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

    function _stakeMP(address staker, uint256 amount) internal {
        // if the deal is not approved adding stakes not allowed
        require(approved, "Deal not approved");

        require(
            IERC20(mpTokenAddr).transferFrom(staker, address(this), amount),
            "Token not transferred"
        );

        stake(staker, amount);
    }

    function _checkStackedMPProposalSupported(StakedMPParams calldata) internal virtual returns (bool supported) {
        // Children override this to indicate if the governance proposal is supported
        supported = false;
    }

    function _beforeExecuteProposal(uint256 proposalId) internal virtual {}
    function _afterExecuteProposal(uint256 proposalId) internal virtual {}

    function executeStakedMPProposal(uint256 proposalId) external onlyAfterStakedMPVote(proposalId) {
        _beforeExecuteProposal(proposalId);

        address prop = stakedMPProposals[proposalId];
        StakedMPManagementType typ = StakedMPProposal(prop).typ();

        if (typ == StakedMPManagementType.RequestTranche) {
            address _fundingToken = StakedMPProposal(prop).target();
            uint256 amountFunding = StakedMPProposal(prop).getAmount();

            // Creating tranche state
            if (_requestedFunding[_fundingToken] == 0) fundingTokens.push(_fundingToken);
            _requestedFunding[_fundingToken] = amountFunding;
            
            _fundingTranches[proposalId] = Tranche({
                token: _fundingToken,
                amount: amountFunding,
                settled: false
            });

            IDACEntityAdapter(dacEntity).createTrancheProposal(id, proposalId);
        }

        else if (typ == StakedMPManagementType.AddStake) {
            address staker = StakedMPProposal(prop).target();
            uint256 stakeAmount = StakedMPProposal(prop).getAmount();
            
            _stakeMP(staker, stakeAmount);
        }

        else if (typ == StakedMPManagementType.UpdateVotingConfig) {
            VotingConfig memory config = StakedMPProposal(prop).getVotingConfiguration();

            _votingConfig = config;
            emit VotingConfigUpdate(id, config);
        }

        else if (typ == StakedMPManagementType.ToggleEarlyReturns) {
            _toggleEarlyReturns(StakedMPProposal(prop).getToggleValue());
        }

        else if (typ == StakedMPManagementType.ToggleWhitelist) {
            _toggleWhitelist(StakedMPProposal(prop).getToggleValue());
        }

        else {
            // Forward to child for specific types
            _executeStakedMPProposal(StakedMPProposal(prop));
        }
        
        emit StakedMPProposalExecuted(proposalId, typ);

        _afterExecuteProposal(proposalId);
    }

    function _executeStakedMPProposal(StakedMPProposal) internal virtual {
        // Children override this to handle their specific proposals
        revert("Unsupported management proposal type in base Deal");
    }

    function getStakedMPTotal() external view returns (uint256) { return _totalStakedMP; }
    function getReturnedCapital(address token) external view returns (uint256) { return returnedCapital[token]; }
    function getInvestedCapital(address token) external view returns (uint256) { return investedCapital[token]; }
    function getLPRewardsLimit() external view returns (uint256) { return _lpRewardsLimit; }
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external view returns (bool) { return approved; }
    function isClosed() external view returns (bool) { return closed; }
    function fundingSettled(uint256 trancheId) public view returns (bool) {
        Tranche memory tranche = _fundingTranches[trancheId];
        require(tranche.amount > 0, "Invalid tranche");
        return tranche.settled; 
    }
    function fundingToken(uint256 trancheId) public view returns (address) { 
        Tranche memory tranche = _fundingTranches[trancheId];
        require(tranche.amount > 0, "Invalid tranche");
        return tranche.token; 
    }
    function fundingAmount(uint256 trancheId) public view returns (uint256) { 
        Tranche memory tranche = _fundingTranches[trancheId];
        require(tranche.amount > 0, "Invalid tranche");
        return tranche.amount; 
    }

    function votingConfig() public view returns (VotingConfig memory) { return _votingConfig; }

    modifier onlyDACEntity() {
        _onlyDACEntity();
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

    function _onlyDACEntity() internal view {
        require(msg.sender == dacEntity, "Only DAC");
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