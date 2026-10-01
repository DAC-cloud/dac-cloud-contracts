// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProposalParams, DealParams, VotingConfig} from "../../../interfaces/Structs.sol";
import {IVotes} from "../../../lib/IVotes.sol";
import {IVoting} from "../../../interfaces/IVoting.sol";
import {IAgentToken} from "../../../interfaces/IAgentToken.sol";
import {IDeal} from "../../../interfaces/IDeal.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {IDACCell} from "../../../interfaces/IDACCell.sol";
import {IDealManager} from "../../../interfaces/IDealManager.sol";
import {IDealManagerAdapter} from "../../../kernel/interfaces/IDealManagerAdapter.sol";
import {IDealCellAdapter} from "../../../kernel/interfaces/IDealCellAdapter.sol";
import {DealManagementProposal} from "../../../kernel/governance/DealManagementProposal.sol";
import {Deal} from "../../../kernel/Deal.sol";
import {CoreDealManagementType} from "../governance/CoreDealManagementProposals.sol";
import {DACErrorsLib} from "../../../interfaces/DACErrorsLib.sol";

/// @title AgentDeal
/// @notice A core deal that lets its home DAC act as an agent inside one other
///         (host) DAC: it holds the host's AgentToken, stakes into the host's
///         deals, holds the host's StakedAgent, participates in host deal
///         governance, can originate new host deals, earns host incentives, and
///         routes those incentives back to the home treasury.
///
///         This is the inverse of `DACDeal` (which owns a child DAC). Two
///         governance layers apply: the home DAC's staked agents govern this
///         deal's host-side behaviour through the proposals below, while the
///         host DAC's own governance still has to pass anything the deal
///         proposes there. The deal holds host `AgentToken`/`StakedAgent`, and
///         host `MainToken` only transiently as claimed rewards on their way home
///         (RETURN_ASSET_TO_DAC); it never delegates host main token and has no
///         host *DAC-level* proposal path, so its power inside the host is
///         bounded to deal-level agency by construction.
contract AgentDeal is Deal {
    using SafeERC20 for IERC20;

    struct HostDNA {
        address hostAgentToken;
        address hostMainToken;
    }

    // The single host DAC this deal is an agent inside is stored in `managedEntity`.
    HostDNA public hostDNA;

    // Events (host = the DAC this deal acts as an agent inside).
    event HostStaked(address indexed hostDealCell, uint256 amount);
    event HostStakeApproved(address indexed hostDealCell, uint256 amount);
    event HostDealCreated(address indexed hostDealCell, uint256 indexed hostDealId);
    event HostProposalCreated(address indexed hostDealCell, uint256 indexed hostProposalId, bytes4 typ);
    event HostVoteCast(address indexed hostDealCell, uint256 indexed hostProposalId, bool support);
    event HostRewardClaimed(address indexed hostDealCell, uint256 evaluatorId);
    event HostUnstaked(address indexed hostDealCell);
    event HostInvited(address indexed hostDealCell, address indexed invitee, bool grantInviteRight);
    event AssetReturnedToDAC(address indexed token, uint256 amount);

    function initialize(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _agentToken,
        address _mainToken,
        address _proposer,
        address _factory
    ) external initializer {
        __Deal_init(
            _id,
            _dac,
            _governanceFactory,
            _agentToken,
            _mainToken,
            _proposer,
            _factory
        );
    }

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override {
        // Bind the single host DAC this deal will act as an agent inside.
        address hostDac = params.dealTarget;
        require(hostDac != address(0) && hostDac != dacCell, DACErrorsLib.NotAllowed());

        managedEntity = hostDac;

        // Reading the host kernel getters also asserts the target is a real DAC.
        hostDNA = HostDNA({
            hostAgentToken: IDACCell(hostDac).getAgentToken(),
            hostMainToken: IDACCell(hostDac).getMainToken()
        });

        _registerRelatedContract(hostDac, bytes32("HOST_DAC"), false, true);
        _registerRelatedContract(hostDNA.hostAgentToken, bytes32("HOST_AGENT_TOKEN"), false, false);
        _registerRelatedContract(hostDNA.hostMainToken, bytes32("HOST_MAIN_TOKEN"), false, false);
    }

    function _checkStackedAgentProposalSupported(ProposalParams calldata params)
        internal
        virtual
        override
        returns (bool supported)
    {
        supported = (
            params.typ == CoreDealManagementType.HOST_STAKE ||
            params.typ == CoreDealManagementType.HOST_APPROVE_STAKE ||
            params.typ == CoreDealManagementType.HOST_CREATE_DEAL ||
            params.typ == CoreDealManagementType.HOST_CREATE_PROPOSAL ||
            params.typ == CoreDealManagementType.HOST_VOTE ||
            params.typ == CoreDealManagementType.HOST_CLAIM_REWARD ||
            params.typ == CoreDealManagementType.HOST_UNSTAKE ||
            params.typ == CoreDealManagementType.HOST_INVITE ||
            params.typ == CoreDealManagementType.RETURN_ASSET_TO_DAC
        );
    }

    function _beforeCreateProposal(ProposalParams calldata params) internal virtual override {
        // Fail fast: ensure the referenced host deal belongs to the bound host
        // DAC at proposal-creation time. Execution re-validates regardless.
        if (
            params.typ == CoreDealManagementType.HOST_STAKE ||
            params.typ == CoreDealManagementType.HOST_APPROVE_STAKE ||
            params.typ == CoreDealManagementType.HOST_CLAIM_REWARD
        ) {
            (address hostDealCell,) = abi.decode(params.data, (address, uint256));
            _resolveHostDeal(hostDealCell);
        }
        else if (params.typ == CoreDealManagementType.HOST_CREATE_PROPOSAL) {
            (address hostDealCell,) = abi.decode(params.data, (address, ProposalParams));
            _resolveHostDeal(hostDealCell);
        }
        else if (params.typ == CoreDealManagementType.HOST_VOTE) {
            (address hostDealCell,,) = abi.decode(params.data, (address, uint256, bool));
            _resolveHostDeal(hostDealCell);
        }
        else if (params.typ == CoreDealManagementType.HOST_UNSTAKE) {
            address hostDealCell = abi.decode(params.data, (address));
            _resolveHostDeal(hostDealCell);
        }
        else if (params.typ == CoreDealManagementType.HOST_INVITE) {
            (address hostDealCell,,) = abi.decode(params.data, (address, address, bool));
            _resolveHostDeal(hostDealCell);
        }
    }

    function _executeModuleManagementProposal(DealManagementProposal proposal) internal virtual override {
        bytes4 typ = proposal.typ();

        if (typ == CoreDealManagementType.HOST_STAKE) {
            (address hostDealCell, uint256 amount) = abi.decode(proposal.data(), (address, uint256));
            _resolveHostDeal(hostDealCell);

            // Pre-approval staking: moves host agent tokens into the host deal.
            IAgentToken(hostDNA.hostAgentToken).stakeToDeal(hostDealCell, amount);

            // StakedAgent is ERC20Votes and does not auto-delegate; self-delegate
            // so this position carries host voting and proposing power.
            IVotes(IDealCell(hostDealCell).stakeToken()).delegate(address(this));

            emit HostStaked(hostDealCell, amount);
        }

        else if (typ == CoreDealManagementType.HOST_APPROVE_STAKE) {
            (address hostDealCell, uint256 amount) = abi.decode(proposal.data(), (address, uint256));
            _resolveHostDeal(hostDealCell);

            // Post-approval staking: lets a host ADD_STAKE proposal pull more stake.
            IERC20(hostDNA.hostAgentToken).forceApprove(hostDealCell, amount);

            // The stake minted by the host's ADD_STAKE must carry voting power too;
            // delegation can be set before any balance exists.
            IVotes(IDealCell(hostDealCell).stakeToken()).delegate(address(this));

            emit HostStakeApproved(hostDealCell, amount);
        }

        else if (typ == CoreDealManagementType.HOST_CREATE_DEAL) {
            DealParams memory hostDealParams = abi.decode(proposal.data(), (DealParams));

            // createDealProposal enforces params.proposer == msg.sender.
            hostDealParams.proposer = address(this);

            address hostManager = IDACCell(managedEntity).getDealManager();
            (uint256 hostDealId, address hostDealCell,,) =
                IDealManager(hostManager).createDealProposal(hostDealParams);

            // The proposer is force-staked the host's minInitialAgentStake into the
            // new deal; self-delegate so that position carries voting power.
            IVotes(IDealCell(hostDealCell).stakeToken()).delegate(address(this));

            emit HostDealCreated(hostDealCell, hostDealId);
        }

        else if (typ == CoreDealManagementType.HOST_CREATE_PROPOSAL) {
            (address hostDealCell, ProposalParams memory hostParams) =
                abi.decode(proposal.data(), (address, ProposalParams));
            address hostDeal = _resolveHostDeal(hostDealCell);

            uint256 hostProposalId = IDeal(hostDeal).createStakedAgentProposal(hostParams);

            emit HostProposalCreated(hostDealCell, hostProposalId, hostParams.typ);
        }

        else if (typ == CoreDealManagementType.HOST_VOTE) {
            (address hostDealCell, uint256 hostProposalId, bool support) =
                abi.decode(proposal.data(), (address, uint256, bool));
            address hostDeal = _resolveHostDeal(hostDealCell);

            address hostProposal = IDeal(hostDeal).getProposal(hostProposalId);
            IVoting(hostProposal).vote(support);

            emit HostVoteCast(hostDealCell, hostProposalId, support);
        }

        else if (typ == CoreDealManagementType.HOST_CLAIM_REWARD) {
            (address hostDealCell, uint256 evaluatorId) = abi.decode(proposal.data(), (address, uint256));
            _resolveHostDeal(hostDealCell);

            // Host main-token rewards earned by this agent land on this contract.
            IDealCell(hostDealCell).claimMainToken(evaluatorId);

            emit HostRewardClaimed(hostDealCell, evaluatorId);
        }

        else if (typ == CoreDealManagementType.HOST_UNSTAKE) {
            address hostDealCell = abi.decode(proposal.data(), (address));
            _resolveHostDeal(hostDealCell);

            // Returns host agent tokens here, or opens a host PERMIT_UNSTAKE if the
            // host deal is already approved.
            IDealCell(hostDealCell).unstake();

            emit HostUnstaked(hostDealCell);
        }

        else if (typ == CoreDealManagementType.HOST_INVITE) {
            (address hostDealCell, address invitee, bool grantInviteRight) =
                abi.decode(proposal.data(), (address, address, bool));
            _resolveHostDeal(hostDealCell);

            // As proposer of a host deal this contract is its sole initial inviter;
            // whitelist-only host deals cannot be staffed without this path.
            IDealCell(hostDealCell).invite(invitee, grantInviteRight);

            emit HostInvited(hostDealCell, invitee, grantInviteRight);
        }

        else if (typ == CoreDealManagementType.RETURN_ASSET_TO_DAC) {
            address token = proposal.target();
            uint256 amount = abi.decode(proposal.data(), (uint256));

            // Routing the home main token through the treasury path would interfere
            // with main-token obligation accounting; earned host assets are foreign
            // tokens and route cleanly.
            require(token != mainTokenAddr, DACErrorsLib.NotAllowed());

            IERC20(token).forceApprove(dealCell, amount);
            IDealCellAdapter(dealCell).transferCapital(token, amount);

            emit AssetReturnedToDAC(token, amount);
        }

        else {
            revert DACErrorsLib.UnsupportedProposal();
        }
    }

    /// @dev Confirms `hostDealCell` is a real deal registered in the bound host
    ///      DAC's deal manager, and returns the host Deal contract address.
    function _resolveHostDeal(address hostDealCell) internal returns (address hostDeal) {
        address hostManager = IDACCell(managedEntity).getDealManager();
        require(
            IDealManagerAdapter(hostManager).state(hostDealCell).id != 0,
            DACErrorsLib.InvalidDealAddress()
        );
        require(IDealCell(hostDealCell).isValidDeal(), DACErrorsLib.InvalidDealAddress());
        hostDeal = address(IDealCell(hostDealCell).deal());
    }

    function _beforeWithdrawCapital() internal override {
        // Idle funding-token balances are returned to the home DAC by the base
        // withdraw path. Earned host assets are routed home via RETURN_ASSET_TO_DAC.
    }
}
