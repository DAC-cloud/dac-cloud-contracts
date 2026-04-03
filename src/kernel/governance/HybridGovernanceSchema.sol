// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig} from "../../interfaces/Structs.sol";
import {IGovernanceSchema} from "../../interfaces/IGovernanceSchema.sol";
import {IExecutableProposal} from "../../interfaces/IExecutableProposal.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {AssetCapability, DealCreationConfig, GovernanceStrategyConfig} from "../../interfaces/GovernanceStructs.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACManagementProposalType} from "./DACManagementProposals.sol";
import {HybridDACManagementProposalFactory} from "./factories/HybridDACManagementProposalFactory.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IVotes} from "../../lib/IVotes.sol";

contract HybridGovernanceSchema is IGovernanceSchema, Initializable {
    address public dacCell;
    IERC20 public wrappedMainToken;
    address public dealManager;
    address public assetController;
    address public proposalFactory;
    address public governanceOracle;

    GovernanceStrategyConfig private strategyConfig;
    DealCreationConfig private dealCreationConfig;
    uint256 private nextId;
    mapping(uint256 => address) private proposals;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _dacCell,
        address _wrappedMainToken,
        address _dealManager,
        address _assetController,
        address _proposalFactory,
        address _governanceOracle,
        GovernanceStrategyConfig calldata _strategyConfig
    ) external initializer {
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_wrappedMainToken != address(0), DACErrorsLib.NotAllowed());
        require(_dealManager != address(0), DACErrorsLib.NotAllowed());
        require(_assetController != address(0), DACErrorsLib.NotAllowed());
        require(_proposalFactory != address(0), DACErrorsLib.NotAllowed());
        require(_governanceOracle != address(0), DACErrorsLib.NotAllowed());

        dacCell = _dacCell;
        wrappedMainToken = IERC20(_wrappedMainToken);
        dealManager = _dealManager;
        assetController = _assetController;
        proposalFactory = _proposalFactory;
        governanceOracle = _governanceOracle;
        nextId = 1;

        _setStrategyConfig(_strategyConfig);
    }

    function createProposal(
        address creator,
        ProposalParams calldata params,
        uint256,
        bool dividendsEnabled
    ) external onlyDACCell returns (uint256 id, address proposal) {
        if (creator == dealManager) {
            require(
                params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE,
                DACErrorsLib.NotAuthorized()
            );
        } else {
            require(
                !(
                    params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE
                ),
                DACErrorsLib.NotAuthorized()
            );

            require(
                IVotes(address(wrappedMainToken)).getVotes(creator) > strategyConfig.qualification,
                DACErrorsLib.InsufficientBalance()
            );

            if (params.typ == DACManagementProposalType.ADD_EVALUATOR) {
                (uint256 dealId,) = abi.decode(params.data, (uint256, bytes));

                address dealCell = IDealManager(dealManager).deals(dealId);
                require(dealCell != address(0), DACErrorsLib.NotFound());

                require(
                    IDealManagerAdapter(dealManager).state(dealCell).active,
                    DACErrorsLib.InvalidDealState(IDealManagerAdapter(dealManager).state(dealCell).deal)
                );
            }

            if (params.typ == DACManagementProposalType.RECOVER_DEAL) {
                (uint256 dealId) = abi.decode(params.data, (uint256));
                require(IDealManager(dealManager).isRecoverable(dealId), DACErrorsLib.DealNotRecoverable());
            }

            if (params.typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
                require(dividendsEnabled, DACErrorsLib.DividendsNotEnabled());
            }

            if (params.typ == DACManagementProposalType.UPDATE_VOTING_CONFIG) {
                VotingConfig memory nextVotingConfig = abi.decode(params.data, (VotingConfig));
                _validateVotingConfig(nextVotingConfig);
            }
            else if (params.typ == DACManagementProposalType.UPDATE_GOVERNANCE_STRATEGY) {
                GovernanceStrategyConfig memory nextStrategy = abi.decode(params.data, (GovernanceStrategyConfig));
                _validateStrategyConfig(nextStrategy);
            }
            else if (params.typ == DACManagementProposalType.UPDATE_DEAL_CREATION_CONFIG) {
                _validateDealCreationConfig(abi.decode(params.data, (DealCreationConfig)));
            }
            else if (params.typ == DACManagementProposalType.UPDATE_GOVERNANCE_ORACLE) {
                require(params.target != address(0), DACErrorsLib.NotAllowed());
            }
        }

        _validateCapabilitySupport(params.typ);

        id = nextId++;
        proposal = HybridDACManagementProposalFactory(proposalFactory).deployProposal(
            id,
            dacCell,
            address(wrappedMainToken),
            governanceOracle,
            params,
            strategyConfig,
            _isHighQuorum(params.typ),
            _isBlockingEnabled(params.typ)
        );

        proposals[id] = proposal;
    }

    function consumeApprovedProposal(uint256 id, bool requiredOutcome)
        external
        onlyDACCell
        returns (address proposal)
    {
        proposal = proposals[id];
        require(proposal != address(0), DACErrorsLib.NotFound());
        IExecutableProposal(proposal).consumeExecution(requiredOutcome);
    }

    function setVotingConfig(VotingConfig calldata config) external onlyDACCell {
        _validateVotingConfig(config);
        strategyConfig.quorumPercent = config.quorumPercent;
        strategyConfig.highQuorumPercent = config.highQuorumPercent;
        strategyConfig.blockingPercent = config.blockingPercent;
        strategyConfig.duration = config.duration;
        strategyConfig.qualification = config.qualification;
        strategyConfig.executionValidityDuration = config.executionValidityDuration;
    }

    function setDealCreationConfig(DealCreationConfig calldata config) external onlyDACCell {
        _validateDealCreationConfig(config);
        dealCreationConfig = config;
    }

    function setStrategyConfig(GovernanceStrategyConfig calldata config) external onlyDACCell {
        _setStrategyConfig(config);
    }

    function setGovernanceOracle(address oracle) external onlyDACCell {
        require(oracle != address(0), DACErrorsLib.NotAllowed());
        governanceOracle = oracle;
    }

    function getVotingConfig() external view returns (VotingConfig memory config) {
        config = VotingConfig({
            quorumPercent: strategyConfig.quorumPercent,
            blockingPercent: strategyConfig.blockingPercent,
            highQuorumPercent: strategyConfig.highQuorumPercent,
            duration: strategyConfig.duration,
            qualification: strategyConfig.qualification,
            executionValidityDuration: strategyConfig.executionValidityDuration
        });
    }

    function getDealCreationConfig() external view returns (DealCreationConfig memory config) {
        config = dealCreationConfig;
    }

    function getProposal(uint256 id) external view returns (address proposal) {
        proposal = proposals[id];
    }

    function getStrategyConfig() external view returns (GovernanceStrategyConfig memory config) {
        config = strategyConfig;
    }

    function getGovernanceOracle() external view returns (address oracle) {
        oracle = governanceOracle;
    }

    modifier onlyDACCell() {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());
        _;
    }

    function _setStrategyConfig(GovernanceStrategyConfig memory config) internal {
        _validateStrategyConfig(config);
        strategyConfig = config;
    }

    function _validateStrategyConfig(GovernanceStrategyConfig memory config) internal view {
        _validateVotingConfig(
            VotingConfig({
                quorumPercent: config.quorumPercent,
                blockingPercent: config.blockingPercent,
                highQuorumPercent: config.highQuorumPercent,
                duration: config.duration,
                qualification: config.qualification,
                executionValidityDuration: config.executionValidityDuration
            })
        );
        require(config.blockingPercent > 0 || (!config.blockingOnAllProposals && !config.blockingOnHighQuorum), DACErrorsLib.InvalidVotingConfig());
        require(config.oraclePublishDeadline > 0 || !config.oraclePrimaryEnabled, DACErrorsLib.InvalidVotingConfig());
        require(config.fallbackWarmupDuration > 0, DACErrorsLib.InvalidVotingConfig());
        require(config.fallbackDuration > 0, DACErrorsLib.InvalidVotingConfig());
    }

    function _validateVotingConfig(VotingConfig memory config) internal view {
        require(config.quorumPercent > 0, DACErrorsLib.InvalidVotingConfig());
        require(config.highQuorumPercent > 0, DACErrorsLib.InvalidVotingConfig());
        require(config.duration > 0, DACErrorsLib.InvalidVotingConfig());
        require(config.executionValidityDuration > 0, DACErrorsLib.InvalidVotingConfig());
        require(config.quorumPercent <= MathLib.SCALE, DACErrorsLib.InvalidVotingConfig());
        require(config.blockingPercent <= MathLib.SCALE, DACErrorsLib.InvalidVotingConfig());
        require(config.highQuorumPercent <= MathLib.SCALE, DACErrorsLib.InvalidVotingConfig());

        uint256 totalReleasedVotable = IDealManager(dealManager).totalReleasedVotable();
        require(
            config.qualification == 0 || config.qualification < totalReleasedVotable / 2,
            DACErrorsLib.InvalidVotingConfig()
        );
    }

    function _validateDealCreationConfig(DealCreationConfig memory) internal pure {}

    function _validateCapabilitySupport(bytes4 typ) internal view {
        if (typ == DACManagementProposalType.MINT_MAIN_TOKENS) {
            require(IAssetController(assetController).supportsCapability(AssetCapability.MINT), DACErrorsLib.UnsupportedProposal());
        } else if (typ == DACManagementProposalType.BURN_MAIN_TOKENS) {
            require(IAssetController(assetController).supportsCapability(AssetCapability.BURN), DACErrorsLib.UnsupportedProposal());
        } else if (typ == DACManagementProposalType.CAPITAL_CALL) {
            require(
                IAssetController(assetController).supportsCapability(AssetCapability.CAPITAL_CALL),
                DACErrorsLib.UnsupportedProposal()
            );
        }
    }

    function _isHighQuorum(bytes4 typ) internal pure returns (bool) {
        return (
            typ == DACManagementProposalType.MINT_MAIN_TOKENS ||
            typ == DACManagementProposalType.UPDATE_GOVERNANCE_STRATEGY ||
            typ == DACManagementProposalType.UPDATE_DEAL_CREATION_CONFIG ||
            typ == DACManagementProposalType.UPDATE_GOVERNANCE_ORACLE ||
            typ == DACManagementProposalType.UPDATE_VOTING_CONFIG ||
            typ == DACManagementProposalType.UPDATE_LEGAL_WRAPPER ||
            typ == DACManagementProposalType.DIVIDEND_PAYOUT ||
            typ == DACManagementProposalType.ADD_MODULE ||
            typ == DACManagementProposalType.REMOVE_MODULE ||
            typ == DACManagementProposalType.TOGGLE_DIVIDENDS
        );
    }

    function _isBlockingEnabled(bytes4 typ) internal view returns (bool) {
        return (
            strategyConfig.blockingOnAllProposals ||
            (
                _isHighQuorum(typ) &&
                strategyConfig.blockingOnHighQuorum
            ) ||
            typ == DACManagementProposalType.APPROVE_OFFCHAIN_ACTION ||
            typ == DACManagementProposalType.REVOKE_AGENT_TOKENS ||
            typ == DACManagementProposalType.CAPITAL_CALL ||
            typ == DACManagementProposalType.APPROVE_DEAL ||
            typ == DACManagementProposalType.APPROVE_TRANCHE ||
            typ == DACManagementProposalType.ADD_EVALUATOR ||
            typ == DACManagementProposalType.BURN_MAIN_TOKENS ||
            typ == DACManagementProposalType.DELEGATE_VOTE_RIGHTS
        );
    }
}
