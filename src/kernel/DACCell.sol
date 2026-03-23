// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig, CapitalCall, LegalWrapper} from "../interfaces/Structs.sol";
import {IVoting} from "../interfaces/IVoting.sol";
import {IAssetController} from "../interfaces/IAssetController.sol";
import {IGovernanceSchema} from "../interfaces/IGovernanceSchema.sol";
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
import {NativeGovernanceSchemaFactory} from "./governance/factories/NativeGovernanceSchemaFactory.sol";
import {DACManagementProposal} from "./governance/DACManagementProposal.sol";
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
    MainToken private mainToken;
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

        mainToken = MainToken(_mainToken);
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
            proposalFactory,
            initialVotingConfig
        );

        mainToken.dacInit(dealManager, assetController);
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
        DACManagementProposal prop = DACManagementProposal(
            IGovernanceSchema(governanceSchema).consumeApprovedProposal(id, true)
        );
        bytes4 typ = prop.typ();
        
        if (typ == DACManagementProposalType.UPDATE_VOTING_CONFIG) {
            IGovernanceSchema(governanceSchema).setVotingConfig(abi.decode(prop.data(), (VotingConfig)));

            emit DACEventsLib.VotingConfigUpdate(id, IGovernanceSchema(governanceSchema).getVotingConfig());
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
            IAssetController(assetController).mintMainToTreasury(uint256(prop.i()));
            emit DACEventsLib.TokenMinted(id, uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.BURN_MAIN_TOKENS) {
            IAssetController(assetController).burnMainFromTreasury(uint256(prop.i()));
            emit DACEventsLib.TokenBurnt(id, uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.MINT_AGENT_TOKENS) {
            agentToken.mint(address(prop.target()), uint256(prop.i()));

            emit DACEventsLib.AgentTokenMinted(id, prop.target(), uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.REVOKE_AGENT_TOKENS) {
            agentToken.burnFrom(prop.target(), uint256(prop.i()));

            emit DACEventsLib.AgentTokenRevoked(id, prop.target(), uint256(prop.i()));
        }

        else if (typ == DACManagementProposalType.CAPITAL_CALL) {
            (address treasuryToken, uint256 cashAmount) = abi.decode(
                prop.data(),
                (address, uint256)
            );

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

            IAssetController(assetController).recordDividendPayout(id, token, totalPayout, merkleRoot);

            emit DACEventsLib.DividendPayout(id, token, totalPayout, merkleRoot);
        }

        else if (
            typ == DACManagementProposalType.APPROVE_DEAL || 
            typ == DACManagementProposalType.APPROVE_TRANCHE
        ) {
            (uint256 dealId, uint256 trancheId, uint256 rewardsLimit) = abi.decode(
                prop.data(),
                (uint256, uint256, uint256)
            );

            IAssetController(assetController).approveFunding(dealId, trancheId, rewardsLimit);
            IDealManagerAdapter(dealManager).approveFunding(dealId, trancheId, rewardsLimit);
        }

        else if (typ == DACManagementProposalType.ADD_MODULE) {
            IModuleRegistry(moduleRegistry).approveModule(prop.target());

            emit DACEventsLib.ModuleAdded(address(this), prop.target());
        }

        else if (typ == DACManagementProposalType.REMOVE_MODULE) {
            if (legalWrapper.wrapperAddr != address(0)) {
                require(
                    msg.sender == legalWrapper.wrapperAddr,
                    DACErrorsLib.LegalWrapperExecutionExpected()
                );
            }

            IModuleRegistry(moduleRegistry).removeModule(prop.target());

            emit DACEventsLib.ModuleRemoved(address(this), prop.target());
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

            IAssetController(assetController).delegateVotes(token, delegatee);

            emit DACEventsLib.VotesDelegated(token, delegatee);
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
