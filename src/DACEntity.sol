// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./Structs.sol";
import "./IDACEntity.sol";
import "./IDACEntityAdapter.sol";
import "./IDealCore.sol";
import "./IDealAdmin.sol";
import "./IDealFactory.sol";
import "./IEvaluator.sol";
import "./ILPManagementFactory.sol";
import "./LPToken.sol";
import "./MPToken.sol";
import "./LPManagementProposal.sol";
import "./IEvaluatorFactory.sol";

contract DACEntity is IDACEntity, IDACEntityAdapter, ReentrancyGuard {
    address public immutable deployer;

    LPToken public lpToken;
    MPToken public mpToken;

    address public proposalFactory;
    VotingConfig public votingConfig;

    string public name;
    string public description;

    LegalWrapper public legalWrapper;

    mapping(bytes32 => CapitalCall) public capitalCalls;
    mapping(bytes32 => bool) public fulfilledCalls;

    mapping(address => bool) public evaluatorFactories;
    mapping(address => bool) public dealFactories;

    bool public rootCapitalCallInitialized;
    mapping(address => uint256) public treasuryBalances;

    uint256 public nextId = 1;
    mapping(uint256 => address) public deals;                   // id => Deal address
    mapping(uint256 => address) public lpProposals;             // id => LPManagementProposal address

    mapping(address => IDealFactory) public dealFactory;        // Deal address => id (for onlyDeal modifier)
    mapping(address => address) public dealEvaluators;

    mapping(uint256 => bytes32) public dividendMerkleRoots;     // proposalId => root
    mapping(bytes32 => bool) public dividendClaimed;            // keccak(root + leaf) => claimed

    // Events
    event DACCreated(address indexed creator, address indexed dac, string name);
    event DealCreated(uint256 indexed id, uint256 indexed proposalId, address indexed creator, bytes4 kind, address deal, address target, address evaluator);
    event TrancheCreated(uint256 indexed id, uint256 indexed proposalId, uint256 trancheId);
    event FundingApproved(uint256 indexed id, uint256 trancheId);
    event CapitalCallFulfilled(bytes32 indexed callHash, address indexed recipient, uint256 lpAmount);
    event LPMProposalCreated(uint256 indexed id, LPManagementType typ, address target, uint256 amount, bytes data);
    event LPMProposalExecuted(uint256 indexed id, LPManagementType typ);
    event MPMinted(address indexed to, uint256 amount);
    event DividendPayout(uint256 payoutId, address indexed token, uint256 totalPayout, bytes32 merkleRoot);
    event DividendClaimed(uint256 payoutId, address indexed token, uint256 amountPayout);
    event CapitalCallCreated(bytes32 indexed callHash, address indexed recipient, uint256 lpAmount);
    event DealEvaluated(uint256 indexed id, bool success);
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed from);
    event TrustedEvaluatorFactoryAdded(address indexed factory);
    event TrustedEvaluatorFactoryRemoved(address indexed factory);
    event MPRevoked(address indexed target, uint256 amount);
    event VotingConfigUpdate(uint256 indexed id, VotingConfig config);
    event LegalWrapperSet(uint256 indexed id, LegalWrapper legalWrapper);
    event LegalWrapperMessage(address indexed wrapper, bytes4 messageKind, bytes message);
    event OffchainActionApproved(uint256 indexed id, bytes4 action, bytes data);

    constructor(
        string memory _name,
        string memory _description,
        uint256 _quorum,
        address _proposalFactory
    ) {
        name = _name;
        description = _description;

        proposalFactory = _proposalFactory;
        votingConfig = VotingConfig({   // DEFAULTS — changed via governance later
            quorumPercent: _quorum,
            highQuorumPercent: (100 + _quorum) / 2,
            blockingPercent: _quorum / 2,
            duration: 7 days
        });

        initialized = false;
        deployer = msg.sender;
        rootCapitalCallInitialized = false;

        emit DACCreated(msg.sender, address(this), name);
    }

    bool public initialized;

    function initializeAfterDeployment(
        address _lpToken,
        address _mpToken,
        address _dealFactory,
        address _evaluatorFactory
    ) external {
        require(msg.sender == deployer, "Only self");
        require(!initialized, "Already initialized");

        lpToken = LPToken(_lpToken);
        mpToken = MPToken(_mpToken);

        dealFactories[_dealFactory] = true;
        evaluatorFactories[_evaluatorFactory] = true;

        // Any post-deployment setup you want (e.g. set factories later via proposals)
        initialized = true;
    }

    function initializeRootCapitalCall(
        address treasuryToken,
        address lpRecipient,
        uint256 lpAmount,
        uint256 cashAmount
    ) external {
        require(initialized, "Not initialized");
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
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        treasuryBalances[token] += amount;
        emit TreasuryDeposit(token, amount, msg.sender);
    }

    function fulfillCapitalCall(CapitalCall calldata call) external nonReentrant returns (bool) {
        bytes32 callHash = keccak256(abi.encode(call));
        require(!fulfilledCalls[callHash], "Already fulfilled");
        
        CapitalCall memory capitalCall = capitalCalls[callHash];
        require(capitalCall.lpAmount > 0, "Invalid capital call");

        require(
            IERC20(call.treasuryToken).transferFrom(msg.sender, address(this), call.cashAmount), 
            "Transfer failed"
        );
        treasuryBalances[call.treasuryToken] += call.cashAmount;

        lpToken.mint(call.lpRecipient, call.lpAmount);

        fulfilledCalls[callHash] = true;
        emit CapitalCallFulfilled(callHash, call.lpRecipient, call.lpAmount);
        return true;
    }

    function createDealProposal(DealParams calldata params)
        external
        onlyMPHolder
        returns (uint256 id, address dealAddr, address evaluatorAddr)
    {
        require(dealFactories[params.dealFactory], "Untrusted deal factory");
        require(evaluatorFactories[params.evaluatorFactory], "Untrusted evaluator factory");

        require(params.proposer == msg.sender, "Proposer must be msg.sender");

        require(IDealFactory(params.dealFactory).isActive(), "Deal factory is paused");

        id = nextId++;

        (dealAddr, evaluatorAddr) = IDealFactory(params.dealFactory).deployDeal(
            id,
            params,
            address(this),
            address(mpToken),
            address(lpToken),
            votingConfig
        );

        deals[id] = dealAddr;
        dealFactory[dealAddr] = IDealFactory(params.dealFactory);
        dealEvaluators[dealAddr] = evaluatorAddr;

        LPMParams memory dealVote = LPMParams({
            typ: LPManagementType.ApproveDeal,
            target: params.fundingToken,
            amount: params.fundingAmount,
            data: abi.encode(0, id) // tranche id 0
        });

        uint256 votingId = this.createLPManagementProposal(dealVote);

        emit DealCreated(id, votingId, msg.sender, params.dealKind, dealAddr, params.dealTarget, evaluatorAddr);
    }

    function createTrancheProposal(
        uint256 dealId,
        uint256 trancheId
    ) external onlyDeal {
        address deal = deals[dealId];
        require(msg.sender == deal, "Invalid deal ID");

        address fundingToken = IDealCore(deal).fundingToken(trancheId);
        uint256 fundingAmount = IDealCore(deal).fundingAmount(trancheId);
        require(fundingAmount > 0, "Invalid tranche");

        LPMParams memory trancheVote = LPMParams({
            typ: LPManagementType.ApproveTranche,
            target: fundingToken,
            amount: fundingAmount,
            data: abi.encode(trancheId, dealId)
        });

        uint256 votingId = this.createLPManagementProposal(trancheVote);

        emit TrancheCreated(dealId, trancheId, votingId);
    }

    function _approveFunding(uint256 id, uint256 trancheId) internal {
        address deal = deals[id];
        require(deal != address(0), "Invalid deal ID");

        uint256 amount = IDealCore(deal).fundingAmount(trancheId);
        address token = IDealCore(deal).fundingToken(trancheId);

        require(treasuryBalances[token] >= amount, "Insufficient treasury");

        if (amount > 0) {
            require(IERC20(token).transfer(deal, amount), "Transfer failed");
            treasuryBalances[token] -= amount;
        }
        else {
            require(trancheId == 0, "Invalid tranche");
        }

        IDealAdmin(deal).onApproved(trancheId);
        emit FundingApproved(id, trancheId);
    }

    function logLegalWrapperMessage(uint256 id, bytes4 kind, bytes calldata message) external onlyLegalWrapper {
        if (id == 0) {
            emit LegalWrapperMessage(msg.sender, kind, message);
        }
        else {
            //todo send message to deal
        }
    }

    function createLPManagementProposal(LPMParams calldata params)
        external
        onlyLPHolderOrSelf
        returns (uint256 id)
    {
        if (msg.sender == address(this)) {
            require(
                (
                    params.typ == LPManagementType.ApproveDeal ||
                    params.typ == LPManagementType.ApproveTranche
                ),
                "Type not authorized"
            );
        }
        else {
            require(
                !(
                    params.typ == LPManagementType.ApproveDeal ||
                    params.typ == LPManagementType.ApproveTranche
                ),
                "Type not authorized"
            );

            if (params.typ == LPManagementType.RecoverDeal) {
                (uint256 dealId) = abi.decode(params.data, (uint256));

                address deal = deals[dealId];
                require(deal != address(0), "Invalid deal");
                
                require(
                    IDealCore(deal).isClosed(),
                    "Invalid deal state"
                );

                require(
                    IDealCore(deal).getStakedMPTotal() == 0,
                    "Invalid deal management state"
                );
            }
        }

        id = nextId++;
        
        address prop = ILPManagementFactory(proposalFactory).deployLPManagement(
            id,
            params,
            address(this),
            address(lpToken),
            votingConfig
        );

        lpProposals[id] = prop;
        emit LPMProposalCreated(id, params.typ, params.target, params.amount, params.data);
        return id;
    }

    function executeLPMProposal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        address prop = lpProposals[id];
        LPManagementType typ = LPManagementProposal(prop).typ();

        if (typ == LPManagementType.UpdateLegalWrapper) {
            legalWrapper = LPManagementProposal(prop).getLegalWrapper();
            
            emit LegalWrapperSet(id, legalWrapper);
        }

        else if (typ == LPManagementType.ApproveOffchainAction) {
            (bytes4 action, bytes memory actionData) = LPManagementProposal(prop).getOffchainActionData();

            emit OffchainActionApproved(id, action, actionData);
        }

        else if (typ == LPManagementType.MintMP) {
            address target = LPManagementProposal(prop).target();
            uint256 amount = LPManagementProposal(prop).getMPAmount();

            mpToken.mint(target, amount);

            emit MPMinted(target, amount);
        }

        else if (typ == LPManagementType.Dividend) {
            address token = LPManagementProposal(prop).getDividendToken();
            bytes32 merkleRoot = LPManagementProposal(prop).getMerkleRoot();
            uint256 totalPayout = LPManagementProposal(prop).getCashAmount();
            
            dividendMerkleRoots[id] = merkleRoot;

            emit DividendPayout(id, token, totalPayout, merkleRoot);
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

            evaluatorFactories[factory] = true;

            emit TrustedEvaluatorFactoryAdded(factory);
        } 

        else if (typ == LPManagementType.RemoveTrustedEvaluatorFactory) {
            address factory = LPManagementProposal(prop).target();

            evaluatorFactories[factory] = false;

            emit TrustedEvaluatorFactoryRemoved(factory);
        } 

        else if (typ == LPManagementType.RevokeMP) {
            address target = LPManagementProposal(prop).target();
            uint256 amount = LPManagementProposal(prop).getMPAmount();
            
            mpToken.burnFrom(target, amount);

            emit MPRevoked(target, amount);
        }

        else if (typ == LPManagementType.UpdateVotingConfig) {
            votingConfig = LPManagementProposal(prop).getVotingConfiguration();

            emit VotingConfigUpdate(id, votingConfig);
        }

        else if (typ == LPManagementType.RecoverDeal) {
            uint256 dealId = LPManagementProposal(prop).getRecoveredDealId();
            address deal = deals[dealId];

            address liquidator = LPManagementProposal(prop).target();
            uint256 amount = LPManagementProposal(prop).getMPAmount();

            IDealAdmin(deal).recoverDeal(liquidator, amount);
        }

        else if (
            typ == LPManagementType.ApproveDeal || 
            typ == LPManagementType.ApproveTranche
        ) {
            uint256 dealId = LPManagementProposal(prop).getDealId();
            uint256 trancheId = LPManagementProposal(prop).getTrancheId();
            _approveFunding(dealId, trancheId);
        }

        // todo: add/remove trusted deal factory (for remove, if legal wrapper active, require legal wrapper to execute)

        // todo: message deal

        emit LPMProposalExecuted(id, typ);
    }

    function mintLP(address deal, address to, uint256 amount) external onlyDeal {
        require(msg.sender == deal, "Invalid deal");

        // TODO: evaluator shall permint mint
        //  thus evaluator can become an oracle for last-resort protection between
        //  vulnerabilities in the particular Deal contract that we trust.
        
        // Basic logic for evaluator - revert any mintLP call, until someone presses the button on the web
        // and signs with EOA, then there is a 12 hours window, and if no other EOA objects and provide
        // to an AI agent reasonable claims about a hack in a Deal - evaluator approves the single mint

        lpToken.mint(to, amount);
    }

    function forceReturnCapital(uint256 id) external onlyLPHolderOrSelf {
        address deal = deals[id];
        require(deal != address(0), "Invalid deal");
        IDealCore(deal).returnCapitalToDAC();
    }

    function claimDividend(
        uint256 proposalId,
        uint256 index,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        bytes32 root = dividendMerkleRoots[proposalId];
        require(root != bytes32(0), "No dividend for this proposal");

        bytes32 leaf = keccak256(abi.encodePacked(index, msg.sender, amount));

        bytes32 claimedKey = keccak256(abi.encodePacked(root, leaf));
        require(!dividendClaimed[claimedKey], "Already claimed");

        require(MerkleProof.verify(proof, root, leaf), "Invalid Merkle proof");

        dividendClaimed[claimedKey] = true;

        address prop = lpProposals[proposalId];

        address token = LPManagementProposal(prop).getDividendToken();
        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");

        emit DividendClaimed(proposalId, msg.sender, amount);
    }

    function _performTransformation(uint256 id, uint256 transformationPercent) internal {
        address deal = deals[id];
        IDealAdmin(deal).markAsSuccess(transformationPercent);
    }

    function _performSlash(uint256 id, uint256 slashPercent) internal {
        address deal = deals[id];
        uint256 totalMP = IDealCore(deal).getStakedMPTotal();
        MPToken(mpToken).burnFrom(deal, totalMP);
        IDealAdmin(deal).markAsFailed(slashPercent);
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
            IDealAdmin(deal).extendDeadline(result.newDeadline);
        } else if (result.action == 3) { // close
            IDealAdmin(deal).closeDeal();
        }

        if (result.action == 1 || result.action == 0) {
            emit DealEvaluated(id, result.action == 1);
        }
    }

    function getCapitalCall(bytes32 calldataHash) external view returns (CapitalCall memory capitalCall) {
        require(!fulfilledCalls[calldataHash], "Already fulfilled");
        capitalCall = capitalCalls[calldataHash];
        require(capitalCall.lpAmount > 0, "Invalid capital call");
    }

    function getProposalVoting(uint256 proposalId) external view returns (address) {
        return lpProposals[proposalId];
    }

    function getLPToken() external view returns (address) {
        return address(lpToken);
    }

    function getMPToken() external view returns (address) {
        return address(lpToken);
    }

    modifier onlyMPHolder() {
        _onlyMPHolder();
        _;
    }

    modifier onlyLPHolderOrSelf() {
        _onlyLPHolderOrSelf();
        _;
    }

    modifier onlyMPOrLPHolder() {
        _onlyMPOrLPHolder();
        _;
    }

    modifier onlyDeal() {
        _onlyDeal(msg.sender);
        _;
    }

    modifier onlyDealOrSelf() {
        _onlyDealOrSelf();
        _;
    }

    modifier onlyLegalWrapper() {
        _onlyLegalWrapper();
        _;
    }

    modifier onlyAfterVote(uint256 id, bool requiredOutcome) {
        _onlyAfterVote(id, requiredOutcome);
        _;
    }

    function _onlyMPHolder() internal view {
        require(mpToken.balanceOf(msg.sender) > 0, "Not MP holder");
    }

    function _onlyLPHolderOrSelf() internal view {
        require(
            (
                msg.sender == address(this) ||
                lpToken.balanceOf(msg.sender) > 0
            ), 
            "Not authorized"
        );
    }

    function _onlyMPOrLPHolder() internal view {
        require(
            (
                lpToken.balanceOf(msg.sender) > 0 ||
                mpToken.balanceOf(msg.sender) > 0
            ), 
            "Not MP or LP holder"
        );
    }

    function _onlyDealOrSelf() internal view {
        if (msg.sender != address(this)) {
            _onlyDeal(msg.sender);
        }
    }

    function _onlyDeal(address deal) internal view {
        require(
            IDealFactory(dealFactory[deal]).isActive(), 
            "Not a valid Deal"
        );
    }

    function _onlyLegalWrapper() internal view {
        require(legalWrapper.wrapperAddr != address(0), "Legal Wrapper not set");
        require(legalWrapper.wrapperAddr == msg.sender, "Not a Legal Wrapper");
    }

    function _onlyAfterVote(uint256 id, bool requiredOutcome) internal view {
        require(
            IVoting(lpProposals[id]).isResolved() &&
            IVoting(lpProposals[id]).outcome() == requiredOutcome,
            "Vote not passed"
        );
    }
}