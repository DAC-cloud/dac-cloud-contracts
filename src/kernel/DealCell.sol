// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DealParams, VotingConfig, ProposalParams, Tranche} from "../interfaces/Structs.sol";
import {IDealManagerAdapter} from "./interfaces/IDealManagerAdapter.sol";
import {IDeal} from "../interfaces/IDeal.sol";
import {IDealCell} from "../interfaces/IDealCell.sol";
import {StakedAgent} from "./tokens/StakedAgent.sol";
import {StakedAgentFactory} from "./tokens/factories/TokenFactories.sol";
import {DealManagementProposal} from "./governance/DealManagementProposal.sol";
import {DealCellGovernanceLib} from "./libraries/DealCellGovernanceLib.sol";
import {AbstractDealManagementType} from "./governance/AbstractDealManagementProposals.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {DACErrorsLib} from "../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../interfaces/DACEventsLib.sol";

contract DealCell is IDealCell, ReentrancyGuard, Initializable {

    address private factory;

    address public manager;
    
    uint256 internal id;
    address internal dacCell;
    address internal governanceFactory;
    
    address internal agentTokenAddr;
    address internal mainTokenAddr;

    address private proposer;

    IDeal public deal;
    
    StakedAgent internal token; 

    // Entities in the DAC paradigm are analogue of the "balance sheets"
    // Can store and manage capital on long term basis.
    // While Deal can have capital on it's "contract balance", Deal is not a storage
    // for it, and only escrow capital within the Deal logic.
    
    uint256 internal _tokenRewardsLimit;
    
    uint256 public startTime;
    uint256 internal _approveDeadline;
    uint256 internal _evaluationDeadline;
    uint256 internal _dealDeadline;

    // Name and description
    string public name;
    string public description;

    // Link with document management system
    string public linkHash;

    // Funding
    address[] internal _fundingTokens;
    mapping(address => uint256) internal _requestedFunding;

    // Tranches indexed by proposalId
    mapping(uint256 => Tranche) internal _fundingTranches;

    // Deal state
    bool internal approved;
    bool internal closed;
    bool internal recovery;

    bool internal vetoEnabled;
    bool internal earlyReturns;
    bool internal isWhitelistOnly; 
    
    // General metrics for abstract Deal
    uint256 internal rewardsConverted;

    // Indexed by funding token
    mapping(address => uint256) internal investedCapital;
    mapping(address => uint256) internal returnedCapital;

    // Rewards unlocked
    mapping(address => uint256) internal claimableRewards;

    // Whitelist
    mapping(address => bool) internal isWhitelisted;
    mapping(address => bool) internal canInviteOthers;

    address[] internal holders; // historical, only for claimable tracking

    // Governance
    VotingConfig private _votingConfig;

    constructor() {
        _disableInitializers();
    }

    struct DACAddresses {
        address _deployer;
        address _dac;
        address _dealManager;
        address _governanceFactory;
        address _agentToken;
        address _mainToken;
        address _proposer;
    }

    function initialize(
        uint256 _id,
        DACAddresses memory addresses
    ) public initializer {
        id = _id;
    
        factory = addresses._deployer;
        dacCell = addresses._dac;
        manager = addresses._dealManager;
        governanceFactory = addresses._governanceFactory;
        agentTokenAddr = addresses._agentToken;
        mainTokenAddr = addresses._mainToken;
        proposer = addresses._proposer;
    }

    function initializeDealCell(
        address _deal,
        address _stakedAgentFactory,
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external {
        require(msg.sender == factory, DACErrorsLib.NotAuthorized());
        require(startTime == 0, DACErrorsLib.AlreadyInitialized());

        deal = IDeal(_deal);

        token = StakedAgent(StakedAgentFactory(_stakedAgentFactory).deployStakedAgentToken(
            address(this),
            params.name,
            ERC20(agentTokenAddr).symbol()
        ));

        startTime = block.timestamp;

        name = params.name;
        description = params.description;

        linkHash = params.linkHash;

        _tokenRewardsLimit = params.rewardsLimit;
        _approveDeadline = params.approveDeadline;
        _evaluationDeadline = params.evaluationDeadline;
        _dealDeadline = params.dealDeadline;

        if (params.fundingAmount > 0) {
            if (_requestedFunding[params.fundingToken] == 0) {
                _fundingTokens.push(params.fundingToken);
            }
            _requestedFunding[params.fundingToken] = params.fundingAmount;
        }

        _fundingTranches[0] = Tranche({
            token: params.fundingToken,
            amount: params.fundingAmount,
            rewards: params.rewardsLimit,
            settled: false
        });

        vetoEnabled = params.vetoEnabled;

        isWhitelistOnly = true;
        isWhitelisted[proposer] = true;
        canInviteOthers[proposer] = true;

        emit DACEventsLib.Invited(proposer, true);

        deal.beforeInitialize(params, defaultVotingConfig);
    }
 
    function onDACInit(
        DealParams calldata params,
        VotingConfig calldata defaultVotingConfig
    ) external onlyDealManager {
        emit DACEventsLib.DealInitialized(dacCell, id, address(deal), params);

        deal.afterInitialize(params, defaultVotingConfig);
    }

    function registerControlledAddress(address controlled) external onlyDeal {
        IDealManagerAdapter(manager).registerControlledAddress(controlled);
    }

    function stake(address staker, uint256 amount) internal {
        DealCellGovernanceLib.stake(
            dacCell,
            staker,
            amount,
            id,
            deal,
            token,
            holders
        );
    }

    function onAgentTokenStaked(address staker, uint256 amount) external {
        require(msg.sender == agentTokenAddr || msg.sender == dacCell, DACErrorsLib.NotAuthorized());

        // if the deal is approved no more direct stakes allowed
        require(!approved, DACErrorsLib.DealAlreadyApproved());

        if (isWhitelistOnly) {
            require(isWhitelisted[staker], DACErrorsLib.NotWhitelistedAgent());
        }

        stake(staker, amount);

        deal.onVoluntaryStake(staker, amount);
    }

    function approveFunding(uint256 trancheId, uint256 rewardsLimit) external onlyDealManager {
        deal.beforeApproveFunding(trancheId);

        (_tokenRewardsLimit, rewardsConverted) = DealCellGovernanceLib.approveFunding(
            dacCell,
            id,
            trancheId,
            approved,
            _approveDeadline,
            _tokenRewardsLimit,
            rewardsConverted,
            rewardsLimit,
            deal,
            _fundingTranches,
            investedCapital
        );

        if (!approved) {
            approved = true;
        
            emit DACEventsLib.DealActivated(dacCell, id, address(deal), token.totalSupply());
        }

        deal.afterApproveFunding(trancheId);
    }

    function invite(address invitee, bool grantInviteRight) external nonReentrant {
        require(isWhitelistOnly, DACErrorsLib.NotWhitelistDeal());

        if (msg.sender != address(this)) {
            require(isWhitelisted[msg.sender] && canInviteOthers[msg.sender], DACErrorsLib.NotAuthorized());
        }
        
        if(!isWhitelisted[invitee]) {
            isWhitelisted[invitee] = true;
            canInviteOthers[invitee] = grantInviteRight;
            
            emit DACEventsLib.Invited(invitee, grantInviteRight);

            deal.onInvite(invitee, grantInviteRight);
        }   
    }

    function unstake() external nonReentrant {
        DealCellGovernanceLib.unstakeAgent(
            dacCell,
            id,
            deal,
            closed,
            approved,
            recovery,
            _approveDeadline,
            agentTokenAddr,
            token
        );
    }

    function transferCapital(address _token, uint256 amount) external onlyDeal {
        DealCellGovernanceLib.transferCapitalFromDeal(
            id,
            address(deal),
            _token,
            amount,
            dacCell,
            returnedCapital
        );
    }

    function withdrawCapital() external nonReentrant {
        DealCellGovernanceLib.withdrawCapital(
            id,
            earlyReturns,
            dacCell,
            _dealDeadline,
            token,
            deal,
            _fundingTokens,
            returnedCapital
        );
    }

    function markAsSuccess(uint256 rewardPercent) external onlyDealManager returns (uint256 currentReward) {
        require(!closed, DACErrorsLib.DealIsClosed());
        
        (rewardsConverted, currentReward) = DealCellGovernanceLib.markAsSuccess(
            rewardPercent,
            id,
            dacCell,
            token,
            deal,
            rewardsConverted,
            _tokenRewardsLimit,
            holders,
            claimableRewards
        );
    }

    function markAsFailed(uint256 slashPercent) external onlyDealManager returns (uint256 slashedTokens) {
        require(!closed, DACErrorsLib.DealIsClosed());

        slashedTokens = DealCellGovernanceLib.markAsFailed(
            slashPercent,
            id,
            dacCell,
            token,
            deal,
            holders
        );
    }

    function extendDeadline(uint256 newDeadline) external onlyDealManager {
        require(!closed, DACErrorsLib.DealIsClosed());
        
        deal.onExtendDeadline(_dealDeadline, newDeadline);

        _dealDeadline = newDeadline;
        
        emit DACEventsLib.DeadlineExtended(dacCell, id, address(deal), newDeadline);
    }

    function closeDeal() external {
        if (msg.sender != manager) {
            require(token.balanceOf(msg.sender) > 0, DACErrorsLib.NotAuthorized());

            // Normally should never happen as the deal is auto closed by manager
            // however for additional safety allowing agent to close the deal if
            // no more rewards are available
            require(rewardsConverted == MathLib.SCALE, DACErrorsLib.NotAllowed());
        }

        if (!closed) {
            deal.beforeClose();

            closed = true;
            
            emit DACEventsLib.DealClosed(dacCell, id, address(deal), token.totalSupply());

            IDealManagerAdapter(manager).onDealClosed(id);
        }
    }

    function recoverDeal(address liquidator, uint256 liquidatorStake) external onlyDealManager {
        require(closed, DACErrorsLib.DealIsNotClosed());
        require(liquidatorStake > 0, DACErrorsLib.NotAllowed());
        
        deal.beforeRecovery(liquidator, liquidatorStake);

        recovery = true;

        stake(liquidator, liquidatorStake);
        
        emit DACEventsLib.DealRecovered(dacCell, id, address(deal), liquidator);

        deal.afterRecovery(liquidator, liquidatorStake);
    }

    function claimMainToken(uint256 evaluatorId) external nonReentrant {
        DealCellGovernanceLib.claimMainToken(
            dacCell,
            deal,
            evaluatorId,
            claimableRewards
        );
    }

    function toggleWhitelist(bool whitelistOnly) internal {
        if (isWhitelistOnly != whitelistOnly) {
            isWhitelistOnly = whitelistOnly;

            emit DACEventsLib.WhitelistToggled(id, isWhitelistOnly);
            
            if (isWhitelistOnly) {
                DealCellGovernanceLib.whitelistHolders(holders);
            }
        }
    }

    function unstakeAllowed(address agent) internal {
        // if the deal is not approved adding stakes not allowed
        require(!recovery, DACErrorsLib.DealInLiquidation());

        require(token.balanceOf(agent) > 0, DACErrorsLib.NoStake());
        require(token.totalSupply() > token.balanceOf(agent), DACErrorsLib.NotAllowed());

        DealCellGovernanceLib.unstake(
            dacCell,
            id,
            deal,
            agent,
            agentTokenAddr,
            token
        );
    }

    function executeCellAgentProposal(DealManagementProposal prop) external onlyDeal returns (bool) {
        bytes4 typ = DealManagementProposal(prop).typ();

        if (typ == AbstractDealManagementType.REQUEST_TRANCHE) {
            DealCellGovernanceLib.requestTranche(
                dacCell,
                id,
                address(deal),
                prop,
                _fundingTranches,
                _fundingTokens,
                _requestedFunding
            );
        }

        else if (typ == AbstractDealManagementType.ADD_STAKE) {
            // if the deal is not approved adding stakes not allowed
            require(approved, DACErrorsLib.DealIsNotApproved());
            require(!recovery, DACErrorsLib.DealInLiquidation());

            DealCellGovernanceLib.addStake(
                dacCell,
                DealManagementProposal(prop).target(),
                uint256(DealManagementProposal(prop).i()),
                id,
                deal,
                agentTokenAddr,
                token,
                holders
            );
        }

        else if (typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS) {
            earlyReturns = abi.decode(DealManagementProposal(prop).data(), (bool));

            emit DACEventsLib.EarlyReturnsToggled(prop.id(), earlyReturns);
        }

        else if (typ == AbstractDealManagementType.TOGGLE_WHITELIST) {
            toggleWhitelist(
                abi.decode(DealManagementProposal(prop).data(), (bool))
            );
        }

        else if (typ == AbstractDealManagementType.ENABLE_VETO_RIGHT) {
            if (!vetoEnabled) {
                vetoEnabled = true;

                emit DACEventsLib.DealChallengeEnabled(id);
            }
        }

        else if (typ == AbstractDealManagementType.PERMIT_UNSTAKE) {
            unstakeAllowed(DealManagementProposal(prop).target());
        }

        else if (typ == AbstractDealManagementType.PERMIT_EVALUATOR_ADD) {
            IDealManagerAdapter(manager).permitEvaluatorAdd(id, DealManagementProposal(prop).data());
        }

        else {
            // Proposal not recognized by DealCell, will be forwarded to module

            return false;
        }
        
        // Proposal was executed

        return true;
    }

    function messageDeal(bytes4 messageKind, bytes calldata message) external onlyDealManager {
        require(
            deal.onMessageDeal(messageKind, message), 
            DACErrorsLib.MessageNotAccepted()
        );

        emit DACEventsLib.MessageReceived(messageKind, message);
    }

    function legalWrapperMessage(address legalWrapper, bytes4 messageKind, bytes calldata message) external onlyDealManager {
        deal.onLegalWrapperMessage(legalWrapper, messageKind, message);
        
        emit DACEventsLib.LegalWrapperMessageReceived(legalWrapper, messageKind, message);
    }

    function approveDeadline() external view returns (uint256) { return _approveDeadline; }
    function evaluationDeadline() external view returns (uint256) { return _evaluationDeadline; }
    function dealDeadline() external view returns (uint256) { return _dealDeadline; }

    function stakeToken() external view returns (address) { return address(token); }
    
    function getReturnedCapital(address _fundingToken) external view returns (uint256) { return returnedCapital[_fundingToken]; }
    function getInvestedCapital(address _fundingToken) external view returns (uint256) { return investedCapital[_fundingToken]; }
    function getMainRewardsLimit() external view returns (uint256) { return _tokenRewardsLimit; }
    function rewardsConvertedPct() external view returns (uint256) { return rewardsConverted; }
    
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external view returns (bool) { return approved; }
    function isClosed() external view returns (bool) { return closed; }

    function allowEarlyReturns() external view returns (bool) { return earlyReturns; }
    function allowDACVeto() external view returns (bool) { return vetoEnabled; }

    function fundingTokens() public view returns (address[] memory) {
        return _fundingTokens;
    }

    function fundingTranche(uint256 trancheId) public view returns (Tranche memory tranche) {
        tranche = _fundingTranches[trancheId];
        if (trancheId != 0) {
            require(tranche.amount > 0, DACErrorsLib.InvalidTranche());
        }
    }
    
    modifier onlyDealManager() {
        _onlyDealManager();
        _;
    }

    modifier onlyDeal() {
        _onlyDeal();
        _;
    }

    modifier onlyStakedMPHolder() {
        _onlyStakedMPHolder();
        _;
    }

    function _onlyDealManager() internal view {
        require(msg.sender == manager, DACErrorsLib.NotAuthorized());
    }

    function _onlyDeal() internal view {
        require(msg.sender == address(deal), DACErrorsLib.NotAuthorized());
    }

    function _onlyStakedMPHolder() internal view {
        require(token.balanceOf(msg.sender) > 0, DACErrorsLib.NoStake());
    }
}
