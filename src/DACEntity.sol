// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IDACEntity.sol";
import "./LPToken.sol";
import "./MPToken.sol";
import "./IDeal.sol";
import "./Interfaces.sol";

interface IDealFactory {
    function deployDeal(
        uint256 id,
        string memory description,
        address dac,
        address childDAC,
        uint256 fundingAmount,
        address fundingToken,
        uint256 successThreshold,
        uint256 duration,
        address mpToken,
        address votingFactory,
        uint256 lpAmount
    ) external returns (address);
}

interface ILPManagementFactory {
    function deployLPManagement(
        uint256 id,
        LPManagementType typ,
        address target,
        uint256 amountOrPercent,
        address dividendToken,
        address dac,
        address votingFactory,
        address token,
        uint256 cashAmount
    ) external returns (address);
}

interface ILPManagementProposal {
    function typ() external view returns (LPManagementType);
    function target() external view returns (address);
    function amount() external view returns (uint256);
    function percent() external view returns (uint256);
    function dividendToken() external view returns (address);
    function votingContract() external view returns (address);
    function cashAmount() external view returns (uint256);
}

contract DACEntity is IDACEntity, ReentrancyGuard {
    Config public config;
    LPToken public lpToken;
    MPToken public mpToken;

    mapping(address => uint256) public treasuryBalances;

    mapping(uint256 => address) public deals;
    mapping(uint256 => address) public lpProposals;
    uint256 public nextId = 1;
    mapping(address => uint256) public dealsMapping; // For quick checks
    mapping(address => bool) public oracles;
    address public dealFactory;
    address public lpFactory;

    mapping(bytes32 => CapitalCall) public capitalCalls;
    mapping(bytes32 => bool) public fulfilledCalls;

    constructor(
        address _lpToken,
        address _mpToken,
        uint256 _quorum,
        address _dealFactory,
        address _lpFactory,
        address _votingFactory
    ) {
        config = Config({
            quorumPercent: _quorum,
            lpToken: _lpToken,
            mpToken: _mpToken,
            votingFactory: _votingFactory
        });
        lpToken = LPToken(_lpToken);
        mpToken = MPToken(_mpToken);
        dealFactory = _dealFactory;
        lpFactory = _lpFactory;

        // Create first capital call for root DAC
        CapitalCall memory firstCall = CapitalCall({
            treasuryToken: _lpToken, // Placeholder
            nonce: 0,
            lpRecipient: msg.sender,
            lpAmount: 1000, // Placeholder
            cashAmount: 1000 // Placeholder
        });
        bytes32 hash = keccak256(abi.encode(firstCall));
        capitalCalls[hash] = firstCall;
        fulfilledCalls[hash] = false;

        emit DACCreated(msg.sender, address(this));
    }

    function depositTreasury(address token, uint256 amount) external nonReentrant {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        treasuryBalances[token] += amount;
        emit TreasuryDeposit(token, amount, msg.sender);
    }

    function createDealProposal(
        string memory description,
        address childDAC,
        uint256 fundingAmount,
        address fundingToken,
        uint256 successThreshold,
        uint256 duration,
        uint256 lpAmount
    ) external onlyMPHolder returns (uint256 id) {
        id = nextId++;
        address deal = IDealFactory(dealFactory).deployDeal(
            id, description, address(this), childDAC, fundingAmount, fundingToken, successThreshold, duration, config.mpToken, config.votingFactory, lpAmount
        );
        deals[id] = deal;
        dealsMapping[deal] = id;
        IERC20(fundingToken).approve(deal, fundingAmount);
        emit DealCreated(id, msg.sender, childDAC);
    }

    function approveDeal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        address deal = deals[id];
        require(deal != address(0), "Invalid ID");
        address token = IDeal(deal).fundingToken();
        uint256 amount = IDeal(deal).fundingAmount();
        require(treasuryBalances[token] >= amount, "Insufficient treasury");
        IERC20(token).transfer(deal, amount);
        treasuryBalances[token] -= amount;
        IDeal(deal).onApproved();
        emit DealApproved(id);
    }

    function fulfillCapitalCall(CapitalCall calldata call) external nonReentrant returns (bool) {
        bytes32 callHash = keccak256(abi.encode(call));
        require(!fulfilledCalls[callHash], "Already fulfilled");
        require(IERC20(call.treasuryToken).transferFrom(msg.sender, address(this), call.cashAmount), "Transfer failed");
        treasuryBalances[call.treasuryToken] += call.cashAmount;
        lpToken.mint(call.lpRecipient, call.lpAmount);
        fulfilledCalls[callHash] = true;
        emit CapitalCallFulfilled(callHash, call.lpRecipient, call.lpAmount);
        return true;
    }

    function proxyVoteFromDeal(address deal, uint256 childProposalId, bool support) external onlyDeal {
        uint256 weight = IDeal(deal).getStakedMPTotal();
        IDACEntity(IDeal(deal).childDAC()).voteOnProposal(childProposalId, support);
        emit ProxyVote(deal, childProposalId, support, weight);
    }

    function createLPManagementProposal(
        LPManagementType typ,
        address target,
        uint256 amountOrPercent,
        address dividendToken,
        uint256 cashAmount
    ) external onlyLPHolder returns (uint256 id) {
        id = nextId++;
        address prop = ILPManagementFactory(lpFactory).deployLPManagement(
            id, typ, target, amountOrPercent, dividendToken, address(this), config.votingFactory, config.lpToken, cashAmount
        );
        lpProposals[id] = prop;
        emit LPMProposalCreated(id, typ);
    }

    function executeLPMProposal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        address prop = lpProposals[id];
        LPManagementType typ = ILPManagementProposal(prop).typ();
        if (typ == LPManagementType.MintMP) {
            address target = ILPManagementProposal(prop).target();
            uint256 amount = ILPManagementProposal(prop).amount();
            mpToken.mint(target, amount);
            emit MPMinted(target, amount);
        } else if (typ == LPManagementType.Dividend) {
            address token = ILPManagementProposal(prop).dividendToken();
            uint256 percent = ILPManagementProposal(prop).percent();
            uint256 totalLP = lpToken.totalSupply();
            uint256 payout = (treasuryBalances[token] * percent) / 100;
            // Placeholder for pro-rata distribution (implement off-chain or Merkle for gas efficiency)
            treasuryBalances[token] -= payout;
            emit DividendPayout(token, percent, payout);
        } else if (typ == LPManagementType.CapitalCall) {
            address treasuryToken = ILPManagementProposal(prop).dividendToken();
            address lpRecipient = ILPManagementProposal(prop).target();
            uint256 lpAmount = ILPManagementProposal(prop).amount();
            uint256 cashAmount = ILPManagementProposal(prop).cashAmount();
            CapitalCall memory call = CapitalCall(treasuryToken, id, lpRecipient, lpAmount, cashAmount);
            bytes32 hash = keccak256(abi.encode(call));
            capitalCalls[hash] = call;
            fulfilledCalls[hash] = false;
            emit CapitalCallCreated(hash, lpRecipient, lpAmount);
        }
    }

    function evaluateDeal(uint256 id, bool success, address oracle) external onlyOracle(oracle) {
        address deal = deals[id];
        if (success) {
            IDeal(deal).transformStakes();
        } else {
            IDeal(deal).slashStakes(100); // Full slash for now
        }
        emit DealEvaluated(id, success);
    }

    function getQuorumPercent() external view returns (uint256) {
        return config.quorumPercent;
    }

    function getTreasuryBalance(address token) external view returns (uint256) {
        return treasuryBalances[token];
    }

    function voteOnProposal(uint256 proposalId, bool support) external {
        // Implement voting logic if needed
    }

    function getLPToken() external view returns (address) {
        return address(lpToken);
    }

    modifier onlyMPHolder() {
        require(mpToken.balanceOf(msg.sender) > 0, "Not MP holder");
        _;
    }

    modifier onlyLPHolder() {
        require(lpToken.balanceOf(msg.sender) > 0, "Not LP holder");
        _;
    }

    modifier onlyDeal() {
        require(dealsMapping[msg.sender] != 0, "Not a deal");
        _;
    }

    modifier onlyOracle(address oracle) {
        require(oracles[oracle], "Not oracle");
        _;
    }

    modifier onlyAfterVote(uint256 id, bool requiredOutcome) {
        address voting = deals[id] != address(0) ? IDeal(deals[id]).votingContract() : ILPManagementProposal(lpProposals[id]).votingContract();
        require(IVoting(voting).isResolved(id) && IVoting(voting).outcome(id) == requiredOutcome, "Vote not passed");
        _;
    }

    // Events
    event DACCreated(address indexed creator, address indexed dac);
    event DealCreated(uint256 indexed id, address indexed creator, address childDAC);
    event DealApproved(uint256 indexed id);
    event CapitalCallFulfilled(bytes32 indexed callHash, address indexed recipient, uint256 lpAmount);
    event ProxyVote(address indexed deal, uint256 indexed childId, bool support, uint256 weight);
    event LPMProposalCreated(uint256 indexed id, LPManagementType typ);
    event MPMinted(address indexed to, uint256 amount);
    event DividendPayout(address indexed token, uint256 percent, uint256 totalPayout);
    event DealEvaluated(uint256 indexed id, bool success);
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed from);
    event CapitalCallCreated(bytes32 indexed callHash, address indexed recipient, uint256 lpAmount);
}