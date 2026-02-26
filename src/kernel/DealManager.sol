// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/Structs.sol";
import "../interfaces/IDACCell.sol";
import "../interfaces/IDACCellAdapter.sol";
import "../interfaces/IDealCore.sol";
import "../interfaces/IDealAdmin.sol";
import "../interfaces/IModuleFactory.sol";
import "../interfaces/IEvaluator.sol";
import "../interfaces/IDACManagementFactory.sol";
import "./interfaces/Structs.sol";
import "./tokens/MainToken.sol";
import "./tokens/AgentToken.sol";
import "./governance/DACManagementProposal.sol";
import "./governance/DACManagementProposals.sol";
import "./libraries/DACCellGovernance.sol";

contract DealManager is IDealManager, ReentrancyGuard {
    
    // Errors
    error NotAllowed();
    error NotAuthorized();
    error NotInitialized();
    error AlreadyInitialized();

    error VoteNotPassed();

    error ProposalAlreadyExecuted();
    error InvalidDeal(address deal);
    error InvalidDealId(uint256 deal);
    error InvalidDealState(address deal);
    error InvalidTranche();
    error InsufficientTreasury();
    error TransferFailed();

    error InvalidCapitalCall();
    error AlreadyFulfilled();

    error LegalWrapperNotSet();
    error LegalWrapperExecutionExpected();

    // DACCell has no upgrade or pause capabilities by design.
    
    // Deployer role limited to initialization call only, in fact deployer will be always 
    // a Create2 DACFactory, and once initialized, DACCell is independent of the factory.
    address private immutable deployer;

    address private dacCell;

    // Tokens for chickens and pigs
    MainToken private mainToken;
    AgentToken private agentToken;
    
    address private coreModuleFactory;
    mapping(address => bool) private moduleFactories;
    
    uint256 private nextId = 1;
    mapping(uint256 => address) public deals;                   // id => Deal address
    
    mapping(address => DealState) public dealState;             // address => Deal state

    // Events
    event ModuleAdded(address indexed factory);
    event ModuleRemoved(address indexed factory);

    constructor() {
        initialized = false;
        deployer = msg.sender;
    }

    bool public initialized;

    function initializeAfterDeployment(
        address _lpToken,
        address _mpToken,
        address coreModule,
        address _dacCell
    ) external {
        require(msg.sender == deployer, NotAuthorized());
        require(!initialized, AlreadyInitialized());

        mainToken = MainToken(_lpToken);
        agentToken = AgentToken(_mpToken);

        dacCell = _dacCell;

        coreModuleFactory = coreModule;
        moduleFactories[coreModule] = true;

        initialized = true;
    }

    function createDealProposal(DealParams calldata params)
        external
        onlyAgent
        returns (uint256 id, address dealAddr, address evaluatorAddr)
    {
        (id, dealAddr, evaluatorAddr) = DACCellGovernance.createDealProposal(
            address(this),
            nextId,
            params,
            mainToken,
            agentToken,
            IDACCell(dacCell).getVotingConfig(),
            moduleFactories,
            deals,
            dealState
        );

        nextId++;
    }

    function createTrancheProposal(
        uint256 dealId,
        uint256 trancheId
    ) external onlyDeal nonReentrant {
        DACCellGovernance.createTrancheProposal(
            address(this),
            dealId,
            trancheId,
            deals
        );
    }

    function legalWrapperMessage(uint256 id, bytes4 kind, bytes calldata message) 
        external 
        onlyLegalWrapper 
        nonReentrant
    {
        IDealAdmin(deals[id]).legalWrapperMessage(msg.sender, kind, message);
    }

    function mintMain(address deal, address to, uint256 amount) external onlyDeal nonReentrant {
        DACCellGovernance.mintMain(
            deal, 
            to, 
            amount, 
            mainToken, 
            dealState
        );
    }

    function forceReturnCapital(uint256 id) external onlyHolderOrSelf {
        address deal = deals[id];
        require(deal != address(0), InvalidDealId(id));
        IDealCore(deal).returnCapitalToDAC();
    }

    function isRecoverable(uint256 id) external view returns (bool) {
        address deal = deals[id];
        require(deal != address(0), InvalidDeal(deal));
        
        require(
            IDealCore(deal).isClosed(),
            InvalidDealState(deal)
        );

        require(
            IDealCore(deal).getStakedAgentTotal() == 0,
            InvalidDealState(deal)
        );
    }

    function approveFunding(uint256 id, uint256 trancheId, uint256 rewardsLimit) external onlyDACCell {
        DACCellGovernance.executeTrancheApprove(
            id,
            trancheId,
            rewardsLimit,
            deals,
            dealState
        );
    }

    function executeProp(address msgSender, DACManagementProposal prop) external onlyDACCell {
        if (prop.typ() == DACManagementProposalType.RECOVER_DEAL) {
            (uint256 dealId) = abi.decode(prop.data(), (uint256));
            address deal = deals[dealId];

            address liquidator = prop.target();
            
            IDealAdmin(deal).recoverDeal(liquidator, uint256(prop.i()));
        }

        else if (prop.typ() == DACManagementProposalType.DEAL_MESSAGE) {
            (uint256 dealId) = abi.decode(DACManagementProposal(prop).data(), (uint256));
            address deal = deals[dealId];

            (bytes4 message, bytes memory data) = abi.decode(
                DACManagementProposal(prop).data(),
                (bytes4, bytes)
            );

            IDealAdmin(deal).messageDeal(message, data);  
        }

        else if (prop.typ() == DACManagementProposalType.ADD_MODULE) {
            moduleFactories[prop.target()] = true;

            emit ModuleAdded(prop.target());
        } 

        else if (prop.typ() == DACManagementProposalType.REMOVE_MODULE) {
            if (IDACCell(dacCell).getLegalWrapper().wrapperAddr != address(0)) {
                require(msgSender == IDACCell(dacCell).getLegalWrapper().wrapperAddr, LegalWrapperExecutionExpected());
            }

            address factory = DACManagementProposal(prop).target();

            require(factory != coreModuleFactory, NotAllowed());

            moduleFactories[factory] = false;

            emit ModuleRemoved(factory);
        }
    }

    function evaluateDeal(uint256 id) external onlyAgentOrHolder {
        DACCellGovernance.evaluateDeal(
            id,
            agentToken,
            deals,
            dealState
        );
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

    modifier onlyHolderOrSelf() {
        _onlyHolderOrSelf();
        _;
    }

    modifier onlyAgentOrHolder() {
        _onlyAgentOrHolder();
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

    modifier onlyDACCell() {
        _onlyDACCell();
        _;
    }

    function _onlyAgent() internal view {
        require(agentToken.balanceOf(msg.sender) > 0, NotAuthorized());
    }

    function _onlyHolderOrSelf() internal view {
        require(
            (
                msg.sender == address(this) ||
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

    function _onlyDealOrSelf() internal view {
        if (msg.sender != address(this)) {
            _onlyDeal(msg.sender);
        }
    }

    function _onlyDeal(address deal) internal view {
        require(
            IModuleFactory(dealState[deal].module).isActive(), 
            InvalidDeal(deal)
        );
    }

    function _onlyLegalWrapper() internal view {
        require(IDACCell(dacCell).getLegalWrapper().wrapperAddr != address(0), LegalWrapperNotSet());
        require(IDACCell(dacCell).getLegalWrapper().wrapperAddr == msg.sender, LegalWrapperExecutionExpected());
    }

    function _onlyDACCell() internal view {
        require(msg.sender == dacCell, NotAuthorized());
    }
}
