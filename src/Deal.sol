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

contract Deal is ERC20, ReentrancyGuard, IDeal {
    uint256 public id;
    string public description;
    address public dacEntity;
    address private _childDAC;
    address private _fundingToken;
    uint256 private _fundingAmount;
    uint256 public successThreshold;
    uint256 public startTime;
    uint256 public duration;
    address private _votingContract;
    address private _votingFactory;

    mapping(address => uint256) private _stakedMPBalances;
    uint256 private _totalStakedMP;
    mapping(address => mapping(address => uint256)) private _allowances;

    bool public approved = false;
    bool public evaluated = false;
    bool public success = false; // For returnProfits

    mapping(address => uint256) public stakedRealMP;
    MPToken public mpToken;

    address[] public holders; // For pro-rata loops

    uint256 public capitalCallNonce;
    uint256 public lpAmount;

    mapping(uint256 => address) public childProposalVotings;

    constructor(
        uint256 _id,
        string memory _description,
        address _dac,
        address _child,
        uint256 _funding,
        address _token,
        uint256 _threshold,
        uint256 _duration,
        address _mpToken,
        address _lpToken,
        address _dacVotingFactory,
        uint256 _lpAmount
    ) ERC20("Staked MP for Deal", "sMP") {
        id = _id;
        description = _description;
        dacEntity = _dac;
        _childDAC = _child;
        _fundingAmount = _funding;
        _fundingToken = _token;
        successThreshold = _threshold;
        duration = _duration;
        startTime = block.timestamp;
        mpToken = MPToken(_mpToken);
        _votingFactory = _dacVotingFactory;
        _votingContract = IVotingFactory(_dacVotingFactory).deployVoting(_id, _duration, address(this), _lpToken);
        lpAmount = _lpAmount;
        capitalCallNonce = _id; // Use id as nonce
        emit DealInitialized(_id);
    }

    function totalSupply() public view override returns (uint256) {
        return _totalStakedMP;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _stakedMPBalances[account];
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function onMPStaked(address staker, uint256 amount) external onlyDACOrMPToken {
        if (_stakedMPBalances[staker] == 0) holders.push(staker);
        stakedRealMP[staker] += amount;
        _stakedMPBalances[staker] += amount;
        _totalStakedMP += amount;
        _mint(staker, amount);
        emit StakedMPMinted(staker, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(_stakedMPBalances[msg.sender] >= amount, "Insufficient balance");
        _stakedMPBalances[msg.sender] -= amount;
        _stakedMPBalances[to] += amount;
        return super.transfer(to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function onApproved() external onlyDACEntity {
        approved = true;
        // Fulfill capital call for child DAC
        IDACEntity.CapitalCall memory call = IDACEntity.CapitalCall(_fundingToken, capitalCallNonce, address(this), lpAmount, _fundingAmount);
        IDACEntity(_childDAC).fulfillCapitalCall(call);
        emit DealActivated(id);
    }

    function transformStakes() external onlyDACEntity {
        require(!evaluated, "Already evaluated");
        evaluated = true;
        success = true;
        uint256 totalMP = _totalStakedMP;
        mpToken.burnFrom(address(this), totalMP);
        _totalStakedMP = 0;
        // Pro-rata LP mint to holders
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 share = stakedRealMP[holder];
            LPToken(IDACEntity(dacEntity).getLPToken()).mint(holder, share);
        }
        emit StakesTransformed(totalMP);
    }

    function slashStakes(uint256 slashPercent) external onlyDACEntity {
        require(!evaluated, "Already evaluated");
        evaluated = true;
        uint256 slashAmount = (_totalStakedMP * slashPercent) / 100;
        mpToken.burnFrom(address(this), slashAmount);
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 holderSlash = (_stakedMPBalances[holder] * slashPercent) / 100;
            _stakedMPBalances[holder] -= holderSlash;
        }
        _totalStakedMP -= slashAmount;
        IERC20(_fundingToken).transfer(dacEntity, (_fundingAmount * slashPercent) / 100);
        emit StakesSlashed(slashAmount);
    }

    function getStakedMPTotal() external view returns (uint256) {
        return _totalStakedMP;
    }

    function returnProfits(uint256 profitAmount) external onlyAfterSuccess nonReentrant {
        IERC20(_fundingToken).transfer(dacEntity, profitAmount);
    }

    function isValidDeal() external pure returns (bool) {
        return true; // Placeholder
    }

    function votingContract() external view returns (address) {
        return _votingContract;
    }

    function fundingToken() external view returns (address) {
        return _fundingToken;
    }

    function fundingAmount() external view returns (uint256) {
        return _fundingAmount;
    }

    function childDAC() external view returns (address) {
        return _childDAC;
    }

    function createChildLPProposal(
        LPManagementType typ,
        address target,
        uint256 amountOrPercent,
        address dividendToken,
        uint256 cashAmount
    ) external onlyStakedMPHolder returns (uint256) {
        return IDACEntity(_childDAC).createLPManagementProposal(typ, target, amountOrPercent, dividendToken, cashAmount);
    }

    function createChildProposalVoting(uint256 childProposalId) external onlyStakedMPHolder {
        require(childProposalVotings[childProposalId] == address(0), "Voting already exists");
        address voting = IVotingFactory(_votingFactory).deployVoting(childProposalId, 7 days, address(this), address(this));
        childProposalVotings[childProposalId] = voting;
        emit ChildProposalVotingCreated(childProposalId, voting);
    }

    function resolveChildProposalVote(uint256 childProposalId) external onlyStakedMPHolder {
        address voting = childProposalVotings[childProposalId];
        require(voting != address(0), "No voting for this proposal");
        require(IVoting(voting).isResolved(childProposalId), "Voting not resolved");
        bool support = IVoting(voting).outcome(childProposalId);
        address childVoting = IDACEntity(_childDAC).getProposalVoting(childProposalId);
        IVoting(childVoting).vote(support);
        emit ChildProposalVoted(childProposalId, support);
    }

    modifier onlyDACEntity() {
        require(msg.sender == dacEntity, "Only DAC");
        _;
    }

    modifier onlyDACOrMPToken() {
        require(msg.sender == dacEntity || msg.sender == address(mpToken), "Unauthorized");
        _;
    }

    modifier onlyStakedMPHolder() {
        require(balanceOf(msg.sender) > 0, "Not staked MP holder");
        _;
    }

    modifier onlyAfterSuccess() {
        require(evaluated && success, "Not successful");
        _;
    }

    // Events
    event DealInitialized(uint256 indexed id);
    event StakedMPMinted(address indexed staker, uint256 amount);
    event DealActivated(uint256 indexed id);
    event StakesTransformed(uint256 totalMP);
    event StakesSlashed(uint256 slashAmount);
    event ChildProposalVotingCreated(uint256 indexed childProposalId, address voting);
    event ChildProposalVoted(uint256 indexed childProposalId, bool support);
}