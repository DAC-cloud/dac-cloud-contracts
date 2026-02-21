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
        address votingFactory,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address);
}

abstract contract Deal is ERC20, ReentrancyGuard, IDealCore, IDealAdmin {
    address public immutable factory;
    
    uint256 public immutable id;
    address public immutable dacEntity;
    address public immutable governanceFactory;
    
    address public immutable managedEntity;

    address public immutable mpTokenAddr;
    address public immutable lpTokenAddr;
    address public immutable votingFactoryAddr;
    address public immutable proposer;
    
    string public linkHash;
    address private _fundingToken;
    uint256 public approveDeadline;
    uint256 private _lpRewardsLimit;
    uint256 public dealDeadline;
    uint256 private startTime;

    VotingConfig private _votingConfig;

    // Tranches indexed by proposalId
    mapping(uint256 => uint256) private _fundingAmount;
    mapping(uint256 => bool) private _fundingApproved;

    // Deal state
    bool public approved;
    bool public closed;
    bool public recovery;
    bool public earlyReturns;
    bool public isWhitelistOnly; 
    uint256 public rewardsConverted;
    uint256 public investedCapital;
    uint256 public returnedCapital;

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
    
    // Events
    event DealInitialized(uint256 indexed id, DealParams params);
    event StakedMPMinted(address indexed staker, uint256 amount);
    event DealActivated(uint256 indexed id);
    event StakesTransformed(uint256 totalMP);
    event StakesSlashed(uint256 slashAmount);
    event LPClaimed(address indexed holder, uint256 amount);
    event CapitalReturned(uint256 amount);
    event DeadlineExtended(uint256 newDeadline);
    event DealClosed(uint256 totalMP);
    event Invited(address indexed invitee, bool canInvite);
    event StakedMPProposalCreated(uint256 indexed id, StakedMPManagementType typ, address target, uint256 targetId, bytes data);
    event StakedMPProposalExecuted(uint256 indexed id, StakedMPManagementType typ);
    event EarlyReturnsToggled(bool enabled);

    constructor(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _mpToken,
        address _lpToken,
        address _votingFactory,
        address _proposer
    ) ERC20("Staked MP for Deal", "sMP") {
        factory = msg.sender;
        id = _id;
        governanceFactory = _governanceFactory;
        dacEntity = _dac;
        mpTokenAddr = _mpToken;
        lpTokenAddr = _lpToken;
        votingFactoryAddr = _votingFactory;
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
        _fundingToken = params.fundingToken;
        _lpRewardsLimit = params.lpRewardsLimit;
        approveDeadline = params.approveDeadline;
        dealDeadline = params.dealDeadline;
        _votingConfig = defaultVotingConfig;

        _fundingAmount[0] = params.fundingAmount;
        
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

    function _beforeStake(address staker, uint256 amount) internal virtual {}
    function _afterStake(address staker, uint256 amount) internal virtual {}

    function onMPStaked(address staker, uint256 amount) external {
        require(msg.sender == mpTokenAddr || msg.sender == dacEntity, "Unauthorized");

        // if the deal is approved no more stakes allowed
        require(!approved, "Already approved");

        if (isWhitelistOnly) {
            require(isWhitelisted[staker], "Not whitelisted for this deal");
        }

        _beforeStake(staker, amount);

        if (stakedMPBalance[staker] == 0) holders.push(staker);
        
        stakedRealMP[staker] += amount;
        stakedMPBalance[staker] += amount;
        _totalStakedMP += amount;
        _mint(staker, amount);
        
        emit StakedMPMinted(staker, amount);

        _afterStake(staker, amount);
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
            require(_fundingAmount[trancheId] != 0, "Tranche not exist");
            require(!_fundingApproved[trancheId], "Tranche not exist");
        }
        
        _beforeApprove(trancheId);

        if (!approved) {
            approved = true;
        
            emit DealActivated(id);
        }
        
        investedCapital += _fundingAmount[trancheId];
        _fundingApproved[trancheId] = true;

        _afterApprove(trancheId);
    }

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

        uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
        if (balance == 0) return;

        IDACEntityAdapter(dacEntity).depositTreasury(_fundingToken, balance);
        returnedCapital += balance;
        
        emit CapitalReturned(balance);

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

        uint256 slashAmount = (_totalStakedMP * slashPercent) / 100;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderSlash = (stakedMPBalance[h] * slashPercent) / 100;
            stakedMPBalance[h] -= holderSlash;
            claimableLP[h] = 0;
        }
        _totalStakedMP -= slashAmount;
        
        emit StakesSlashed(slashAmount);
    }

    function _beforeExtendDeadline(uint256 newDeadline) internal virtual {}

    function extendDeadline(uint256 newDeadline) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(!closed, "Deal is already closed");
        
        _beforeExtendDeadline(newDeadline);

        dealDeadline = newDeadline;
        
        emit DeadlineExtended(newDeadline);
    }

    function _beforeClose() internal virtual {}

    function closeDeal() external {
        require(msg.sender == address(this) || msg.sender == dacEntity, "Only DAC");
        require(!closed, "Deal is already closed");
        
        _beforeClose();

        closed = true;
        
        emit DealClosed(_totalStakedMP);
    }

    function claimLP() external {
        uint256 amount = claimableLP[msg.sender];
        require(amount > 0, "Nothing to claim");
        
        claimableLP[msg.sender] = 0;
        IDACEntityAdapter(dacEntity).mintLP(address(this), msg.sender, amount);
        
        emit LPClaimed(msg.sender, amount);
    }

    function _beforeCreateProposal(StakedMPParams calldata params) internal virtual {}
    function _afterCreateProposal(uint256 proposalId, StakedMPParams calldata params) internal virtual {}

    function createStakedMPProposal(StakedMPParams calldata params) external returns (uint256 proposalId) {
        if (msg.sender != address(this)) {
            _onlyStakedMPHolder();
        }

        _beforeCreateProposal(params);

        proposalId = nextId++;
        
        if (!(
            params.typ == StakedMPManagementType.UpdateVotingConfig ||
            params.typ == StakedMPManagementType.ToggleEarlyReturns ||
            params.typ == StakedMPManagementType.ToggleWhitelist ||
            params.typ == StakedMPManagementType.RequestTranche ||
            params.typ == StakedMPManagementType.AddStake
        )) {
            // If type is not a basic Deal governance type, requiring derived contracts to validate
            require(
                _checkStackedMPProposalSupported(params),
                "Governance proposal type not supported"
            );
        }

        address prop = IStakedMPProposalFactory(governanceFactory).deployProposal(
            proposalId,
            params,
            address(this),
            votingFactoryAddr,
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

    function _checkStackedMPProposalSupported(StakedMPParams calldata params) internal virtual returns (bool supported) {
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
            uint256 amountFunding = StakedMPProposal(prop).getAmount();

            // Creating tranche state
            _fundingAmount[proposalId] = amountFunding;

            IDACEntityAdapter(dacEntity).createTrancheProposal(id, proposalId);
        }

        else if (typ == StakedMPManagementType.AddStake) {
            // todo: implement add stake (MP holder shall approve prior)
        }

        else if (typ == StakedMPManagementType.UpdateVotingConfig) {
            // todo: implement voting config update
        }

        else if (typ == StakedMPManagementType.ToggleEarlyReturns) {
            bool toggleValue = StakedMPProposal(prop).getToggleValue();
            _toggleEarlyReturns(toggleValue);
        }

        else if (typ == StakedMPManagementType.ToggleWhitelist) {
            bool toggleValue = StakedMPProposal(prop).getToggleValue();
            _toggleWhitelist(toggleValue);
        }

        else {
            // Forward to child for specific types
            _executeStakedMPProposal(StakedMPProposal(prop));
        }
        
        emit StakedMPProposalExecuted(proposalId, typ);

        _afterExecuteProposal(proposalId);
    }

    function _executeStakedMPProposal(StakedMPProposal proposal) internal virtual {
        // Children override this to handle their specific proposals
        revert("Unsupported management proposal type in base Deal");
    }

    function getStakedMPTotal() external view returns (uint256) { return _totalStakedMP; }
    function getReturnedCapital() external view returns (uint256) { return returnedCapital; }
    function getLPRewardsLimit() external view returns (uint256) { return _lpRewardsLimit; }
    function isValidDeal() external pure returns (bool) { return true; }
    function fundingToken() public view returns (address) { return _fundingToken; }
    function fundingAmount(uint256 trancheId) public view returns (uint256) { return _fundingAmount[trancheId]; }

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
        address votingAddr = StakedMPProposal(stakedMPProposals[proposalId]).votingContract();

        require(
            IVoting(votingAddr).isResolved() &&
            IVoting(votingAddr).outcome(),
            "Vote not passed"
        );
    }
}