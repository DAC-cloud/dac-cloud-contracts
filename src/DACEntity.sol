// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IDACEntity.sol";
import "./IEvaluator.sol";
import "./Interfaces.sol";
import "./LPToken.sol";
import "./MPToken.sol";
import "./IDeal.sol";
import "./LPManagementProposal.sol";
import "./IEvaluatorFactory.sol";

// Factory interfaces (minimal)
interface IDealFactory {
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken,
        address votingFactory,
        VotingConfig calldata votingConfig
    ) external returns (address, address);
}

interface ILPManagementFactory {
    function deployLPManagement(
        uint256 id,
        LPMParams calldata params,
        address dac,
        address votingFactory,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address);
}

contract DACEntity is IDACEntity, ReentrancyGuard {
    address public immutable deployer;

    LPToken public immutable lpToken;
    MPToken public immutable mpToken;

    Config public config;

    bool public rootCapitalCallInitialized;
    mapping(address => uint256) public treasuryBalances;

    mapping(uint256 => address) public deals;           // id => Deal address
    mapping(uint256 => address) public lpProposals;     // id => LPManagementProposal address
    uint256 public nextId = 1;

    mapping(address => uint256) public dealsMapping;    // Deal address => id (for onlyDeal modifier)
    mapping(address => address) public dealEvaluators;

    mapping(address => bool) public oracles;

    mapping(bytes32 => CapitalCall) public capitalCalls;
    mapping(bytes32 => bool) public fulfilledCalls;

    mapping(address => bool) public trustedEvaluatorFactories;

    // Events
    event DACCreated(address indexed creator, address indexed dac);
    event DealCreated(uint256 indexed id, address indexed creator, address deal, address target, address evaluator);
    event DealApproved(uint256 indexed id);
    event CapitalCallFulfilled(bytes32 indexed callHash, address indexed recipient, uint256 lpAmount);
    event LPMProposalCreated(uint256 indexed id, LPManagementType typ);
    event MPMinted(address indexed to, uint256 amount);
    event DividendPayout(address indexed token, uint256 totalPayout, uint256 merkleRoot);
    event CapitalCallCreated(bytes32 indexed callHash, address indexed recipient, uint256 lpAmount);
    event DealEvaluated(uint256 indexed id, bool success);
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed from);
    event TrustedEvaluatorFactoryAdded(address indexed factory);
    event TrustedEvaluatorFactoryRemoved(address indexed factory);
    event MPRevoked(address indexed target, uint256 amount);

    constructor(
        address _lpToken,
        address _mpToken,
        uint256 _quorum,
        address _dealFactory,
        address _evaluatorFactory,
        address _lpFactory,
        address _votingFactory
    ) {
        config = Config({
            quorumPercent: _quorum,
            lpToken: _lpToken,
            mpToken: _mpToken,
            votingFactory: _votingFactory,
            dealFactory: _dealFactory,
            evaluatorFactory: _evaluatorFactory,
            lpFactory: _lpFactory,
            votingConfig: VotingConfig({   // DEFAULTS — change here or via governance later
                quorumPercent: 50,
                defaultDuration: 7 days
            })
        });

        lpToken = LPToken(_lpToken);
        mpToken = MPToken(_mpToken);

        deployer = msg.sender;
        rootCapitalCallInitialized = false;

        emit DACCreated(msg.sender, address(this));
    }

    function initializeRootCapitalCall(
        address treasuryToken,
        address lpRecipient,
        uint256 lpAmount,
        uint256 cashAmount
    ) external {
        require(msg.sender == deployer, "Only deployer");
        require(!rootCapitalCallInitialized, "Already initialized");

        CapitalCall memory call = CapitalCall({
            treasuryToken: treasuryToken,
            nonce: 0,                   // special root nonce
            lpRecipient: lpRecipient,
            lpAmount: lpAmount,
            cashAmount: cashAmount
        });

        bytes32 callHash = keccak256(abi.encode(call));
        capitalCalls[callHash] = call;
        fulfilledCalls[callHash] = false;

        rootCapitalCallInitialized = true;

        emit CapitalCallCreated(callHash, lpRecipient, lpAmount);
    }

    function depositTreasury(address token, uint256 amount) external nonReentrant {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        treasuryBalances[token] += amount;
        emit TreasuryDeposit(token, amount, msg.sender);
    }

    function createDealProposal(DealParams calldata params)
        external
        onlyMPHolder
        returns (uint256 id, address dealAddr, address evaluatorAddr)
    {
        require(trustedEvaluatorFactories[params.evaluatorFactory], "Untrusted evaluator factory");

        require(params.proposer == msg.sender, "Proposer must be msg.sender");

        id = nextId++;

        (dealAddr, evaluatorAddr) = IDealFactory(config.dealFactory).deployDeal(
            id,
            params,
            address(this),
            config.mpToken,
            config.lpToken,
            config.votingFactory,
            config.votingConfig
        );

        deals[id] = dealAddr;
        dealsMapping[dealAddr] = id;
        dealEvaluators[dealAddr] = evaluatorAddr; // optional, for easy lookup

        IERC20(params.fundingToken).approve(dealAddr, params.fundingAmount);

        emit DealCreated(id, msg.sender, dealAddr, params.dealTarget, evaluatorAddr);
    }

    function approveDeal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        address deal = deals[id];
        require(deal != address(0), "Invalid deal ID");

        uint256 amount = IDeal(deal).fundingAmount();
        address token = IDeal(deal).fundingToken();

        require(treasuryBalances[token] >= amount, "Insufficient treasury");

        IERC20(token).transfer(deal, amount);
        treasuryBalances[token] -= amount;

        IDeal(deal).onApproved();
        emit DealApproved(id);
    }

    function fulfillCapitalCall(CapitalCall calldata call) external nonReentrant returns (bool) {
        bytes32 callHash = keccak256(abi.encode(call));
        require(!fulfilledCalls[callHash], "Already fulfilled");

        IERC20(call.treasuryToken).transferFrom(msg.sender, address(this), call.cashAmount);
        treasuryBalances[call.treasuryToken] += call.cashAmount;

        lpToken.mint(call.lpRecipient, call.lpAmount);

        fulfilledCalls[callHash] = true;
        emit CapitalCallFulfilled(callHash, call.lpRecipient, call.lpAmount);
        return true;
    }

    function createLPManagementProposal(LPMParams calldata params)
        external
        onlyLPHolder
        returns (uint256 id)
    {
        id = nextId++;
        address prop = ILPManagementFactory(config.lpFactory).deployLPManagement(
            id,
            params,
            address(this),
            config.votingFactory,
            config.lpToken,
            config.votingConfig
        );

        lpProposals[id] = prop;
        emit LPMProposalCreated(id, params.typ);
        return id;
    }

    function executeLPMProposal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        address prop = lpProposals[id];
        LPManagementType typ = LPManagementProposal(prop).typ();

        if (typ == LPManagementType.MintMP) {
            address target = LPManagementProposal(prop).target();
            uint256 amount = LPManagementProposal(prop).getMPAmount();
            mpToken.mint(target, amount);
            emit MPMinted(target, amount);
        }
        else if (typ == LPManagementType.Dividend) {
            address token = LPManagementProposal(prop).getDividendToken();
            uint256 amount = LPManagementProposal(prop).getCashAmount();
            // TODO: Merkle root
            // TODO: Store dividend payout in state for future claims
            emit DividendPayout(token, amount, 0);
        }
        else if (typ == LPManagementType.CapitalCall) {
            address treasuryToken = LPManagementProposal(prop).getDividendToken();
            address lpRecipient = LPManagementProposal(prop).target();
            uint256 lpAmount = LPManagementProposal(prop).getLPAmount();
            uint256 cashAmount = LPManagementProposal(prop).getCashAmount();

            CapitalCall memory call = CapitalCall({
                treasuryToken: treasuryToken,
                nonce: id,
                lpRecipient: lpRecipient,
                lpAmount: lpAmount,
                cashAmount: cashAmount
            });

            bytes32 hash = keccak256(abi.encode(call));
            capitalCalls[hash] = call;
            fulfilledCalls[hash] = false;
            emit CapitalCallCreated(hash, lpRecipient, lpAmount);
        }
        else if (typ == LPManagementType.AddTrustedEvaluatorFactory) {
            address factory = LPManagementProposal(prop).target();
            trustedEvaluatorFactories[factory] = true;
            emit TrustedEvaluatorFactoryAdded(factory);
        } 
        else if (typ == LPManagementType.RemoveTrustedEvaluatorFactory) {
            address factory = LPManagementProposal(prop).target();
            trustedEvaluatorFactories[factory] = false;
            emit TrustedEvaluatorFactoryRemoved(factory);
        } 
        else if (typ == LPManagementType.RevokeMP) {
            address target = LPManagementProposal(prop).target();
            uint256 amount = LPManagementProposal(prop).getMPAmount();
            mpToken.burnFrom(target, amount);
            emit MPRevoked(target, amount);
        }
    }

    function mintLP(address deal, address to, uint256 amount) external {
        require(msg.sender == address(this) || msg.sender == deal, "Only DAC/Deal");
        lpToken.mint(to, amount);
    }

    function forceReturnCapital(uint256 id) external onlyLPHolder {
        address deal = deals[id];
        require(deal != address(0), "Invalid deal");
        IDeal(deal).returnCapitalToDAC();
    }

    function _performTransformation(uint256 id, uint256 transformationPercent) internal {
        address deal = deals[id];
        IDeal(deal).markAsSuccess(transformationPercent);
    }

    function _performSlash(uint256 id, uint256 slashPercent) internal {
        address deal = deals[id];
        uint256 totalMP = IDeal(deal).getStakedMPTotal();
        MPToken(mpToken).burnFrom(deal, totalMP);
        IDeal(deal).markAsFailed(slashPercent);
    }

    function evaluateDeal(uint256 id) external onlyMPHolder {
        address deal = deals[id];
        require(deal != address(0), "Invalid deal");

        address evaluatorAddr = dealEvaluators[deal];
        EvaluationResult memory result = IEvaluator(evaluatorAddr).evaluateDeal(id, deal, address(this));

        if (result.action == 0) { // slash
            _performSlash(id, result.percent);
        } else if (result.action == 1) { // convert
            _performTransformation(id, result.percent);
        } else if (result.action == 2) { // extend
            IDeal(deal).extendDeadline(result.newDeadline);
        } else if (result.action == 3) { // close
            IDeal(deal).closeDeal();
        }

        if (result.action == 1 || result.action == 0) {
            emit DealEvaluated(id, result.action == 1);
        }
    }

    function getQuorumPercent() external view returns (uint256) {
        return config.quorumPercent;
    }

    function getTreasuryBalance(address token) external view returns (uint256) {
        return treasuryBalances[token];
    }

    function getProposalVoting(uint256 proposalId) external view returns (address) {
        return LPManagementProposal(lpProposals[proposalId]).votingContract();
    }

    function getLPToken() external view returns (address) {
        return address(lpToken);
    }

    modifier onlyMPHolder() {
        _onlyMPHolder();
        _;
    }

    modifier onlyLPHolder() {
        _onlyLPHolder();
        _;
    }

    modifier onlyDeal() {
        _onlyDeal();
        _;
    }

    modifier onlyOracle(address oracle) {
        _onlyOracle(oracle);
        _;
    }

    modifier onlyAfterVote(uint256 id, bool requiredOutcome) {
        _onlyAfterVote(id, requiredOutcome);
        _;
    }

    function _onlyMPHolder() internal view {
        require(mpToken.balanceOf(msg.sender) > 0, "Not MP holder");
    }

    function _onlyLPHolder() internal view {
        require(lpToken.balanceOf(msg.sender) > 0, "Not LP holder");
    }

    function _onlyDeal() internal view {
        require(dealsMapping[msg.sender] != 0, "Not a Deal");
    }

    function _onlyOracle(address oracle) internal view {
        require(oracles[oracle], "Not oracle");
    }

    function _onlyAfterVote(uint256 id, bool requiredOutcome) internal view {
        address votingAddr = deals[id] != address(0)
            ? IDeal(deals[id]).votingContract()
            : LPManagementProposal(lpProposals[id]).votingContract();

        require(
            IVoting(votingAddr).isResolved(id) &&
            IVoting(votingAddr).outcome(id) == requiredOutcome,
            "Vote not passed"
        );
    }
}