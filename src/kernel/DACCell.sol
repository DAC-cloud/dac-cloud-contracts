// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProposalParams, VotingConfig, CapitalCall, LegalWrapper} from "../interfaces/Structs.sol";
import {IVotes} from "../lib/IVotes.sol";
import {IVoting} from "../interfaces/IVoting.sol";
import {IDACCellAdapter} from "../interfaces/IDACCellAdapter.sol";
import {IDealManager} from "../interfaces/IDealManager.sol";
import {IDACCell} from "../interfaces/IDACCell.sol";
import {CapitalCallState} from "./interfaces/Structs.sol";
import {IDealManagerAdapter} from "./interfaces/IDealManagerAdapter.sol";
import {MainToken} from "./tokens/MainToken.sol";
import {AgentToken} from "./tokens/AgentToken.sol";
import {DealManagerFactory} from "./factories/DealManagerFactory.sol";
import {DACManagementProposal} from "./governance/DACManagementProposal.sol";
import {DACManagementProposalType} from "./governance/DACManagementProposals.sol";
import {DACCellGovernanceLib} from "./libraries/DACCellGovernanceLib.sol";

contract DACCell is IDACCell, IDACCellAdapter, ReentrancyGuard {
    
    // Errors
    error NotAllowed();
    error NotAuthorized();
    error NotInitialized();
    error AlreadyInitialized();

    error VoteNotPassed();

    error ProposalAlreadyExecuted();
    error InvalidDeal(address deal);
    error InvalidDealId(uint256 deal);
    error TransferFailed();

    error InvalidCapitalCall();
    error AlreadyFulfilled();

    error LegalWrapperNotSet();
    error LegalWrapperExecutionExpected();

    // DACCell has no upgrade or pause capabilities by design.
    
    // Deployer role limited to initialization call only, in fact deployer will be always 
    // a Create2 DACFactory, and once initialized, DACCell is independent of the factory.
    address private immutable deployer;

    // Tokens for chickens and pigs
    MainToken private mainToken;
    AgentToken private agentToken;

    // Deal manager
    address public dealManager;

    address private proposalFactory;
    VotingConfig private votingConfig;

    string private name;
    string private description;

    LegalWrapper private legalWrapper;

    mapping(bytes32 => CapitalCallState) private capitalCalls;
    
    bool private rootCapitalCallInitialized;
    mapping(address => uint256) private treasuryBalances;

    uint256 private nextId = 1;
    mapping(uint256 => address) private proposals;               // id => DACManagementProposal address
    mapping(uint256 => bool) private executed;                   // id => proposal executed (set early)

    bool private dividendsEnabled;
    mapping(uint256 => bytes32) private dividendMerkleRoots;     // proposalId => root
    mapping(bytes32 => bool) private dividendClaimed;            // keccak(root + leaf) => claimed

    // Events
    event DACCreated(address indexed creator, string name);

    event VotingConfigUpdate(uint256 indexed id, VotingConfig config);
    event LegalWrapperMessage(address indexed wrapper, bytes4 messageKind, bytes message);
    event DividendsConfigUpdate(uint256 indexed id, bool enabled);

    // Indexed by proposal id
    event DACProposalExecuted(uint256 indexed id, bytes4 indexed typ);

    event TokenMinted(uint256 indexed id, uint256 amount);
    event TokenBurnt(uint256 indexed id, uint256 amount);

    event AgentTokenMinted(uint256 indexed id, address indexed agent, uint256 amount);
    event AgentTokenRevoked(uint256 indexed id, address indexed agent, uint256 amount);

    event CapitalCallCreated(uint256 indexed id, address indexed recipient, bytes32 callHash, uint256 amount);
    
    event LegalWrapperSet(uint256 indexed id, LegalWrapper legalWrapper);
    event OffchainActionApproved(uint256 indexed id, bytes4 action, bytes data);
    event DividendPayout(uint256 payoutId, address indexed token, uint256 totalPayout, bytes32 merkleRoot);
    
    constructor(
        address _globalFactory,
        string memory _name,
        string memory _description,
        address _proposalFactory
    ) {
        name = _name;
        description = _description;

        proposalFactory = _proposalFactory;

        deployer = _globalFactory;

        initialized = false;
        rootCapitalCallInitialized = false;

        emit DACCreated(msg.sender, name);
    }

    bool public initialized;

    function initializeAfterDeployment(
        address _mainToken,
        address _agentToken,
        address managerFactory,
        address coreModule,
        bool _dividendsEnabled,
        uint256 _quorum
    ) external {
        require(msg.sender == deployer, NotAuthorized());
        require(!initialized, AlreadyInitialized());

        mainToken = MainToken(_mainToken);
        agentToken = AgentToken(_agentToken);

        dividendsEnabled = _dividendsEnabled;

        votingConfig = VotingConfig({   // DEFAULTS — changed via governance later
            quorumPercent: _quorum,
            highQuorumPercent: (100 + _quorum) / 2,
            blockingPercent: (100 - _quorum) / 2,
            duration: 7 days,
            qualification: 0
        });

        dealManager = DealManagerFactory(managerFactory).deployDealManager(
            _mainToken,
            _agentToken,
            coreModule,
            address(this)
        );

        initialized = true;
    }

    function initializeRootCapitalCall(
        address treasuryToken,
        address recipient,
        uint256 amount,
        uint256 cashAmount
    ) external {
        require(initialized, NotInitialized());
        require(msg.sender == deployer, NotAuthorized());
        require(!rootCapitalCallInitialized, AlreadyInitialized());

        CapitalCall memory call = CapitalCall({
            treasuryToken: treasuryToken,
            nonce: 0, // special nonce for root capital call
            tokenRecipient: recipient,
            tokenAmount: amount,
            cashAmount: cashAmount
        });

        bytes32 callHash = keccak256(abi.encode(call));

        capitalCalls[callHash] = CapitalCallState({
            call: call,
            fulfilled: false
        });

        rootCapitalCallInitialized = true;

        emit CapitalCallCreated(0, recipient, callHash, amount);
    }

    function depositTreasury(address token, uint256 amount) external nonReentrant {
        return DACCellGovernanceLib.depositTreasury(
            token, amount, dealManager, treasuryBalances
        );
    }

    function recoverTreasury(address token) external nonReentrant onlyHolderOrManager {
        return DACCellGovernanceLib.recoverTreasury(
            token, treasuryBalances
        );
    }

    function fulfillCapitalCall(CapitalCall calldata call) external nonReentrant returns (bool) {
        return DACCellGovernanceLib.fulfillCapitalCall(
            call, mainToken, capitalCalls, treasuryBalances
        );
    }

    function logLegalWrapperMessage(bytes4 kind, bytes calldata message) 
        external 
        onlyLegalWrapper 
        nonReentrant
    {
        emit LegalWrapperMessage(msg.sender, kind, message);
    }

    function createManagementProposal(ProposalParams calldata params)
        external
        onlyHolderOrManager
        nonReentrant
        returns (uint256 id)
    {
        id = DACCellGovernanceLib.createManagementProposal(
            nextId,
            params,
            votingConfig,
            proposalFactory,
            mainToken,
            dividendsEnabled,
            IDealManager(dealManager).totalReleasedVotable(),
            IDealManager(dealManager),
            proposals
        );

        nextId++;
    }

    function executeDACProposal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        require(!executed[id], ProposalAlreadyExecuted());
        executed[id] = true;
        
        DACManagementProposal prop = DACManagementProposal(proposals[id]);
        bytes4 typ = prop.typ();
        
        if (typ == DACManagementProposalType.UPDATE_VOTING_CONFIG) {
            votingConfig = abi.decode(prop.data(), (VotingConfig));

            emit VotingConfigUpdate(id, votingConfig);
        }
        
        else if (typ == DACManagementProposalType.UPDATE_LEGAL_WRAPPER) {
            legalWrapper = abi.decode(prop.data(), (LegalWrapper));

            emit LegalWrapperSet(id, legalWrapper);
        }

        else if (typ == DACManagementProposalType.APPROVE_OFFCHAIN_ACTION) {
            (bytes4 selector, bytes memory data) = abi.decode(
                prop.data(), 
                (bytes4, bytes)
            );

            emit OffchainActionApproved(
                id, 
                selector, 
                data
            );
        }

        else if (typ == DACManagementProposalType.MINT_MAIN_TOKENS) {
            mainToken.mint(address(this), uint256(prop.i()));

            treasuryBalances[address(mainToken)] += uint256(prop.i());
            emit TokenMinted(id, uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.BURN_MAIN_TOKENS) {
            mainToken.burn(uint256(prop.i()));

            emit TokenBurnt(id, uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.MINT_AGENT_TOKENS) {
            agentToken.mint(address(prop.target()), uint256(prop.i()));

            treasuryBalances[address(mainToken)] += uint256(prop.i());
            emit AgentTokenMinted(id, prop.target(), uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.REVOKE_AGENT_TOKENS) {
            agentToken.burnFrom(prop.target(), uint256(prop.i()));

            emit AgentTokenRevoked(id, prop.target(), uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.CAPITAL_CALL) {
            DACCellGovernanceLib.executeCapitalCall(id, prop, capitalCalls);
        }

        else if (typ == DACManagementProposalType.TOGGLE_DIVIDENDS) {
            require(msg.sender == legalWrapper.wrapperAddr, LegalWrapperExecutionExpected());

            dividendsEnabled = abi.decode(prop.data(), (bool));

            emit DividendsConfigUpdate(id, dividendsEnabled);
        }

        else if (typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
            (address token, uint256 totalPayout, bytes32 merkleRoot) = abi.decode(
                DACManagementProposal(prop).data(), 
                (address, uint256, bytes32)
            );
            
            dividendMerkleRoots[id] = merkleRoot;

            emit DividendPayout(id, token, totalPayout, merkleRoot);
        }

        else if (
            typ == DACManagementProposalType.APPROVE_DEAL || 
            typ == DACManagementProposalType.APPROVE_TRANCHE
        ) {
            DACCellGovernanceLib.approveFunding(
                prop, treasuryBalances, IDealManager(dealManager)
            );
        }

        else if (
            typ == DACManagementProposalType.CAST_VETO_DEAL
        ) {
            DACCellGovernanceLib.castVeto(
                prop, IDealManager(dealManager)
            );
        }

        else if (
            typ == DACManagementProposalType.DELEGATE_VOTE_RIGHTS
        ) {
            (address token, address delegatee) = abi.decode(
                DACManagementProposal(prop).data(), 
                (address, address)
            );

            IVotes(token).delegate(delegatee);
        }

        else {
            IDealManagerAdapter(dealManager).executeProp(msg.sender, prop);
        }

        emit DACProposalExecuted(id, typ);
    }

    function getVotingConfig() external view returns (VotingConfig memory config) {
        config = votingConfig;
    }

    function getLegalWrapper() external view returns (LegalWrapper memory wrapper) {
        wrapper = legalWrapper;
    }

    function claimDividend(
        uint256 proposalId,
        uint256 index,
        address receiver,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        DACCellGovernanceLib.claimDividend(
            proposalId,
            index,
            receiver,
            amount,
            proof,
            proposals,
            dividendMerkleRoots,
            dividendClaimed
        );
    }

    function getCapitalCall(bytes32 calldataHash) external view returns (CapitalCall memory capitalCall) {
        require(!capitalCalls[calldataHash].fulfilled, AlreadyFulfilled());
        capitalCall = capitalCalls[calldataHash].call;
        require(capitalCall.tokenAmount > 0, InvalidCapitalCall());
    }

    function getProposalVoting(uint256 proposalId) external view returns (address) {
        return proposals[proposalId];
    }

    function getMainToken() external view returns (address) {
        return address(mainToken);
    }

    function getAgentToken() external view returns (address) {
        return address(agentToken);
    }

    modifier onlyAgent() {
        _onlyAgent();
        _;
    }

    modifier onlyHolderOrManager() {
        _onlyHolderOrManager();
        _;
    }

    modifier onlyAgentOrHolder() {
        _onlyAgentOrHolder();
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

    function _onlyAgent() internal view {
        require(agentToken.balanceOf(msg.sender) > 0, NotAuthorized());
    }

    function _onlyHolderOrManager() internal view {
        require(
            (
                msg.sender == dealManager ||
                mainToken.balanceOf(msg.sender) > 0
            ), 
            NotAuthorized()
        );
    }

    function _onlyAgentOrHolder() internal view {
        require(
            (
                mainToken.balanceOf(msg.sender) > 0 ||
                agentToken.balanceOf(msg.sender) > 0
            ), 
            NotAuthorized()
        );
    }

    function _onlyLegalWrapper() internal view {
        require(legalWrapper.wrapperAddr != address(0), LegalWrapperNotSet());
        require(legalWrapper.wrapperAddr == msg.sender, LegalWrapperExecutionExpected());
    }

    function _onlyAfterVote(uint256 id, bool requiredOutcome) internal view {
        require(
            IVoting(proposals[id]).isResolved() &&
            IVoting(proposals[id]).outcome() == requiredOutcome,
            VoteNotPassed()
        );
    }
}
