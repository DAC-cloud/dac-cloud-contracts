// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig, CapitalCall, LegalWrapper, ExistingDACConfig} from "../interfaces/Structs.sol";
import {DealCreationConfig, GovernanceStrategyConfig} from "../interfaces/GovernanceStructs.sol";
import {IVoting} from "../interfaces/IVoting.sol";
import {IAssetController} from "../interfaces/IAssetController.sol";
import {IGovernanceSchema} from "../interfaces/IGovernanceSchema.sol";
import {IManagementProposal} from "../interfaces/IManagementProposal.sol";
import {IDACCellAdapter} from "./interfaces/IDACCellAdapter.sol";
import {IDealManager} from "../interfaces/IDealManager.sol";
import {IModuleRegistry} from "../interfaces/IModuleRegistry.sol";
import {IDACCell} from "../interfaces/IDACCell.sol";
import {IDealManagerAdapter} from "./interfaces/IDealManagerAdapter.sol";
import {MainToken} from "./tokens/MainToken.sol";
import {AgentToken} from "./tokens/AgentToken.sol";
import {DealManagerFactory} from "./factories/DealManagerFactory.sol";
import {ModuleRegistryFactory} from "./factories/ModuleRegistryFactory.sol";
import {NativeAssetControllerFactory} from "./factories/AssetControllerFactory.sol";
import {ExistingTokenAssetControllerFactory} from "./factories/ExistingTokenAssetControllerFactory.sol";
import {NativeGovernanceSchemaFactory} from "./governance/factories/NativeGovernanceSchemaFactory.sol";
import {HybridGovernanceSchemaFactory} from "./governance/factories/HybridGovernanceSchemaFactory.sol";
import {WrappedMainToken} from "./tokens/WrappedMainToken.sol";
import {DACManagementProposalType} from "./governance/DACManagementProposals.sol";
import {DACCellGovernanceLib} from "./libraries/DACCellGovernanceLib.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {DACErrorsLib} from "../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../interfaces/DACEventsLib.sol";

contract DACCell is IDACCell, IDACCellAdapter, ReentrancyGuard, Initializable {

    // DACCell has no upgrade or pause capabilities by design.
    
    // Deployer role limited to initialization call only, in fact deployer will be always 
    // a Create2 DACFactory, and once initialized, DACCell is independent of the factory.
    address private deployer;

    // Tokens for chickens and pigs
    IERC20 private mainToken;
    AgentToken private agentToken;

    // Deal manager
    address private dealManager;
    address private moduleRegistry;
    address private assetController;
    address private governanceSchema;

    address private proposalFactory;

    string public name;
    string public description;

    LegalWrapper private legalWrapper;
    
    bool private rootCapitalCallInitialized;

    bool private dividendsEnabled;

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
        name = _name;
        description = _description;

        proposalFactory = _proposalFactory;

        deployer = _globalFactory;

        cellStarted = false;
        rootCapitalCallInitialized = false;

        emit DACEventsLib.DACCreated(msg.sender, name, description);
    }

    function initializeAfterDeployment(
        address _mainToken,
        address _agentToken,
        address managerFactory,
        address _moduleRegistryFactory,
        address _assetControllerFactory,
        address _governanceSchemaFactory,
        address coreModule,
        bool _dividendsEnabled,
        uint256 _quorum // 1e18 == MathLib.SCALE == 100%
    ) external {
        require(msg.sender == deployer, DACErrorsLib.NotAuthorized());
        require(!cellStarted, DACErrorsLib.AlreadyInitialized());
        cellStarted = true;

        mainToken = IERC20(_mainToken);
        agentToken = AgentToken(_agentToken);

        dividendsEnabled = _dividendsEnabled;

        VotingConfig memory initialVotingConfig = VotingConfig({   // DEFAULTS — changed via governance later
            quorumPercent: _quorum,
            highQuorumPercent: (MathLib.SCALE + _quorum) / 2,
            blockingPercent: (MathLib.SCALE - _quorum) / 2,
            duration: 7 days,
            qualification: 0
        });

        assetController = NativeAssetControllerFactory(_assetControllerFactory).deployNativeAssetController(
            address(this),
            _mainToken
        );
        moduleRegistry = ModuleRegistryFactory(_moduleRegistryFactory).deployModuleRegistry(
            address(this),
            coreModule
        );

        dealManager = DealManagerFactory(managerFactory).deployDealManager(
            _mainToken,
            _agentToken,
            moduleRegistry,
            address(this),
            assetController
        );

        IAssetController(assetController).setDealManager(dealManager);

        governanceSchema = NativeGovernanceSchemaFactory(_governanceSchemaFactory).deployNativeGovernanceSchema(
            address(this),
            _mainToken,
            dealManager,
            assetController,
            proposalFactory,
            initialVotingConfig
        );

        MainToken(_mainToken).dacInit(dealManager, assetController);
        agentToken.dacInit(dealManager);

        emit DACEventsLib.DACStarted(
            dealManager,
            IGovernanceSchema(governanceSchema).getVotingConfig(),
            dividendsEnabled,
            coreModule
        );
    }

    function initializeExistingTokenAfterDeployment(
        address _wrappedMainToken,
        address _agentToken,
        address managerFactory,
        address _moduleRegistryFactory,
        address _assetControllerFactory,
        address _governanceSchemaFactory,
        address _governanceOracle,
        address coreModule,
        ExistingDACConfig calldata config
    ) external {
        require(msg.sender == deployer, DACErrorsLib.NotAuthorized());
        require(!cellStarted, DACErrorsLib.AlreadyInitialized());
        cellStarted = true;

        mainToken = IERC20(_wrappedMainToken);
        agentToken = AgentToken(_agentToken);
        dividendsEnabled = config.dividendsEnabled;

        assetController = ExistingTokenAssetControllerFactory(_assetControllerFactory).deployExistingTokenAssetController(
            address(this),
            _wrappedMainToken
        );
        moduleRegistry = ModuleRegistryFactory(_moduleRegistryFactory).deployModuleRegistry(
            address(this),
            coreModule
        );

        dealManager = DealManagerFactory(managerFactory).deployDealManager(
            _wrappedMainToken,
            _agentToken,
            moduleRegistry,
            address(this),
            assetController
        );

        IAssetController(assetController).setDealManager(dealManager);
        WrappedMainToken(_wrappedMainToken).setController(assetController);

        governanceSchema = HybridGovernanceSchemaFactory(_governanceSchemaFactory).deployHybridGovernanceSchema(
            address(this),
            _wrappedMainToken,
            dealManager,
            assetController,
            proposalFactory,
            _governanceOracle,
            config.governanceStrategy
        );

        agentToken.dacInit(dealManager);

        emit DACEventsLib.DACStarted(
            dealManager,
            IGovernanceSchema(governanceSchema).getVotingConfig(),
            dividendsEnabled,
            coreModule
        );
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

        bytes32 callHash = IAssetController(assetController).createCapitalCall(
            0,
            treasuryToken,
            recipient,
            amount,
            cashAmount
        );

        emit DACEventsLib.CapitalCallCreated(
            0,
            recipient,
            callHash,
            treasuryToken,
            amount,
            cashAmount,
            0
        );
    }

    function depositTreasury(address token, uint256 amount) external nonReentrant {
        require(
            IDealManagerAdapter(dealManager).state(msg.sender).deal != address(0),
            DACErrorsLib.NotAuthorized()
        );

        IAssetController(assetController).depositFrom(msg.sender, token, amount);
        emit DACEventsLib.TreasuryDeposit(token, amount, msg.sender);
    }

    function recoverTreasury(address token) external nonReentrant onlyHolderOrManager {
        uint256 recovered = IERC20(token).balanceOf(address(this));
        if (recovered > 0) {
            require(IERC20(token).transfer(assetController, recovered), DACErrorsLib.TransferFailed());
            IAssetController(assetController).recordTreasuryDeposit(token, recovered);
            emit DACEventsLib.TreasuryDeposit(token, recovered, msg.sender);
        }

        (uint256 previousBalance, uint256 currentBalance) = IAssetController(assetController).syncTreasury(
            token,
            msg.sender,
            IGovernanceSchema(governanceSchema).getVotingConfig().qualification
        );

        if (currentBalance > previousBalance) {
            emit DACEventsLib.TreasuryDeposit(token, currentBalance - previousBalance, msg.sender);
        } else if (currentBalance < previousBalance) {
            emit DACEventsLib.TreasurySyncMissing(token, previousBalance - currentBalance);
        }
    }

    function fulfillCapitalCall(CapitalCall calldata call) external nonReentrant returns (bool) {
        (bytes32 callHash, CapitalCall memory capitalCall) = IAssetController(assetController).fulfillCapitalCall(call);

        emit DACEventsLib.CapitalCallFulfilled(
            capitalCall.tokenRecipient,
            call.tokenRecipient,
            callHash,
            call.treasuryToken,
            call.tokenAmount,
            call.cashAmount,
            call.nonce
        );

        return true;
    }

    function recordBootstrapTreasuryDeposit(address token, uint256 amount) external {
        require(msg.sender == deployer, DACErrorsLib.NotAuthorized());
        require(cellStarted, DACErrorsLib.NotInitialized());
        require(amount > 0, DACErrorsLib.NotAllowed());

        IAssetController(assetController).recordTreasuryDeposit(token, amount);
        emit DACEventsLib.TreasuryDeposit(token, amount, msg.sender);
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
        address proposal;
        (id, proposal) = IGovernanceSchema(governanceSchema).createProposal(
            msg.sender,
            params,
            IDealManager(dealManager).totalReleasedVotable(),
            dividendsEnabled
        );

        emit DACEventsLib.DACProposalCreated(id, proposal, params.typ, params.target, params.i, params.data);
    }

    function executeDACProposal(uint256 id) external nonReentrant {
        IManagementProposal prop = IManagementProposal(IGovernanceSchema(governanceSchema).consumeApprovedProposal(id, true));
        bytes4 typ = prop.typ();
        
        if (typ == DACManagementProposalType.UPDATE_VOTING_CONFIG) {
            _executeVotingConfigUpdate(id, prop);
        }

        else if (typ == DACManagementProposalType.UPDATE_GOVERNANCE_STRATEGY) {
            _executeGovernanceStrategyUpdate(id, prop);
        }

        else if (typ == DACManagementProposalType.UPDATE_DEAL_CREATION_CONFIG) {
            _executeDealCreationConfigUpdate(id, prop);
        }

        else if (typ == DACManagementProposalType.UPDATE_GOVERNANCE_ORACLE) {
            _executeGovernanceOracleUpdate(id, prop);
        }
        
        else if (typ == DACManagementProposalType.UPDATE_LEGAL_WRAPPER) {
            _executeLegalWrapperUpdate(id, prop);
        }

        else if (typ == DACManagementProposalType.APPROVE_OFFCHAIN_ACTION) {
            _executeOffchainActionApprove(id, prop);
        }

        else if (typ == DACManagementProposalType.MINT_MAIN_TOKENS) {
            _executeMintMain(id, prop);
        }

        else if (typ == DACManagementProposalType.BURN_MAIN_TOKENS) {
            _executeBurnMain(id, prop);
        }

        else if (typ == DACManagementProposalType.MINT_AGENT_TOKENS) {
            _executeMintAgent(id, prop);
        }

        else if (typ == DACManagementProposalType.REVOKE_AGENT_TOKENS) {
            _executeRevokeAgent(id, prop);
        }

        else if (typ == DACManagementProposalType.CAPITAL_CALL) {
            _executeCapitalCall(id, prop);
        }

        else if (typ == DACManagementProposalType.TOGGLE_DIVIDENDS) {
            _executeToggleDividends(id, prop);
        }

        else if (typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
            _executeDividendPayout(id, prop);
        }

        else if (
            typ == DACManagementProposalType.APPROVE_DEAL || 
            typ == DACManagementProposalType.APPROVE_TRANCHE
        ) {
            _executeFundingApproval(prop);
        }

        else if (typ == DACManagementProposalType.ADD_MODULE) {
            _executeAddModule(prop);
        }

        else if (typ == DACManagementProposalType.REMOVE_MODULE) {
            _executeRemoveModule(prop);
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
            _executeVoteDelegation(prop);
        }

        else {
            IDealManagerAdapter(dealManager).executeProp(msg.sender, prop);
        }

        emit DACEventsLib.DACProposalExecuted(address(prop), id, typ);
    }

    function getVotingConfig() external view returns (VotingConfig memory config) {
        config = IGovernanceSchema(governanceSchema).getVotingConfig();
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
        address token = IAssetController(assetController).claimDividend(
            proposalId,
            index,
            receiver,
            amount,
            proof
        );

        emit DACEventsLib.DividendClaimed(proposalId, token, receiver, amount);
    }

    function recoverERC20(address token) external nonReentrant onlyHolderOrManager {
        uint256 recovered = IERC20(token).balanceOf(address(this));
        require(recovered > 0, DACErrorsLib.NotEnoughBalance());

        require(IERC20(token).transfer(assetController, recovered), DACErrorsLib.TransferFailed());
        IAssetController(assetController).recordTreasuryDeposit(token, recovered);

        emit DACEventsLib.TreasuryDeposit(token, recovered, msg.sender);
    }

    function _executeVotingConfigUpdate(uint256 id, IManagementProposal prop) internal {
        IGovernanceSchema(governanceSchema).setVotingConfig(abi.decode(prop.data(), (VotingConfig)));
        emit DACEventsLib.VotingConfigUpdate(id, IGovernanceSchema(governanceSchema).getVotingConfig());
    }

    function _executeGovernanceStrategyUpdate(uint256 id, IManagementProposal prop) internal {
        IGovernanceSchema(governanceSchema).setStrategyConfig(abi.decode(prop.data(), (GovernanceStrategyConfig)));
        emit DACEventsLib.GovernanceStrategyUpdate(id, IGovernanceSchema(governanceSchema).getStrategyConfig());
    }

    function _executeDealCreationConfigUpdate(uint256 id, IManagementProposal prop) internal {
        IGovernanceSchema(governanceSchema).setDealCreationConfig(abi.decode(prop.data(), (DealCreationConfig)));
        emit DACEventsLib.DealCreationConfigUpdate(id, IGovernanceSchema(governanceSchema).getDealCreationConfig());
    }

    function _executeGovernanceOracleUpdate(uint256 id, IManagementProposal prop) internal {
        IGovernanceSchema(governanceSchema).setGovernanceOracle(prop.target());
        emit DACEventsLib.GovernanceOracleUpdate(id, IGovernanceSchema(governanceSchema).getGovernanceOracle());
    }

    function _executeLegalWrapperUpdate(uint256 id, IManagementProposal prop) internal {
        legalWrapper = abi.decode(prop.data(), (LegalWrapper));
        emit DACEventsLib.LegalWrapperSet(id, legalWrapper);
    }

    function _executeOffchainActionApprove(uint256 id, IManagementProposal prop) internal {
        (bytes4 selector, bytes memory data) = abi.decode(prop.data(), (bytes4, bytes));
        emit DACEventsLib.OffchainActionApproved(id, selector, data);
    }

    function _executeMintMain(uint256 id, IManagementProposal prop) internal {
        uint256 amount = uint256(prop.i());
        IAssetController(assetController).mintMainToTreasury(amount);
        emit DACEventsLib.TokenMinted(id, amount);
    }

    function _executeBurnMain(uint256 id, IManagementProposal prop) internal {
        uint256 amount = uint256(prop.i());
        IAssetController(assetController).burnMainFromTreasury(amount);
        emit DACEventsLib.TokenBurnt(id, amount);
    }

    function _executeMintAgent(uint256 id, IManagementProposal prop) internal {
        uint256 amount = uint256(prop.i());
        address recipient = prop.target();
        agentToken.mint(recipient, amount);
        emit DACEventsLib.AgentTokenMinted(id, recipient, amount);
    }

    function _executeRevokeAgent(uint256 id, IManagementProposal prop) internal {
        uint256 amount = uint256(prop.i());
        address holder = prop.target();
        agentToken.burnFrom(holder, amount);
        emit DACEventsLib.AgentTokenRevoked(id, holder, amount);
    }

    function _executeCapitalCall(uint256 id, IManagementProposal prop) internal {
        (address treasuryToken, uint256 cashAmount) = abi.decode(prop.data(), (address, uint256));
        bytes32 callHash = IAssetController(assetController).createCapitalCall(
            id,
            treasuryToken,
            prop.target(),
            uint256(prop.i()),
            cashAmount
        );
        emit DACEventsLib.CapitalCallCreated(
            id,
            prop.target(),
            callHash,
            treasuryToken,
            uint256(prop.i()),
            cashAmount,
            id
        );
    }

    function _executeToggleDividends(uint256 id, IManagementProposal prop) internal {
        require(msg.sender == legalWrapper.wrapperAddr, DACErrorsLib.LegalWrapperExecutionExpected());
        dividendsEnabled = abi.decode(prop.data(), (bool));
        emit DACEventsLib.DividendsConfigUpdate(id, dividendsEnabled);
    }

    function _executeDividendPayout(uint256 id, IManagementProposal prop) internal {
        (address token, uint256 totalPayout, bytes32 merkleRoot) = abi.decode(
            prop.data(),
            (address, uint256, bytes32)
        );
        IAssetController(assetController).recordDividendPayout(id, token, totalPayout, merkleRoot);
        emit DACEventsLib.DividendPayout(id, token, totalPayout, merkleRoot);
    }

    function _executeFundingApproval(IManagementProposal prop) internal {
        (uint256 dealId, uint256 trancheId, uint256 rewardsLimit) = abi.decode(
            prop.data(),
            (uint256, uint256, uint256)
        );
        IAssetController(assetController).approveFunding(dealId, trancheId, rewardsLimit);
        IDealManagerAdapter(dealManager).approveFunding(dealId, trancheId, rewardsLimit);
    }

    function _executeAddModule(IManagementProposal prop) internal {
        IModuleRegistry(moduleRegistry).approveModule(prop.target());
        emit DACEventsLib.ModuleAdded(address(this), prop.target());
    }

    function _executeRemoveModule(IManagementProposal prop) internal {
        if (legalWrapper.wrapperAddr != address(0)) {
            require(msg.sender == legalWrapper.wrapperAddr, DACErrorsLib.LegalWrapperExecutionExpected());
        }
        IModuleRegistry(moduleRegistry).removeModule(prop.target());
        emit DACEventsLib.ModuleRemoved(address(this), prop.target());
    }

    function _executeVoteDelegation(IManagementProposal prop) internal {
        (address token, address delegatee) = abi.decode(prop.data(), (address, address));
        IAssetController(assetController).delegateVotes(token, delegatee);
        emit DACEventsLib.VotesDelegated(token, delegatee);
    }

    function getCapitalCall(bytes32 calldataHash) external view returns (CapitalCall memory capitalCall) {
        capitalCall = IAssetController(assetController).getCapitalCall(calldataHash);
    }

    function getProposalVoting(uint256 proposalId) external view returns (address) {
        return IGovernanceSchema(governanceSchema).getProposal(proposalId);
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

    function getModuleRegistry() external view override returns (address) {
        return moduleRegistry;
    }

    function getAssetController() external view override(IDACCell, IDACCellAdapter) returns (address) {
        return assetController;
    }

    function getGovernanceSchema() external view override returns (address) {
        return governanceSchema;
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
}
