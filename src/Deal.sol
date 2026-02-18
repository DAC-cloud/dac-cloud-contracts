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
    uint256 public approveDeadline;
    uint256 public dealDeadline;
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
    uint256 public returnedCapital;

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
    event CapitalReturned(uint256 amount);

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
        approveDeadline = params.approveDeadline;
        dealDeadline = params.dealDeadline;
        startTime = block.timestamp;

        _votingContract = IVotingFactory(votingFactoryAddr).deployVoting(
            id, duration, address(this), lpTokenAddr
        );

        emit DealInitialized(id);
    }

    function totalSupply() public view override returns (uint256) { return _totalStakedMP; }
    function balanceOf(address account) public view override returns (uint256) { return stakedMPBalance[account]; }
    function transfer(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function transferFrom(address, address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }
    function approve(address, uint256) public pure override returns (bool) { revert("StakedMP non-transferable"); }

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

    function unstake() external {
        require(!approved, "Already approved");
        require(block.timestamp > approveDeadline, "Approve deadline not passed");
        uint256 amount = stakedMPBalance[msg.sender];
        require(amount > 0, "No stake");

        stakedMPBalance[msg.sender] = 0;
        _totalStakedMP -= amount;
        MPToken(mpTokenAddr).burnFrom(address(this), amount); // burn StakedMP
        MPToken(mpTokenAddr).mint(msg.sender, amount);        // return real MP
    }

    function returnCapitalToDAC() external {
        require(block.timestamp > dealDeadline || msg.sender == dacEntity, "Deadline not passed");
        uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
        if (balance == 0) return;

        IERC20(_fundingToken).transfer(dacEntity, balance);
        returnedCapital += balance;
        emit CapitalReturned(balance);
    }

    function markAsSuccess(uint256 rewardPercent) external { // added percentage there to support rich evaluator decisions flexibility
        require(msg.sender == dacEntity, "Only DAC");
        require(!evaluated, "Already evaluated");
        evaluated = true; //todo: make it percentage based (change from "evaluated" to "rewarded")
        successFlag = true;

        // we're not slashing stacked-MP balances
        
        // I think we need to move even further with flexibility here
        // MP balances can be later returned to manager when the deal closed by evaluator
        // and that makes a total sense economically

        // todo: and here "evaluated" becomes "closed", while rewards still be there
        // so evaluator need to also have a new action to close the deal
        
        uint256 transformAmount = (_totalStakedMP * rewardPercent) / 100;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderReward = (stakedMPBalance[h] * rewardPercent) / 100;
            claimableLP[h] = holderReward;
        }

        emit StakesTransformed(transformAmount);
    }

    function markAsFailed(uint256 slashPercent) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(!evaluated, "Already evaluated");
        evaluated = true; //todo: closed

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
    function getReturnedCapital() external view returns (uint256) { return returnedCapital; }
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