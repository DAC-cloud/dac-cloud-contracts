// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProposalParams, VotingConfig} from "../../interfaces/Structs.sol";
import {IGovernanceSchema} from "../../interfaces/IGovernanceSchema.sol";
import {IExecutableProposal} from "../../interfaces/IExecutableProposal.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {IDACManagementFactory} from "../interfaces/IDACManagementFactory.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {AssetCapability, DealCreationConfig, GovernanceStrategyConfig} from "../../interfaces/GovernanceStructs.sol";
import {MainToken} from "../tokens/MainToken.sol";
import {DACManagementProposalType} from "./DACManagementProposals.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

contract NativeGovernanceSchema is IGovernanceSchema, Initializable {
    address public dacCell;
    MainToken public mainToken;
    address public dealManager;
    address public proposalFactory;
    address public assetController;

    VotingConfig private votingConfig;
    DealCreationConfig private dealCreationConfig;
    uint256 private nextId;
    mapping(uint256 => address) private proposals;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _dacCell,
        address _mainToken,
        address _dealManager,
        address _assetController,
        address _proposalFactory,
        VotingConfig calldata _votingConfig
    ) external initializer {
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_mainToken != address(0), DACErrorsLib.NotAllowed());
        require(_dealManager != address(0), DACErrorsLib.NotAllowed());
        require(_assetController != address(0), DACErrorsLib.NotAllowed());
        require(_proposalFactory != address(0), DACErrorsLib.NotAllowed());

        dacCell = _dacCell;
        mainToken = MainToken(_mainToken);
        dealManager = _dealManager;
        assetController = _assetController;
        proposalFactory = _proposalFactory;
        nextId = 1;

        _setVotingConfig(_votingConfig);
    }

    function createProposal(
        address creator,
        ProposalParams calldata params,
        uint256 totalVotingSupply,
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
                mainToken.getVotes(creator) > votingConfig.qualification,
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
                revert DACErrorsLib.UnsupportedProposal();
            }
        }

        _validateCapabilitySupport(params.typ);

        id = nextId++;
        proposal = IDACManagementFactory(proposalFactory).deployProposal(
            id,
            params,
            dacCell,
            address(mainToken),
            totalVotingSupply,
            votingConfig
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
        _setVotingConfig(config);
    }

    function setDealCreationConfig(DealCreationConfig calldata config) external onlyDACCell {
        _validateDealCreationConfig(config);
        dealCreationConfig = config;
    }

    function setStrategyConfig(GovernanceStrategyConfig calldata config) external onlyDACCell {
        _validateStrategyConfig(config);
        votingConfig = VotingConfig({
            quorumPercent: config.quorumPercent,
            blockingPercent: config.blockingPercent,
            highQuorumPercent: config.highQuorumPercent,
            duration: config.duration,
            qualification: config.qualification,
            executionValidityDuration: config.executionValidityDuration
        });
    }

    function setGovernanceOracle(address) external pure {
        revert DACErrorsLib.UnsupportedProposal();
    }

    function getVotingConfig() external view returns (VotingConfig memory config) {
        config = votingConfig;
    }

    function getDealCreationConfig() external view returns (DealCreationConfig memory config) {
        config = dealCreationConfig;
    }

    function getStrategyConfig() external view returns (GovernanceStrategyConfig memory config) {
        config = GovernanceStrategyConfig({
            quorumPercent: votingConfig.quorumPercent,
            highQuorumPercent: votingConfig.highQuorumPercent,
            blockingPercent: votingConfig.blockingPercent,
            duration: votingConfig.duration,
            qualification: votingConfig.qualification,
            executionValidityDuration: votingConfig.executionValidityDuration,
            oraclePublishDeadline: 0,
            fallbackWarmupDuration: 0,
            fallbackDuration: 0,
            blockingOnAllProposals: false,
            blockingOnHighQuorum: false,
            oraclePrimaryEnabled: false
        });
    }

    function getGovernanceOracle() external pure returns (address oracle) {
        return address(0);
    }

    function getProposal(uint256 id) external view returns (address proposal) {
        proposal = proposals[id];
    }

    modifier onlyDACCell() {
        _onlyDACCell();
        _;
    }

    function _onlyDACCell() internal view {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());
    }

    function _setVotingConfig(VotingConfig memory config) internal {
        _validateVotingConfig(config);
        votingConfig = config;
    }

    function _validateStrategyConfig(GovernanceStrategyConfig memory config) internal view {
        require(config.oraclePublishDeadline == 0, DACErrorsLib.InvalidVotingConfig());
        require(config.fallbackWarmupDuration == 0, DACErrorsLib.InvalidVotingConfig());
        require(config.fallbackDuration == 0, DACErrorsLib.InvalidVotingConfig());
        require(!config.blockingOnAllProposals, DACErrorsLib.InvalidVotingConfig());
        require(!config.blockingOnHighQuorum, DACErrorsLib.InvalidVotingConfig());
        require(!config.oraclePrimaryEnabled, DACErrorsLib.InvalidVotingConfig());
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
}
