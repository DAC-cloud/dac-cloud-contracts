// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "../interfaces/Structs.sol";
import "../interfaces/IDACEntity.sol";
import "../interfaces/IDACEntityAdapter.sol";
import "../interfaces/IDealCore.sol";
import "../interfaces/IDealAdmin.sol";
import "../interfaces/IDealFactory.sol";
import "../interfaces/IEvaluator.sol";
import "../interfaces/ILPManagementFactory.sol";
import "../interfaces/IEvaluatorFactory.sol";
import "./tokens/LPToken.sol";
import "./tokens/MPToken.sol";
import "./governance/LPManagementProposal.sol";
import "./governance/LPManagementProposals.sol";

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
    event LPMProposalCreated(uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);
    event LPMProposalExecuted(uint256 indexed id, bytes4 typ);
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

        ProposalParams memory dealProposal = ProposalParams({
            typ: LPManagementProposalType.APPROVE_DEAL,
            target: params.fundingToken,
            i: bytes32(params.fundingAmount),
            data: abi.encode(id, 0) // tranche id 0
        });

        uint256 votingId = this.createLPManagementProposal(dealProposal);

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

        ProposalParams memory trancheProposal = ProposalParams({
            typ: LPManagementProposalType.APPROVE_TRANCHE,
            target: fundingToken,
            i: bytes32(fundingAmount),
            data: abi.encode(dealId, trancheId)
        });

        uint256 votingId = this.createLPManagementProposal(trancheProposal);

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

    function createLPManagementProposal(ProposalParams calldata params)
        external
        onlyLPHolderOrSelf
        returns (uint256 id)
    {
        if (msg.sender == address(this)) {
            require(
                (
                    params.typ == LPManagementProposalType.APPROVE_DEAL ||
                    params.typ == LPManagementProposalType.APPROVE_TRANCHE
                ),
                "Type not authorized"
            );
        }
        else {
            require(
                !(
                    params.typ == LPManagementProposalType.APPROVE_DEAL ||
                    params.typ == LPManagementProposalType.APPROVE_TRANCHE
                ),
                "Type not authorized"
            );

            if (params.typ == LPManagementProposalType.RECOVER_DEAL) {
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
        emit LPMProposalCreated(id, params.typ, params.target, params.i, params.data);
        return id;
    }

    function executeLPMProposal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        address prop = lpProposals[id];
        bytes4 typ = LPManagementProposal(prop).typ();

        if (typ == LPManagementProposalType.UPDATE_VOTING_CONFIG) {
            votingConfig = abi.decode(
                LPManagementProposal(prop).data(), 
                (VotingConfig)
            );

            emit VotingConfigUpdate(id, votingConfig);
        }
        
        else if (typ == LPManagementProposalType.UPDATE_LEGAL_WRAPPER) {
            legalWrapper = abi.decode(LPManagementProposal(prop).data(), (LegalWrapper));
            
            emit LegalWrapperSet(id, legalWrapper);
        }

        else if (typ == LPManagementProposalType.APPROVE_OFFCHAIN_ACTION) {
            (bytes4 action, bytes memory actionData) = abi.decode(
                LPManagementProposal(prop).data(), 
                (bytes4, bytes)
            );

            emit OffchainActionApproved(id, action, actionData);
        }

        else if (typ == LPManagementProposalType.MINT_LP_TOKENS) {
            uint256 amount = uint256(LPManagementProposal(prop).i());

            lpToken.mint(address(this), amount);

            treasuryBalances[address(lpToken)] += amount;
            emit TreasuryDeposit(address(lpToken), amount, address(this));
        }

        else if (typ == LPManagementProposalType.REVOKE_MP_TOKENS) {
            address target = LPManagementProposal(prop).target();
            uint256 amount = uint256(LPManagementProposal(prop).i());
            
            mpToken.burnFrom(target, amount);

            emit MPRevoked(target, amount);
        }

        else if (typ == LPManagementProposalType.DIVIDEND_PAYOUT) {
            (address token, uint256 totalPayout, bytes32 merkleRoot) = abi.decode(
                LPManagementProposal(prop).data(), 
                (address, uint256, bytes32)
            );
            
            dividendMerkleRoots[id] = merkleRoot;

            emit DividendPayout(id, token, totalPayout, merkleRoot);
        }

        else if (typ == LPManagementProposalType.CAPITAL_CALL) {
            address lpRecipient = LPManagementProposal(prop).target();
            uint256 lpAmount = uint256(LPManagementProposal(prop).i());

            (address treasuryToken, uint256 cashAmount) = abi.decode(
                LPManagementProposal(prop).data(), 
                (address, uint256)
            );

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

        else if (typ == LPManagementProposalType.ADD_DEAL_FACTORY) {
            address factory = LPManagementProposal(prop).target();

            dealFactories[factory] = true;

            emit TrustedEvaluatorFactoryAdded(factory);
        } 

        else if (typ == LPManagementProposalType.REMOVE_DEAL_FACTORY) {
            if (legalWrapper.wrapperAddr != address(0)) {
                require(msg.sender == legalWrapper.wrapperAddr, "Legal wrapper should execute");
            }

            address factory = LPManagementProposal(prop).target();

            dealFactories[factory] = false;

            emit TrustedEvaluatorFactoryRemoved(factory);
        }

        else if (typ == LPManagementProposalType.ADD_EVALUATOR_FACTORY) {
            address factory = LPManagementProposal(prop).target();

            evaluatorFactories[factory] = true;

            emit TrustedEvaluatorFactoryAdded(factory);
        } 

        else if (typ == LPManagementProposalType.REMOVE_EVALUATOR_FACTORY) {
            address factory = LPManagementProposal(prop).target();

            evaluatorFactories[factory] = false;

            emit TrustedEvaluatorFactoryRemoved(factory);
        }

        else if (
            typ == LPManagementProposalType.APPROVE_DEAL || 
            typ == LPManagementProposalType.APPROVE_TRANCHE
        ) {
            (uint256 dealId, uint256 trancheId) = abi.decode(
                LPManagementProposal(prop).data(),
                (uint256, uint256)
            );
            _approveFunding(dealId, trancheId);
        }

        else if (typ == LPManagementProposalType.DEAL_MESSAGE) {
            // todo: message deal   
        }

        else if (typ == LPManagementProposalType.RECOVER_DEAL) {
            (uint256 dealId) = abi.decode(LPManagementProposal(prop).data(), (uint256));
            address deal = deals[dealId];

            address liquidator = LPManagementProposal(prop).target();
            uint256 amount = uint256(LPManagementProposal(prop).i());

            IDealAdmin(deal).recoverDeal(liquidator, amount);
        }

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

        (address token) = abi.decode(LPManagementProposal(prop).data(), (address));
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