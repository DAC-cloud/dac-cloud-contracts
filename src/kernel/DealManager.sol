// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DealParams} from "../interfaces/Structs.sol";
import {IDACCell} from "../interfaces/IDACCell.sol";
import {IDealAdmin} from "../interfaces/IDealAdmin.sol";
import {IModuleFactory} from "../interfaces/IModuleFactory.sol";
import {IDealCell} from "../interfaces/IDealCell.sol";
import {DealState} from "./interfaces/Structs.sol";
import {IDealManager} from "../interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "./interfaces/IDealManagerAdapter.sol";
import {IDealCellAdapter} from "./interfaces/IDealCellAdapter.sol";
import {MainToken} from "./tokens/MainToken.sol";
import {AgentToken} from "./tokens/AgentToken.sol";
import {DACManagementProposal} from "./governance/DACManagementProposal.sol";
import {DACManagementProposalType} from "./governance/DACManagementProposals.sol";
import {DACCellGovernance} from "./libraries/DACCellGovernance.sol";

contract DealManager is IDealManager, IDealManagerAdapter, ReentrancyGuard {
    
    // Errors
    error NotAllowed();
    error NotAuthorized();
    error NotInitialized();
    error AlreadyInitialized();

    error NoVotingPower();

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
    mapping(uint256 => address) public deals;                   // id => Deal cell address
    
    mapping(address => DealState) public dealState;             // dealCell => Deal state

    // Main token flow tracking
    uint256 private unreleasedMainTokens;
    mapping(address => uint256) private lockedMainTokens;
    mapping(address => bool) private controlledAddresses;

    // Events
    event ModuleAdded(address indexed factory);
    event ModuleRemoved(address indexed factory);

    constructor() {
        initialized = false;
        deployer = msg.sender;
    }

    bool public initialized;

    function initializeAfterDeployment(
        address _mainToken,
        address _agentToken,
        address coreModule,
        address _dacCell
    ) external {
        require(msg.sender == deployer, NotAuthorized());
        require(!initialized, AlreadyInitialized());

        mainToken = MainToken(_mainToken);
        agentToken = AgentToken(_agentToken);

        dacCell = _dacCell;

        coreModuleFactory = coreModule;
        moduleFactories[coreModule] = true;

        controlledAddresses[_dacCell] = true;
        controlledAddresses[address(this)] = true;

        initialized = true;
    }

    function createDealProposal(DealParams calldata params)
        external
        onlyAgent
        returns (uint256 id, address dealCell, address dealAddr, address evaluatorAddr)
    {
        (id, dealCell, dealAddr, evaluatorAddr) = DACCellGovernance.createDealProposal(
            address(this),
            nextId,
            params,
            IDACCell(dacCell).getVotingConfig(),
            moduleFactories,
            deals,
            dealState
        );

        controlledAddresses[dealCell] = true;
        controlledAddresses[dealAddr] = true;

        nextId++;
    }

    function createTrancheProposal(
        uint256 dealId,
        uint256 trancheId
    ) external onlyDealCell nonReentrant override(IDealManager, IDealManagerAdapter) {
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

    function mintMain(address deal, address to, uint256 amount) external onlyDealCell nonReentrant {
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
        IDealCellAdapter(deal).withdrawCapital();
    }

    function isRecoverable(uint256 id) external view override(IDealManager, IDealManagerAdapter) returns (bool) {
        address deal = deals[id];
        require(deal != address(0), InvalidDeal(deal));
        
        require(
            IDealCell(deal).isClosed(),
            InvalidDealState(deal)
        );

        require(
            IDealCell(deal).getStakedAgentTotal() == 0,
            InvalidDealState(deal)
        );

        return true;
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

    function registerControlledAddress(address controlled) external onlyDealCell {
        controlledAddresses[controlled] = true;
    }

    function onMainMove(address from, address to, uint256 amount) external {
        require(msg.sender == address(mainToken), NotAuthorized());

        if (from == address(0)) {
            if (controlledAddresses[to]) {
                lockedMainTokens[to] += amount;
                unreleasedMainTokens += amount;
            }
        }

        else {
            // If address contains both unreleased main tokens and free float,
            //  the unreleased float will be released first

            if (controlledAddresses[from]) {
                lockedMainTokens[from] -= amount;
                if (controlledAddresses[to]) {
                    lockedMainTokens[to] += amount;
                }
                else {
                    unreleasedMainTokens -= amount;
                }
            }
        }
    }

    function onMainDelegate(address from, address to) external view {
        require(msg.sender == address(mainToken), NotAuthorized());

        require(!controlledAddresses[from], NoVotingPower());
        require(!controlledAddresses[to], NoVotingPower());
    }

    function state(address dealCell) external view returns (DealState memory _state) {
        _state = dealState[dealCell];
    }

    function totalReleasedVotable() external view returns (uint256) {
        return (mainToken.totalSupply() - unreleasedMainTokens) - (mainToken.balanceOf(dacCell) - lockedMainTokens[dacCell]);
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

    modifier onlyDealCell() {
        _onlyDealCell(msg.sender);
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

    function _onlyDealCell(address dealCell) internal view {
        require(
            IModuleFactory(dealState[dealCell].module).isActive(), 
            InvalidDeal(dealCell)
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
