// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "../lib/IVotes.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DealParams, VotingConfig, ProposalParams} from "../interfaces/Structs.sol";
import {IDACCell} from "../interfaces/IDACCell.sol";
import {IModuleFactory} from "../interfaces/IModuleFactory.sol";
import {IModuleRegistry} from "../interfaces/IModuleRegistry.sol";
import {IAssetController} from "../interfaces/IAssetController.sol";
import {IGovernanceSchema} from "../interfaces/IGovernanceSchema.sol";
import {IManagementProposal} from "../interfaces/IManagementProposal.sol";
import {IDeal} from "../interfaces/IDeal.sol";
import {IDealCell} from "../interfaces/IDealCell.sol";
import {DealState, KernelFactories} from "./interfaces/Structs.sol";
import {IDealManager} from "../interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "./interfaces/IDealManagerAdapter.sol";
import {IDealCellAdapter} from "./interfaces/IDealCellAdapter.sol";
import {AgentToken} from "./tokens/AgentToken.sol";
import {DACManagementProposalType} from "./governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "./governance/AbstractDealManagementProposals.sol";
import {DealCreationConfig} from "../interfaces/GovernanceStructs.sol";
import {DACCellGovernanceLib} from "./libraries/DACCellGovernanceLib.sol";
import {DACErrorsLib} from "../interfaces/DACErrorsLib.sol";

contract DealManager is IDealManager, IDealManagerAdapter, ReentrancyGuard, Initializable {
    
    // DACCell has no upgrade or pause capabilities by design.
    
    address private dacCell;

    // Tokens for chickens and pigs
    IERC20 private mainToken;
    AgentToken private agentToken;
    
    address private moduleRegistry;
    address private assetController;
    address private dealCellFactory;
    address private stakedAgentTokenFactory;

    uint256 private nextId;
    mapping(uint256 => address) public deals;                   // id => Deal cell address
    
    mapping(address => DealState) public dealState;             // dealCell => Deal state

    mapping(bytes32 => bool) public evaluatorWhitelist;         // keccak256((dealCell,keccak256(evaluator_config))) => true

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _mainToken,
        address _agentToken,
        address _moduleRegistry,
        address _dacCell,
        address _assetController,
        address _dealCellFactory,
        address _stakedAgentTokenFactory
    ) public initializer {
        nextId = 1;

        mainToken = IERC20(_mainToken);
        agentToken = AgentToken(_agentToken);

        dacCell = _dacCell;
        moduleRegistry = _moduleRegistry;
        assetController = _assetController;
        dealCellFactory = _dealCellFactory;
        stakedAgentTokenFactory = _stakedAgentTokenFactory;
    }

    function createDealProposal(DealParams calldata params)
        external
        onlyAgent
        returns (uint256 id, address dealCell, address dealAddr, address evaluatorAddr)
    {
        VotingConfig memory votingConfig = IDACCell(dacCell).getVotingConfig();
        DealCreationConfig memory creationConfig =
            IGovernanceSchema(IDACCell(dacCell).getGovernanceSchema()).getDealCreationConfig();

        require(agentToken.qualifiedBalanceOf(msg.sender) >= creationConfig.minAgentBalance, DACErrorsLib.InsufficientBalance());
        require(agentToken.qualifiedBalanceOf(msg.sender) >= creationConfig.minInitialAgentStake, DACErrorsLib.NoStake());

        (id, dealCell, dealAddr, evaluatorAddr) = DACCellGovernanceLib.createDealProposal(
            dacCell,
            nextId++,
            params,
            votingConfig,
            IModuleRegistry(moduleRegistry),
            KernelFactories(dealCellFactory, stakedAgentTokenFactory),
            deals,
            dealState
        );

        IAssetController(assetController).registerControlledAddress(dealCell);
        IAssetController(assetController).registerControlledAddress(dealAddr);

        if (creationConfig.minInitialAgentStake > 0) {
            agentToken.forceStakeToDeal(msg.sender, dealCell, creationConfig.minInitialAgentStake);
        }

        IDealCellAdapter(dealCell).onDACInit(params, votingConfig);
    }

    function createTrancheProposal(
        uint256 dealId,
        uint256 trancheId
    ) external onlyDealCell nonReentrant override {
        DACCellGovernanceLib.createTrancheProposal(
            dacCell,
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
            dealState
        );

        IAssetController(assetController).settleMainRewardClaim(to, amount);
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

        if (!dealState[deal].liquidated) {
            require(
                IERC20(IDealCell(deal).stakeToken()).totalSupply() == 0,
                DACErrorsLib.InvalidDealState(deal)
            );
        }

        return true;
    }

    function approveFunding(uint256 id, uint256 trancheId, uint256 rewardsLimit) external onlyDACCell {
        DACCellGovernanceLib.executeTrancheApprove(
            dacCell,
            id,
            trancheId,
            rewardsLimit,
            deals,
            dealState
        );
    }

    function executeProp(address msgSender, IManagementProposal prop) external onlyDACCell {
        if (prop.typ() == DACManagementProposalType.ADD_EVALUATOR) {
            (uint256 dealId, address evalModule, bytes memory evaluatorConfig) = abi.decode(
                prop.data(),
                (uint256, address, bytes)
            );

            // Validate evaluator module
            require(IModuleRegistry(moduleRegistry).isModuleApproved(evalModule), DACErrorsLib.ModuleNotApproved());
            require(IModuleFactory(evalModule).isActive(), DACErrorsLib.ModuleDisabled());

            // Cross-validate compatibility
            require(deals[dealId] != address(0), DACErrorsLib.NotFound());
            DealState memory ds = dealState[deals[dealId]];
            DealParams memory dealParams = abi.decode(ds.initParams, (DealParams));
            (bytes4 evaluatorSelector,) = abi.decode(evaluatorConfig, (bytes4, bytes));
            require(
                IModuleFactory(ds.module).dealAcceptsEvaluator(dealParams.dealKind, evaluatorSelector, evalModule),
                DACErrorsLib.EvaluatorNotCompatible()
            );
            require(
                IModuleFactory(evalModule).evaluatorAcceptsDeal(evaluatorSelector, dealParams.dealKind, address(ds.module)),
                DACErrorsLib.EvaluatorNotCompatible()
            );

            ProposalParams memory addEvaluatorParams = ProposalParams({
                typ: AbstractDealManagementType.PERMIT_EVALUATOR_ADD,
                target: address(0),
                i: 0,
                data: abi.encode(
                    prop.id(),
                    evalModule,
                    evaluatorConfig
                )
            });

            IDeal(ds.deal).createStakedAgentProposal(addEvaluatorParams);

            bytes32 propHash = keccak256(
                abi.encode(
                    deals[dealId],
                    keccak256(evaluatorConfig),
                    evalModule,
                    prop.id()
                )
            );

            require(!evaluatorWhitelist[propHash], DACErrorsLib.NotAllowed());
            evaluatorWhitelist[propHash] = true;
        }
        
        else if (prop.typ() == DACManagementProposalType.RECOVER_DEAL) {
            if (IDACCell(dacCell).getLegalWrapper().wrapperAddr != address(0)) {
                require(
                    msgSender == IDACCell(dacCell).getLegalWrapper().wrapperAddr,
                    DACErrorsLib.LegalWrapperExecutionExpected()
                );
            }

            (uint256 dealId) = abi.decode(prop.data(), (uint256));
            address deal = deals[dealId];

            address liquidator = prop.target();
            
            dealState[deal].liquidated = true;

            IDealCellAdapter(deal).recoverDeal(liquidator, uint256(prop.i()));
        }

        else if (prop.typ() == DACManagementProposalType.DEAL_MESSAGE) {
            (uint256 dealId, bytes4 message, bytes memory data) = abi.decode(
                prop.data(),
                (uint256, bytes4, bytes)
            );

            address deal = deals[dealId];

            IDealCellAdapter(deal).messageDeal(message, data);  
        }

    }

    function evaluateDeal(uint256 id, uint256 evaluatorId) external onlyAgentOrHolder nonReentrant {
        DACCellGovernanceLib.evaluateDeal(
            dacCell,
            id,
            evaluatorId,
            agentToken,
            deals,
            dealState
        );
    }

    function permitEvaluatorAdd(uint256 dealId, bytes memory evaluatorHandle) external onlyDealCell {
        DACCellGovernanceLib.permitEvaluatorAdd(
            dealId,
            evaluatorHandle,
            dacCell,
            deals[dealId],
            evaluatorWhitelist,
            dealState
        );
    }

    function onDealClosed(uint256 dealId) external onlyDealCell {
        require(msg.sender == deals[dealId], DACErrorsLib.NotAuthorized());

        uint256 unused = dealState[deals[dealId]].rewardsLimit >= dealState[deals[dealId]].rewardsUnlocked
            ? dealState[deals[dealId]].rewardsLimit - dealState[deals[dealId]].rewardsUnlocked
            : 0;
        IAssetController(assetController).releaseUnusedMintRewards(unused);

        dealState[deals[dealId]].active = false;
    }

    function registerControlledAddress(address controlled) external onlyDealCell {
        IAssetController(assetController).registerControlledAddress(controlled);
    }

    function onMainMove(address from, address to, uint256 amount) external {
        require(msg.sender == address(mainToken), DACErrorsLib.NotAuthorized());
        IAssetController(assetController).onMainMove(from, to, amount);
    }

    function onMainDelegate(address from, address to) external view {
        require(msg.sender == address(mainToken), DACErrorsLib.NotAuthorized());
        IAssetController(assetController).onMainDelegate(from, to);
    }

    function state(address dealCell) external view returns (DealState memory _state) {
        _state = dealState[dealCell];
    }

    function totalReleasedVotable() external view returns (uint256) {
        return IAssetController(assetController).totalReleasedVotable();
    }

    function mainTokenObligations() external view returns (uint256) {
        return IAssetController(assetController).mainTokenObligations();
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
        require(agentToken.qualifiedBalanceOf(msg.sender) > 0, DACErrorsLib.NotAuthorized());
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
                agentToken.qualifiedBalanceOf(msg.sender) > 0
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
