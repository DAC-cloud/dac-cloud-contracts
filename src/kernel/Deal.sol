// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DealParams, ProposalParams, VotingConfig} from "../interfaces/Structs.sol";
import {IExecutableProposal} from "../interfaces/IExecutableProposal.sol";
import {IDealCell} from "../interfaces/IDealCell.sol";
import {IDealCellAdapter} from "./interfaces/IDealCellAdapter.sol";
import {IDeal} from "../interfaces/IDeal.sol";
import {DealCellGovernanceLib} from "./libraries/DealCellGovernanceLib.sol";
import {DealManagementProposal} from "./governance/DealManagementProposal.sol";
import {AbstractDealManagementType} from "./governance/AbstractDealManagementProposals.sol";
import {DACErrorsLib} from "../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../interfaces/DACEventsLib.sol";

abstract contract Deal is IDeal, ReentrancyGuard, Initializable {

    address private factory;
    
    uint256 internal id;
    address internal dacCell;
    address internal governanceFactory;

    address internal dealCell;

    address internal agentTokenAddr;
    address internal mainTokenAddr;

    address private proposer;

    address public managedEntity;

    // DAC cell in the DAC paradigm is analogue of the "balance sheets"
    // Can store and manage capital on long term basis.
    
    // While Deal can have capital on it's "contract balance", Deal is not a storage
    // for it, and only escrow capital within the Deal logic.

    // DealManager and DealCell contracts are not storing capital and fast forwarding
    // the balance. Any amount of tokens sent directly to this contracts bypass contract
    // flows - is effectively lost.

    // Link with document management system
    string public linkHash;

    // Governance
    uint256 private nextId;
    mapping(uint256 => address) private proposals;

    VotingConfig private _votingConfig;
    
    constructor() {
        _disableInitializers();
    }

    function __Deal_init(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _agentToken,
        address _mainToken,
        address _proposer,
        address _factory
    ) internal onlyInitializing {
        nextId = 1;

        factory = _factory;
        id = _id;
        governanceFactory = _governanceFactory;
        dacCell = _dac;
        agentTokenAddr = _agentToken;
        mainTokenAddr = _mainToken;
        proposer = _proposer;
    }

    function joinDac(
        address _dealCell
    ) external {
        require(msg.sender == factory, DACErrorsLib.NotAuthorized());

        dealCell = _dealCell;
    }

    function _beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) internal virtual {}
    function beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external onlyDealCell {
        _beforeInitialize(params, defaultVotingConfig);
        _votingConfig = defaultVotingConfig;
    }

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) internal virtual {}
    function afterInitialize(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external onlyDealCell {
        _afterInitialize(params, defaultVotingConfig);
    }
 
    function _onVoluntaryStake(address staker, uint256 amount) internal virtual {}
    function onVoluntaryStake(address staker, uint256 amount) external onlyDealCell {
        _onVoluntaryStake(staker, amount);
    }

    function _beforeEveryStake(address staker, uint256 amount) internal virtual {}
    function beforeEveryStake(address staker, uint256 amount) external onlyDealCell {
        _beforeEveryStake(staker, amount);
    }

    function _afterEveryStake(address staker, uint256 amount) internal virtual {}
    function afterEveryStake(address staker, uint256 amount) external onlyDealCell {
        _afterEveryStake(staker, amount);
    }

    function _beforeApprove(uint256 trancheId) internal virtual {}
    function beforeApproveFunding(uint256 trancheId) external onlyDealCell {
        _beforeApprove(trancheId);
    }
    
    function _afterApprove(uint256 trancheId) internal virtual {}
    function afterApproveFunding(uint256 trancheId) external onlyDealCell {
        _afterApprove(trancheId);
    }

    function _afterInvite(address invitee, bool grantInviteRight) internal virtual {}
    function onInvite(address invitee, bool grantInviteRight) external onlyDealCell {
        _afterInvite(invitee, grantInviteRight);
    }

    function _afterUnstake(address staker, uint256 amount) internal virtual {}
    function onUnstake(address staker, uint256 amount) external onlyDealCell {
        _afterUnstake(staker, amount);
    }

    function _beforeWithdrawCapital() internal virtual {}
    function beforeWithdrawCapital() external onlyDealCell {
        _beforeWithdrawCapital();
        DealCellGovernanceLib.prepareWithdrawal(dealCell);
    }

    function _afterWithdrawCapital() internal virtual {}
    function afterWithdrawCapital() external onlyDealCell {
        _afterWithdrawCapital();
    }

    function _beforeMarkAsSuccess(uint256 rewardPercent) internal virtual {}
    function onMarkAsSuccess(uint256 rewardPercent) external onlyDealCell {
        _beforeMarkAsSuccess(rewardPercent);
    }

    function _onDealRewardAllocated(uint256 amount) internal virtual {}
    function onDealRewardAllocated(uint256 amount) external onlyDealCell {
        _onDealRewardAllocated(amount);
    }

    function _afterMarkAsFailed(uint256 slashPercent) internal virtual {}
    function onMarkAsFailed(uint256 slashPercent) external onlyDealCell {
        _afterMarkAsFailed(slashPercent);
    }

    function _beforeExtendDeadline(uint256 oldDeadline, uint256 newDeadline) internal virtual {}
    function onExtendDeadline(uint256 oldDeadline, uint256 newDeadline) external onlyDealCell {
        _beforeExtendDeadline(oldDeadline, newDeadline);
    }

    function _beforeClose() internal virtual {}
    function beforeClose() external onlyDealCell {
        _beforeClose();
    }

    function _beforeRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}
    function beforeRecovery(address liquidator, uint256 liquidatorStake) external onlyDealCell {
        _beforeRecovery(liquidator, liquidatorStake);
    }

    function _afterRecovery(address liquidator, uint256 liquidatorStake) internal virtual {}
    function afterRecovery(address liquidator, uint256 liquidatorStake) external onlyDealCell {
        _afterRecovery(liquidator, liquidatorStake);
    }

    function _beforeClaimMainToken(address grantee, uint256 amount) internal virtual {}
    function beforeClaimMainToken(address grantee, uint256 amount) external onlyDealCell {
        _beforeClaimMainToken(grantee, amount);
    }

    function _afterClaimMainToken(address grantee, uint256 amount) internal virtual {}
    function afterClaimMainToken(address grantee, uint256 amount) external onlyDealCell {
        _afterClaimMainToken(grantee, amount);
    }

    function _beforeCreateProposal(ProposalParams calldata params) internal virtual {}
    function _afterCreateProposal(uint256 proposalId, ProposalParams calldata params) internal virtual {}

    function createStakedAgentProposal(ProposalParams calldata params) external returns (uint256 proposalId) {
        _beforeCreateProposal(params);

        bool isBase = DealCellGovernanceLib.checkStakedAgentProposal(params, dealCell, _votingConfig);

        if (!isBase) {
            // If type is not a basic Deal governance type, requiering derived contracts to validate
            require(
                _checkStackedAgentProposalSupported(params),
                DACErrorsLib.ProposalNotSupported()
            );
        }

        proposalId = nextId++;

        DealCellGovernanceLib.createStakedAgentProposal(
            proposalId,
            params,
            dacCell,
            dealCell,
            _votingConfig,
            governanceFactory,
            proposals
        );

        _afterCreateProposal(proposalId, params);
    }

    function _checkStackedAgentProposalSupported(ProposalParams calldata) internal virtual returns (bool supported) {
        // Concrete Deal implementation overrides this to indicate if the governance proposal is supported
        supported = false;
    }

    function _beforeExecuteProposal(uint256 proposalId) internal virtual {}
    function _afterExecuteProposal(uint256 proposalId) internal virtual {}

    function executeStakedAgentProposal(uint256 proposalId) external {
        address proposalAddr = getProposal(proposalId);
        IExecutableProposal(proposalAddr).consumeExecution(true);

        _beforeExecuteProposal(proposalId);

        DealManagementProposal prop = DealManagementProposal(proposalAddr);
        bytes4 typ = (prop).typ();

        if (typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG) {
            _votingConfig = abi.decode(prop.data(), (VotingConfig));

            emit DACEventsLib.VotingConfigUpdate(dealCell, proposalId, _votingConfig);
        }

        else {
            if (
                !IDealCellAdapter(dealCell).executeCellAgentProposal(prop)
            ) {
                // Forward to module if not executed by cell

                _executeModuleManagementProposal(prop);
            }            
        }
        
        emit DACEventsLib.DealManagementProposalExecuted(dealCell, proposalId, typ);

        _afterExecuteProposal(proposalId);
    }

    function _executeModuleManagementProposal(DealManagementProposal) internal virtual {
        // Children override this to handle their specific proposals
        revert DACErrorsLib.ProposalNotSupported();
    }

    function _onMessageDeal(bytes4, bytes calldata) internal virtual returns (bool) { return true; }
    function onMessageDeal(bytes4 message, bytes calldata data) external onlyDealCell returns (bool) {
        return _onMessageDeal(message, data);
    }
    
    function _onLegalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) internal virtual {}
    function onLegalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external onlyDealCell {
        _onLegalWrapperMessage(legalWrapper, messageKind, message);
    }

    function _registerRelatedContract(address relatedContract, bytes32 role, bool controlled, bool managed) internal {
        if (relatedContract == address(0)) {
            return;
        }

        if (controlled) {
            IDealCellAdapter(dealCell).registerControlledAddress(relatedContract);
        }

        emit DACEventsLib.DealRelatedContract(
            dacCell,
            id,
            relatedContract,
            address(this),
            dealCell,
            role,
            controlled,
            managed
        );
    }

    function getCell() external view returns (address) { return dealCell; }
    
    function getProposal(uint256 proposalId) public view returns (address) {
        require(proposals[proposalId] != address(0), DACErrorsLib.InvalidProposal());
        return proposals[proposalId];
    }

    function votingConfig() public view returns (VotingConfig memory) { return _votingConfig; }

    modifier onlyDealCell() {
        _onlyDealCell();
        _;
    }

    modifier onlyStakedAgent() {
        _onlyStakedAgent();
        _;
    }

    function _onlyDealCell() internal view {
        require(msg.sender == dealCell, DACErrorsLib.NotAuthorized());
    }

    function _onlyStakedAgent() internal view {
        require(IERC20(IDealCell(dealCell).stakeToken()).balanceOf(msg.sender) > 0, DACErrorsLib.NoStake());
    }
    
}
