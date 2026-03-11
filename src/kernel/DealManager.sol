// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DealParams, VotingConfig, ProposalParams} from "../interfaces/Structs.sol";
import {IDACCell} from "../interfaces/IDACCell.sol";
import {IModuleFactory} from "../interfaces/IModuleFactory.sol";
import {IDeal} from "../interfaces/IDeal.sol";
import {IDealCell} from "../interfaces/IDealCell.sol";
import {DealState} from "./interfaces/Structs.sol";
import {IDealManager} from "../interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "./interfaces/IDealManagerAdapter.sol";
import {IDealCellAdapter} from "./interfaces/IDealCellAdapter.sol";
import {MainToken} from "./tokens/MainToken.sol";
import {AgentToken} from "./tokens/AgentToken.sol";
import {DACManagementProposal} from "./governance/DACManagementProposal.sol";
import {DACManagementProposalType} from "./governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "./governance/AbstractDealManagementProposals.sol";
import {DACCellGovernanceLib} from "./libraries/DACCellGovernanceLib.sol";
import {DACErrorsLib} from "../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../interfaces/DACEventsLib.sol";

contract DealManager is IDealManager, IDealManagerAdapter, ReentrancyGuard, Initializable {
    
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

    uint256 private nextId;
    mapping(uint256 => address) public deals;                   // id => Deal cell address
    
    mapping(address => DealState) public dealState;             // dealCell => Deal state

    mapping(bytes32 => bool) public evaluatorWhitelist;         // keccak256((dealCell,keccak256(evaluator_config))) => true

    // Main token flow tracking
    uint256 public mainTokenObligations;

    uint256 private unreleasedMainTokens;
    mapping(address => uint256) private lockedMainTokens;
    mapping(address => bool) private controlledAddresses;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _mainToken,
        address _agentToken,
        address coreModule,
        address _dacCell
    ) public initializer {
        nextId = 1;

        mainToken = MainToken(_mainToken);
        agentToken = AgentToken(_agentToken);

        dacCell = _dacCell;

        coreModuleFactory = coreModule;
        moduleFactories[coreModule] = true;

        controlledAddresses[_dacCell] = true;
        controlledAddresses[address(this)] = true;
    }

    function createDealProposal(DealParams calldata params)
        external
        onlyAgent
        returns (uint256 id, address dealCell, address dealAddr, address evaluatorAddr)
    {
        VotingConfig memory votingConfig = IDACCell(dacCell).getVotingConfig();

        (id, dealCell, dealAddr, evaluatorAddr) = DACCellGovernanceLib.createDealProposal(
            dacCell,
            nextId++,
            params,
            votingConfig,
            moduleFactories,
            deals,
            dealState
        );

        controlledAddresses[dealCell] = true;
        controlledAddresses[dealAddr] = true;

        IDealCellAdapter(dealCell).onDACInit(params, votingConfig);
    }

    function createTrancheProposal(
        uint256 dealId,
        uint256 trancheId
    ) external onlyDealCell nonReentrant override {
        DACCellGovernanceLib.createTrancheProposal(
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
        IDealCellAdapter(deals[id]).legalWrapperMessage(msg.sender, kind, message);
    }

    function mintMain(
        address deal, 
        uint256 evaluatorId, 
        address to, 
        uint256 amount
    ) external onlyDealCell nonReentrant {
        DACCellGovernanceLib.mintMain(
            deal, 
            evaluatorId,
            to, 
            amount, 
            mainToken, 
            dealState
        );

        mainTokenObligations -= amount;
    }

    function forceReturnCapital(uint256 id) external onlyHolderOrSelf {
        address deal = deals[id];
        require(deal != address(0), DACErrorsLib.InvalidDealId(id));
        IDealCellAdapter(deal).withdrawCapital();
    }

    function isRecoverable(uint256 id) external view override(IDealManager, IDealManagerAdapter) returns (bool) {
        address deal = deals[id];
        require(deal != address(0), DACErrorsLib.InvalidDeal(deal));
        
        require(
            IDealCell(deal).isClosed(),
            DACErrorsLib.InvalidDealState(deal)
        );

        require(
            IERC20(IDealCell(deal).stakeToken()).totalSupply() == 0,
            DACErrorsLib.InvalidDealState(deal)
        );

        return true;
    }

    function approveFunding(uint256 id, uint256 trancheId, uint256 rewardsLimit) external onlyDACCell {
        if (rewardsLimit > 0) {
            require(
                (mainToken.totalSupply() + mainTokenObligations) + rewardsLimit <= mainToken.maxSupply(),
                DACErrorsLib.InsufficientRewards()
            );
            
            mainTokenObligations += rewardsLimit;
        }
        
        DACCellGovernanceLib.executeTrancheApprove(
            dacCell,
            id,
            trancheId,
            rewardsLimit,
            deals,
            dealState
        );
    }

    function executeProp(address msgSender, DACManagementProposal prop) external onlyDACCell {
        if (prop.typ() == DACManagementProposalType.ADD_EVALUATOR) {
            (uint256 dealId, bytes memory evaluatorConfig) = abi.decode(
                DACManagementProposal(prop).data(),
                (uint256, bytes)
            );

            ProposalParams memory addEvaluatorParams = ProposalParams({
                typ: AbstractDealManagementType.PERMIT_EVALUATOR_ADD,
                target: address(0),
                i: 0,
                data: evaluatorConfig
            });

            require(deals[dealId] != address(0), DACErrorsLib.NotFound());
            IDeal(dealState[deals[dealId]].deal).createStakedAgentProposal(addEvaluatorParams);

            bytes32 propHash = keccak256(
                abi.encode(
                    deals[dealId],
                    keccak256(evaluatorConfig)
                )
            );

            require(!evaluatorWhitelist[propHash], DACErrorsLib.NotAllowed());
            evaluatorWhitelist[propHash] = true;
        }
        
        else if (prop.typ() == DACManagementProposalType.RECOVER_DEAL) {
            (uint256 dealId) = abi.decode(prop.data(), (uint256));
            address deal = deals[dealId];

            address liquidator = prop.target();
            
            IDealCellAdapter(deal).recoverDeal(liquidator, uint256(prop.i()));
        }

        else if (prop.typ() == DACManagementProposalType.DEAL_MESSAGE) {
            (uint256 dealId, bytes4 message, bytes memory data) = abi.decode(
                DACManagementProposal(prop).data(),
                (uint256, bytes4, bytes)
            );

            address deal = deals[dealId];

            IDealCellAdapter(deal).messageDeal(message, data);  
        }

        else if (prop.typ() == DACManagementProposalType.ADD_MODULE) {
            moduleFactories[prop.target()] = true;

            emit DACEventsLib.ModuleAdded(dacCell, prop.target());
        } 

        else if (prop.typ() == DACManagementProposalType.REMOVE_MODULE) {
            if (IDACCell(dacCell).getLegalWrapper().wrapperAddr != address(0)) {
                require(
                    msgSender == IDACCell(dacCell).getLegalWrapper().wrapperAddr,
                    DACErrorsLib.LegalWrapperExecutionExpected()
                );
            }

            address factory = DACManagementProposal(prop).target();

            require(factory != coreModuleFactory, DACErrorsLib.NotAllowed());

            moduleFactories[factory] = false;

            emit DACEventsLib.ModuleRemoved(dacCell, factory);
        }
    }

    function evaluateDeal(uint256 id, uint256 evaluatorId) external onlyAgentOrHolder {
        if (
            //todo: allow maintoken holder to evaluate only after approved deadline
            //todo: allow only bonded agent to evaluate, not every agent, at any time
            DACCellGovernanceLib.evaluateDeal(
                dacCell,
                id,
                evaluatorId,
                agentToken,
                deals,
                dealState
            )
        ) {
            // If the deal is closed, rewards are no longer available,
            //  whatever is left locked need to free, the difference between 
            //  unlocked and paid still will be accounted as obligations
            mainTokenObligations -= (dealState[deals[id]].rewardsLimit - dealState[deals[id]].rewardsUnlocked);

            dealState[deals[id]].active = false;
        }
    }

    function permitEvaluatorAdd(uint256 dealId, bytes memory evaluatorConfig) external onlyDealCell {
        DACCellGovernanceLib.permitEvaluatorAdd(
            dealId,
            evaluatorConfig,
            dacCell,
            evaluatorWhitelist,
            deals,
            dealState
        );
    }

    function registerControlledAddress(address controlled) external onlyDealCell {
        require(controlled != address(0), DACErrorsLib.NotAllowed());
        require(controlled != address(mainToken), DACErrorsLib.NotAllowed());

        controlledAddresses[controlled] = true;
    }

    function onMainMove(address from, address to, uint256 amount) external {
        require(msg.sender == address(mainToken), DACErrorsLib.NotAuthorized());

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
        require(msg.sender == address(mainToken), DACErrorsLib.NotAuthorized());

        require(!controlledAddresses[from], DACErrorsLib.NoVotingPower());
        require(!controlledAddresses[to], DACErrorsLib.NoVotingPower());
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
        require(agentToken.balanceOf(msg.sender) > 0, DACErrorsLib.NotAuthorized());
    }

    function _onlyHolderOrSelf() internal view {
        require(
            (
                msg.sender == address(this) ||
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

    function _onlyDealCell(address dealCell) internal view {
        require(
            IModuleFactory(dealState[dealCell].module).isActive(), 
            DACErrorsLib.InvalidDeal(dealCell)
        );
    }

    function _onlyLegalWrapper() internal view {
        require(
            IDACCell(dacCell).getLegalWrapper().wrapperAddr != address(0), 
            DACErrorsLib.LegalWrapperNotSet()
        );
        require(
            IDACCell(dacCell).getLegalWrapper().wrapperAddr == msg.sender, 
            DACErrorsLib.LegalWrapperExecutionExpected()
        );
    }

    function _onlyDACCell() internal view {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());
    }
}
