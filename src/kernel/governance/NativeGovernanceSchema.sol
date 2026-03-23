// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProposalParams, VotingConfig} from "../../interfaces/Structs.sol";
import {IGovernanceSchema} from "../../interfaces/IGovernanceSchema.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {IDACManagementFactory} from "../interfaces/IDACManagementFactory.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {MainToken} from "../tokens/MainToken.sol";
import {DACManagementProposalType} from "./DACManagementProposals.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

contract NativeGovernanceSchema is IGovernanceSchema, Initializable {
    address public dacCell;
    MainToken public mainToken;
    address public dealManager;
    address public proposalFactory;

    VotingConfig private votingConfig;
    uint256 private nextId;
    mapping(uint256 => address) private proposals;
    mapping(uint256 => bool) private executed;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _dacCell,
        address _mainToken,
        address _dealManager,
        address _proposalFactory,
        VotingConfig calldata _votingConfig
    ) external initializer {
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_mainToken != address(0), DACErrorsLib.NotAllowed());
        require(_dealManager != address(0), DACErrorsLib.NotAllowed());
        require(_proposalFactory != address(0), DACErrorsLib.NotAllowed());

        dacCell = _dacCell;
        mainToken = MainToken(_mainToken);
        dealManager = _dealManager;
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
                mainToken.balanceOf(creator) > votingConfig.qualification,
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
        }

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
        require(!executed[id], DACErrorsLib.ProposalAlreadyExecuted());
        require(
            IVoting(proposal).isResolved() && IVoting(proposal).outcome() == requiredOutcome,
            DACErrorsLib.VoteNotPassed()
        );

        executed[id] = true;
    }

    function setVotingConfig(VotingConfig calldata config) external onlyDACCell {
        _setVotingConfig(config);
    }

    function getVotingConfig() external view returns (VotingConfig memory config) {
        config = votingConfig;
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

    function _validateVotingConfig(VotingConfig memory config) internal view {
        require(config.quorumPercent > 0, DACErrorsLib.InvalidVotingConfig());
        require(config.highQuorumPercent > 0, DACErrorsLib.InvalidVotingConfig());
        require(config.duration > 0, DACErrorsLib.InvalidVotingConfig());
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
