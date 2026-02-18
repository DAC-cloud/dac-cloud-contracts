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
    uint256 public immutable id;
    address public immutable dacEntity;
    address public immutable childDAC;
    address public immutable mpTokenAddr;
    address public immutable lpTokenAddr;
    address public immutable votingFactoryAddr;

    string public description;
    address private _fundingToken;
    uint256 private _fundingAmount;
    uint256 private _successThreshold;
    uint256 private duration;
    uint256 private startTime;
    address private _votingContract;

    bool public approved;
    bool public evaluated;
    bool public successFlag;

    mapping(uint256 => address) public childProposalVotings;

    uint256 private _totalStakedMP;
    mapping(address => uint256) public stakedRealMP;
    mapping(address => uint256) public stakedMPBalance;
    mapping(address => uint256) public claimableLP;

    address[] public holders; // only for claimable tracking

    // Events
    event DealInitialized(uint256 indexed id);
    event StakedMPMinted(address indexed staker, uint256 amount);
    event DealActivated(uint256 indexed id);
    event StakesTransformed(uint256 totalMP);
    event StakesSlashed(uint256 slashAmount);
    event ChildProposalVotingCreated(uint256 indexed childProposalId, address voting);
    event ChildProposalVoted(uint256 indexed childProposalId, bool support);
    event LPClaimed(address indexed holder, uint256 amount);

    constructor(
        uint256 _id,
        address _dac,
        address _child,
        address _mpToken,
        address _lpToken,
        address _votingFactory
    ) ERC20("Staked MP for Deal", "sMP") {
        id = _id;
        dacEntity = _dac;
        childDAC = _child;
        mpTokenAddr = _mpToken;
        lpTokenAddr = _lpToken;
        votingFactoryAddr = _votingFactory;
    }

    function initialize(DealParams calldata params) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(startTime == 0, "Already initialized");

        description = params.description;
        _fundingAmount = params.fundingAmount;
        _fundingToken = params.fundingToken;
        _successThreshold = params.successThreshold;
        duration = params.duration;
        startTime = block.timestamp;

        _votingContract = IVotingFactory(votingFactoryAddr).deployVoting(
            id, duration, address(this), lpTokenAddr
        );

        emit DealInitialized(id);
    }

    function totalSupply() public view override returns (uint256) { return _totalStakedMP; }
    function balanceOf(address account) public view override returns (uint256) { return stakedMPBalance[account]; }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("StakedMP tokens are non-transferable");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("StakedMP tokens are non-transferable");
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert("StakedMP tokens are non-transferable");
    }

    function onMPStaked(address staker, uint256 amount) external {
        require(msg.sender == mpTokenAddr || msg.sender == dacEntity, "Unauthorized");
        if (stakedMPBalance[staker] == 0) holders.push(staker);
        stakedRealMP[staker] += amount;
        stakedMPBalance[staker] += amount;
        _totalStakedMP += amount;
        _mint(staker, amount);
        emit StakedMPMinted(staker, amount);
    }

    function onApproved() external {
        require(msg.sender == dacEntity, "Only DAC");
        approved = true;

        CapitalCall memory call = CapitalCall({
            treasuryToken: _fundingToken,
            nonce: id,
            lpRecipient: address(this),
            lpAmount: 0, //todo: need to fill this amount, from state, initialized at init
            cashAmount: _fundingAmount
        });

        IDACEntity(childDAC).fulfillCapitalCall(call);
        emit DealActivated(id);
    }

    function markAsSuccess() external {
        require(msg.sender == dacEntity, "Only DAC");
        require(!evaluated, "Already evaluated");
        evaluated = true;
        successFlag = true;

        uint256 transformedMP = _totalStakedMP;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            claimableLP[h] = stakedRealMP[h];
        }
        _totalStakedMP = 0;
        emit StakesTransformed(transformedMP);
    }

    function markAsFailed(uint256 slashPercent) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(!evaluated, "Already evaluated");
        evaluated = true;

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

    function claimLP() external {
        uint256 amount = claimableLP[msg.sender];
        require(amount > 0, "Nothing to claim");
        claimableLP[msg.sender] = 0;
        IDACEntity(dacEntity).mintLP(address(this), msg.sender, amount);
        emit LPClaimed(msg.sender, amount);
    }

    function createChildLPProposal(
        LPManagementType typ,
        address target,
        uint256 amountOrPercent,
        address dividendToken,
        uint256 cashAmount
    ) external onlyStakedMPHolder returns (uint256) {
        LPMParams memory proposalParams = LPMParams({ 
            typ: typ, 
            target: target, 
            amountOrPercent: amountOrPercent, 
            dividendToken: dividendToken, 
            cashAmount: cashAmount 
        });

        return IDACEntity(childDAC).createLPManagementProposal(proposalParams);
    }

    function createChildProposalVoting(uint256 childProposalId) external onlyStakedMPHolder {
        require(childProposalVotings[childProposalId] == address(0), "Voting already exists");
        address voting = IVotingFactory(votingFactoryAddr).deployVoting(childProposalId, 7 days, address(this), address(this));
        childProposalVotings[childProposalId] = voting;
        emit ChildProposalVotingCreated(childProposalId, voting);
    }

    function resolveChildProposalVote(uint256 childProposalId) external onlyStakedMPHolder {
        address voting = childProposalVotings[childProposalId];
        require(voting != address(0), "No voting for this proposal");
        require(IVoting(voting).isResolved(childProposalId), "Voting not resolved");
        bool support = IVoting(voting).outcome(childProposalId);
        address childVoting = IDACEntity(childDAC).getProposalVoting(childProposalId);
        IVoting(childVoting).vote(support);
        emit ChildProposalVoted(childProposalId, support);
    }

    function getStakedMPTotal() external view returns (uint256) { return _totalStakedMP; }
    function isValidDeal() external pure returns (bool) { return true; }
    function votingContract() external view returns (address) { return _votingContract; }
    function fundingToken() external view returns (address) { return _fundingToken; }
    function fundingAmount() external view returns (uint256) { return _fundingAmount; }

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
}