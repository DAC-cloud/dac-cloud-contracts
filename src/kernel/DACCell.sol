// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProposalParams, VotingConfig, CapitalCall, LegalWrapper} from "../interfaces/Structs.sol";
import {IVotes} from "../lib/IVotes.sol";
import {IVoting} from "../interfaces/IVoting.sol";
import {IDACCellAdapter} from "./interfaces/IDACCellAdapter.sol";
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
import {DACCellCapitalLib} from "./libraries/DACCellCapitalLib.sol";
import {DACErrorsLib} from "../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../interfaces/DACEventsLib.sol";

contract DACCell is IDACCell, IDACCellAdapter, ReentrancyGuard, Initializable {

    // DACCell has no upgrade or pause capabilities by design.
    
    // Deployer role limited to initialization call only, in fact deployer will be always 
    // a Create2 DACFactory, and once initialized, DACCell is independent of the factory.
    address private deployer;

    // Tokens for chickens and pigs
    MainToken private mainToken;
    AgentToken private agentToken;

    // Deal manager
    address private dealManager;

    address private proposalFactory;
    VotingConfig private votingConfig;

    string public name;
    string public description;

    LegalWrapper private legalWrapper;

    mapping(bytes32 => CapitalCallState) private capitalCalls;
    
    bool private rootCapitalCallInitialized;
    mapping(address => uint256) private treasuryBalances;

    uint256 private nextId;
    mapping(uint256 => address) private proposals;               // id => DACManagementProposal address
    mapping(uint256 => bool) private executed;                   // id => proposal executed (set early)

    bool private dividendsEnabled;
    mapping(uint256 => bytes32) private dividendMerkleRoots;     // proposalId => root
    mapping(bytes32 => bool) private dividendClaimed;            // keccak(root + leaf) => claimed

    constructor() {
        _disableInitializers();
    }

    bool public cellStarted;

    function initialize(
        address _globalFactory,
        string memory _name,
        string memory _description,
        address _proposalFactory
    ) external initializer {
        nextId = 1;

        name = _name;
        description = _description;

        proposalFactory = _proposalFactory;

        deployer = _globalFactory;

        cellStarted = false;
        rootCapitalCallInitialized = false;

        emit DACEventsLib.DACCreated(msg.sender, name);
    }

    function initializeAfterDeployment(
        address _mainToken,
        address _agentToken,
        address managerFactory,
        address coreModule,
        bool _dividendsEnabled,
        uint256 _quorum
    ) external {
        require(msg.sender == deployer, DACErrorsLib.NotAuthorized());
        require(!cellStarted, DACErrorsLib.AlreadyInitialized());
        cellStarted = true;

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

        mainToken.dacInit(dealManager);
        agentToken.dacInit(dealManager);
    }

    function initializeRootCapitalCall(
        address treasuryToken,
        address recipient,
        uint256 amount,
        uint256 cashAmount
    ) external {
        require(cellStarted, DACErrorsLib.NotInitialized());
        require(msg.sender == deployer, DACErrorsLib.NotAuthorized());
        require(!rootCapitalCallInitialized, DACErrorsLib.AlreadyInitialized());
        rootCapitalCallInitialized = true;

        emit DACEventsLib.CapitalCallCreated(
            0, 
            recipient, 
            DACCellCapitalLib.createCapitalCall(
                0,
                treasuryToken,
                recipient,
                amount,
                cashAmount,
                capitalCalls
            ), 
            amount
        );
    }

    function depositTreasury(address token, uint256 amount) external nonReentrant {
        return DACCellCapitalLib.depositTreasury(
            token, amount, dealManager, treasuryBalances
        );
    }

    function recoverTreasury(address token) external nonReentrant onlyHolderOrManager {
        return DACCellCapitalLib.recoverTreasury(
            token, treasuryBalances
        );
    }

    function fulfillCapitalCall(CapitalCall calldata call) external nonReentrant returns (bool) {
        return DACCellCapitalLib.fulfillCapitalCall(
            call, mainToken, capitalCalls, treasuryBalances
        );
    }

    function logLegalWrapperMessage(bytes4 kind, bytes calldata message) 
        external 
        onlyLegalWrapper 
        nonReentrant
    {
        emit DACEventsLib.LegalWrapperMessage(msg.sender, kind, message);
    }

    function createManagementProposal(ProposalParams calldata params)
        external
        onlyHolderOrManager
        nonReentrant
        returns (uint256 id)
    {
        id = DACCellGovernanceLib.createManagementProposal(
            nextId++,
            params,
            votingConfig,
            proposalFactory,
            mainToken,
            dividendsEnabled,
            IDealManager(dealManager).totalReleasedVotable(),
            IDealManager(dealManager),
            proposals
        );
    }

    function executeDACProposal(uint256 id) external onlyAfterVote(id, true) nonReentrant {
        require(!executed[id], DACErrorsLib.ProposalAlreadyExecuted());
        executed[id] = true;
        
        DACManagementProposal prop = DACManagementProposal(proposals[id]);
        bytes4 typ = prop.typ();
        
        if (typ == DACManagementProposalType.UPDATE_VOTING_CONFIG) {
            votingConfig = abi.decode(prop.data(), (VotingConfig));

            emit DACEventsLib.VotingConfigUpdate(id, votingConfig);
        }
        
        else if (typ == DACManagementProposalType.UPDATE_LEGAL_WRAPPER) {
            legalWrapper = abi.decode(prop.data(), (LegalWrapper));

            emit DACEventsLib.LegalWrapperSet(id, legalWrapper);
        }

        else if (typ == DACManagementProposalType.APPROVE_OFFCHAIN_ACTION) {
            (bytes4 selector, bytes memory data) = abi.decode(
                prop.data(), 
                (bytes4, bytes)
            );

            emit DACEventsLib.OffchainActionApproved(
                id, 
                selector, 
                data
            );
        }

        else if (typ == DACManagementProposalType.MINT_MAIN_TOKENS) {
            mainToken.mint(address(this), uint256(prop.i()));

            treasuryBalances[address(mainToken)] += uint256(prop.i());
            emit DACEventsLib.TokenMinted(id, uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.BURN_MAIN_TOKENS) {
            mainToken.burn(uint256(prop.i()));

            emit DACEventsLib.TokenBurnt(id, uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.MINT_AGENT_TOKENS) {
            agentToken.mint(address(prop.target()), uint256(prop.i()));

            treasuryBalances[address(mainToken)] += uint256(prop.i());
            emit DACEventsLib.AgentTokenMinted(id, prop.target(), uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.REVOKE_AGENT_TOKENS) {
            agentToken.burnFrom(prop.target(), uint256(prop.i()));

            emit DACEventsLib.AgentTokenRevoked(id, prop.target(), uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.CAPITAL_CALL) {
            DACCellCapitalLib.executeCapitalCall(id, prop, capitalCalls);
        }

        else if (typ == DACManagementProposalType.TOGGLE_DIVIDENDS) {
            require(
                msg.sender == legalWrapper.wrapperAddr, 
                DACErrorsLib.LegalWrapperExecutionExpected()
            );

            dividendsEnabled = abi.decode(prop.data(), (bool));

            emit DACEventsLib.DividendsConfigUpdate(id, dividendsEnabled);
        }

        else if (typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
            (address token, uint256 totalPayout, bytes32 merkleRoot) = abi.decode(
                DACManagementProposal(prop).data(), 
                (address, uint256, bytes32)
            );
            
            dividendMerkleRoots[id] = merkleRoot;

            emit DACEventsLib.DividendPayout(id, token, totalPayout, merkleRoot);
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

            emit DACEventsLib.VotesDelegated(token, delegatee);
        }

        else {
            IDealManagerAdapter(dealManager).executeProp(msg.sender, prop);
        }

        emit DACEventsLib.DACProposalExecuted(id, typ);
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
        DACCellCapitalLib.claimDividend(
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
        require(!capitalCalls[calldataHash].fulfilled, DACErrorsLib.AlreadyFulfilled());
        capitalCall = capitalCalls[calldataHash].call;
        require(capitalCall.tokenAmount > 0, DACErrorsLib.InvalidCapitalCall());
    }

    function getProposalVoting(uint256 proposalId) external view returns (address) {
        return proposals[proposalId];
    }

    function getMainToken() external view override(IDACCell, IDACCellAdapter) returns (address) {
        return address(mainToken);
    }

    function getAgentToken() external view override(IDACCell, IDACCellAdapter) returns (address) {
        return address(agentToken);
    }

    function getDealManager() external view override(IDACCell, IDACCellAdapter) returns (address) {
        return dealManager;
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
        require(agentToken.balanceOf(msg.sender) > 0, DACErrorsLib.NotAuthorized());
    }

    function _onlyHolderOrManager() internal view {
        require(
            (
                msg.sender == dealManager ||
                mainToken.balanceOf(msg.sender) > 0
            ), 
            DACErrorsLib.NotAuthorized()
        );
    }

    function _onlyAgentOrHolder() internal view {
        require(
            (
                mainToken.balanceOf(msg.sender) > 0 ||
                agentToken.balanceOf(msg.sender) > 0
            ), 
            DACErrorsLib.NotAuthorized()
        );
    }

    function _onlyLegalWrapper() internal view {
        require(legalWrapper.wrapperAddr != address(0), DACErrorsLib.LegalWrapperNotSet());
        require(legalWrapper.wrapperAddr == msg.sender, DACErrorsLib.LegalWrapperExecutionExpected());
    }

    function _onlyAfterVote(uint256 id, bool requiredOutcome) internal view {
        require(
            IVoting(proposals[id]).isResolved() &&
            IVoting(proposals[id]).outcome() == requiredOutcome,
            DACErrorsLib.VoteNotPassed()
        );
    }
}
