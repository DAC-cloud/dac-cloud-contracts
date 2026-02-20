// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MPToken.sol";
import "./IDeal.sol";
import "./Interfaces.sol";
import "./LPToken.sol";
import "./IDACEntity.sol";
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

abstract contract Deal is ERC20, ReentrancyGuard, IDeal {
    address public immutable factory;
    
    uint256 public immutable id;
    address public immutable dacEntity;
    address public immutable governanceFactory;
    
    address public immutable managedEntity;

    address public immutable mpTokenAddr;
    address public immutable lpTokenAddr;
    address public immutable votingFactoryAddr;
    address public immutable proposer;
    
    string public description;
    address private _fundingToken;
    uint256 private _fundingAmount;
    uint256 private _lpRewardsLimit;
    uint256 public approveDeadline;
    uint256 public dealDeadline;
    uint256 private startTime;
    address private _votingContract;
    VotingConfig private _votingConfig;

    // Deal state
    bool public approved;
    bool public closed;
    bool public recovery;
    bool public earlyReturns;
    bool public isWhitelistOnly; 
    uint256 public rewardsConverted;
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
    event DealInitialized(uint256 indexed id);
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

    function initialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) public virtual override {
        require(msg.sender == factory, "Only factory");
        require(startTime == 0, "Already initialized");

        description = params.description;
        _fundingAmount = params.fundingAmount;
        _fundingToken = params.fundingToken;
        _lpRewardsLimit = params.lpRewardsLimit;
        approveDeadline = params.approveDeadline;
        dealDeadline = params.dealDeadline;
        startTime = block.timestamp;
        _votingConfig = defaultVotingConfig;

        _votingContract = IVotingFactory(votingFactoryAddr).deployVoting(
            id, _votingConfig.defaultDuration, address(this), lpTokenAddr, _votingConfig.quorumPercent
        );

        isWhitelistOnly = true;
        isWhitelisted[proposer] = true;
        canInviteOthers[proposer] = true;
        emit Invited(proposer, true);

        emit DealInitialized(id);
    }

    function totalSupply() public view override returns (uint256) { return _totalStakedMP; }
    function balanceOf(address account) public view override returns (uint256) { return stakedMPBalance[account]; }
    function transfer(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function transferFrom(address, address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function approve(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }

    function onMPStaked(address staker, uint256 amount) external {
        require(msg.sender == mpTokenAddr || msg.sender == dacEntity, "Unauthorized");

        // if the deal is approved no more stakes allowed
        require(!approved, "Already approved");

        if (isWhitelistOnly) {
            require(isWhitelisted[staker], "Not whitelisted for this deal");
        }

        if (stakedMPBalance[staker] == 0) holders.push(staker);
        
        stakedRealMP[staker] += amount;
        stakedMPBalance[staker] += amount;
        _totalStakedMP += amount;
        _mint(staker, amount);
        
        emit StakedMPMinted(staker, amount);
    }

    function onApproved() public virtual override {
        require(msg.sender == dacEntity, "Only DAC");
        require(!approved, "Already approved");
        require(block.timestamp > approveDeadline, "Approve deadline not passed");

        approved = true;
        
        emit DealActivated(id);
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

    function unstake() external {
        // allow to unstake if the deal is closed
        if (!closed) {
            // of if the deal is not approved within deadline
            require(!approved, "Already approved");
            require(block.timestamp > approveDeadline, "Approve deadline not passed");
        }
        
        uint256 amount = stakedMPBalance[msg.sender];
        require(amount > 0, "No stake");

        stakedMPBalance[msg.sender] = 0;
        _totalStakedMP -= amount;
        MPToken(mpTokenAddr).burnFrom(address(this), amount); // burn StakedMP
        MPToken(mpTokenAddr).mint(msg.sender, amount);        // return real MP
    }

    function returnCapitalToDAC() public virtual override {
        if (msg.sender == dacEntity) {
            require(block.timestamp > dealDeadline, "Deadline not passed");
        }
        else {
            require(stakedMPBalance[msg.sender] != 0, "Not a staked-MP holder");
            if (!earlyReturns) {
                require(block.timestamp > dealDeadline, "Deadline not passed");
            }
        }
        
        uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
        if (balance == 0) return;

        IERC20(_fundingToken).transfer(dacEntity, balance);
        returnedCapital += balance;
        
        emit CapitalReturned(balance);
    }

    function markAsSuccess(uint256 rewardPercent) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(!closed, "Deal is already closed");
        require(rewardsConverted + rewardPercent <= 100, "Insufficient remaining rewards");

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
    }

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

    function extendDeadline(uint256 newDeadline) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(!closed, "Deal is already closed");
        
        dealDeadline = newDeadline;
        
        emit DeadlineExtended(newDeadline);
    }

    function closeDeal() external {
        require(msg.sender == address(this) || msg.sender == dacEntity, "Only DAC");
        require(!closed, "Deal is already closed");
        
        closed = true;
        
        emit DealClosed(_totalStakedMP);
    }

    function claimLP() external {
        uint256 amount = claimableLP[msg.sender];
        require(amount > 0, "Nothing to claim");
        
        claimableLP[msg.sender] = 0;
        IDACEntity(dacEntity).mintLP(address(this), msg.sender, amount);
        
        emit LPClaimed(msg.sender, amount);
    }

    function createStakedMPProposal(StakedMPParams calldata params) external returns (uint256 proposalId) {
        if (msg.sender != address(this)) {
            _onlyStakedMPHolder();
        }

        proposalId = nextId++;
        
        if (!(
            params.typ == StakedMPManagementType.ToggleEarlyReturns ||
            params.typ == StakedMPManagementType.ToggleWhitelist 
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

    function executeStakedMPProposal(uint256 proposalId) external onlyAfterStakedMPVote(proposalId) {
        address prop = stakedMPProposals[proposalId];
        StakedMPManagementType typ = StakedMPProposal(prop).typ();

        if (typ == StakedMPManagementType.ToggleEarlyReturns) {
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
    }

    function _executeStakedMPProposal(StakedMPProposal proposal) internal virtual {
        // Children override this to handle their specific proposals
        revert("Unsupported management proposal type in base Deal");
    }

    function getStakedMPTotal() external view returns (uint256) { return _totalStakedMP; }
    function getReturnedCapital() external view returns (uint256) { return returnedCapital; }
    function getLPRewardsLimit() external view returns (uint256) { return _lpRewardsLimit; }
    function isValidDeal() external pure returns (bool) { return true; }
    function votingContract() external view returns (address) { return _votingContract; }
    function fundingToken() public view returns (address) { return _fundingToken; }
    function fundingAmount() public view returns (uint256) { return _fundingAmount; }

    function votingConfig() public view returns (VotingConfig memory) { return _votingConfig; }

    modifier onlyDACEntity() {
        _onlyDACEntity();
        _;
    }

    modifier onlyStakedMPHolder() {
        _onlyStakedMPHolder();
        _;
    }

    function _onlyDACEntity() internal view {
        require(msg.sender == dacEntity, "Only DAC");
    }

    function _onlyStakedMPHolder() internal view {
        require(balanceOf(msg.sender) > 0, "Not staked MP holder");
    }

    modifier onlyAfterStakedMPVote(uint256 proposalId) {
        _onlyAfterStakedMPVote(proposalId);
        _;
    }
    
    function _onlyAfterStakedMPVote(uint256 proposalId) internal view {
        //todo: implement voting logic
    }
}