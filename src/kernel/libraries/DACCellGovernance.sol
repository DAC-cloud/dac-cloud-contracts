// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "../../interfaces/Structs.sol";
import "../../interfaces/IDealAdmin.sol";
import "../../interfaces/IEvaluator.sol";
import "../../interfaces/IDACManagementFactory.sol";
import "../../interfaces/IModuleFactory.sol";
import "../interfaces/IDealManager.sol";
import "../interfaces/Structs.sol";
import "../tokens/MainToken.sol";
import "../tokens/AgentToken.sol";
import "../governance/DACManagementProposal.sol";
import "../governance/DACManagementProposals.sol";

interface IDACGovernanceAdapter {
    function createManagementProposal(ProposalParams calldata params)
        external
        returns (uint256 id);
}

library DACCellGovernance {
    // Errors

    error NotFound();
    error NotAuthorized();

    error InsufficientBalance();

    error InvalidDeal(address deal);
    error InvalidDealId(uint256 deal);
    
    error InvalidTranche();
    error InsufficientTreasury();
    error InsufficientRewards();

    error InvalidCapitalCall();
    error AlreadyFulfilled();

    error DividendsNotEnabled();
    error DividendAlreadyClaimed(uint256 id, address claimer);
    error InvalidMerkleProof();
    error TransferFailed();

    error DealNotRecoverable();

    error ModuleNotApproved();
    error ModuleDisabled();

    // Events
    event CapitalCallCreated(uint256 indexed id, address indexed recipient, bytes32 callHash, uint256 amount);
    event CapitalCallFulfilled(address indexed recipient, bytes32 callHash, uint256 amount);
    
    event DACProposalCreated(uint256 indexed id, bytes4 indexed typ, address target, bytes32 data1, bytes data2);

    event DividendClaimed(uint256 payoutId, address indexed token, uint256 amountPayout);
    
    event DealCreated(uint256 indexed id, uint256 indexed proposalId, address indexed creator, bytes4 kind, address deal);
    event TrancheCreated(uint256 indexed id, uint256 indexed proposalId, uint256 trancheId);
    event FundingApproved(uint256 indexed id, uint256 indexed trancheId, uint256 rewardsLimit);
    
    event DealEvaluated(uint256 indexed id, bool success);

    // Methods implementation

    function fulfillCapitalCall(
        CapitalCall calldata call,
        MainToken mainToken,
        mapping(bytes32 => CapitalCallState) storage capitalCalls,
        mapping(address => uint256) storage treasuryBalances
    ) internal returns (bool) {
        bytes32 callHash = keccak256(abi.encode(call));
        require(!capitalCalls[callHash].fulfilled, AlreadyFulfilled());
        
        CapitalCall memory capitalCall = capitalCalls[callHash].call;
        require(capitalCall.tokenAmount > 0, InvalidCapitalCall());

        require(
            IERC20(call.treasuryToken).transferFrom(msg.sender, address(this), call.cashAmount), 
            TransferFailed()
        );

        treasuryBalances[call.treasuryToken] += call.cashAmount;

        mainToken.mint(call.tokenRecipient, call.tokenAmount);

        capitalCalls[callHash].fulfilled = true;

        emit CapitalCallFulfilled(call.tokenRecipient, callHash, call.tokenAmount);
        
        return true;
    }

    function createDealProposal(
        address dacCell,
        uint256 nextId,
        DealParams calldata params,
        MainToken mainToken,
        AgentToken agentToken,
        VotingConfig memory votingConfig,
        mapping(address => bool) storage moduleFactories,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealRegistry
    ) internal returns (uint256 id, address dealAddr, address evaluatorAddr) {
        require(moduleFactories[params.moduleFactory], ModuleNotApproved());

        require(params.proposer == msg.sender, NotAuthorized());

        require(IModuleFactory(params.moduleFactory).isActive(), ModuleDisabled());

        id = nextId + 1; // proposal id = nextId, deal id = proposal id + 1

        (dealAddr, evaluatorAddr) = IModuleFactory(params.moduleFactory).deployDeal(
            id,
            params,
            address(this),
            address(agentToken),
            address(mainToken),
            votingConfig
        );

        deals[id] = dealAddr;
        dealRegistry[dealAddr] = DealState({
            module: IModuleFactory(params.moduleFactory),
            evaluator: evaluatorAddr,
            rewardsLimit: 0
        });
        
        ProposalParams memory dealProposal = ProposalParams({
            typ: DACManagementProposalType.APPROVE_DEAL,
            target: params.fundingToken,
            i: bytes32(params.fundingAmount),
            data: abi.encode(id, 0, params.rewardsLimit) // tranche id 0, rewards limit from config
        });

        emit DealCreated(
            id, 
            IDACGovernanceAdapter(dacCell).createManagementProposal(dealProposal), 
            msg.sender, 
            params.dealKind, 
            dealAddr
        );
    }

    function createTrancheProposal(
        address dacCell,
        uint256 dealId,
        uint256 trancheId,
        mapping(uint256 => address) storage deals
    ) internal {
        address deal = deals[dealId];
        require(msg.sender == deal, InvalidDealId(dealId));

        address fundingToken = IDealCore(deal).fundingToken(trancheId);
        uint256 fundingAmount = IDealCore(deal).fundingAmount(trancheId);
        require(fundingAmount > 0, InvalidTranche());

        ProposalParams memory trancheProposal = ProposalParams({
            typ: DACManagementProposalType.APPROVE_TRANCHE,
            target: fundingToken,
            i: bytes32(fundingAmount),
            data: abi.encode(dealId, trancheId, uint256(0))
        });

        uint256 votingId = IDACGovernanceAdapter(dacCell).createManagementProposal(trancheProposal);

        emit TrancheCreated(dealId, trancheId, votingId);
    }

    function executeTrancheApprove(
        uint256 dealId,
        uint256 trancheId,
        uint256 rewardsLimit,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealState
    ) internal {
        address deal = deals[dealId];

        uint256 amount = IDealCore(deal).fundingAmount(trancheId);
        address token = IDealCore(deal).fundingToken(trancheId);

        require(IERC20(token).transfer(deal, amount), TransferFailed());
        if (trancheId == 0) {
            dealState[deal].rewardsLimit = rewardsLimit;
        }

        IDealAdmin(deal).onApproved(trancheId);
        
        emit FundingApproved(dealId, trancheId, rewardsLimit);
    }

    function approveFunding(
        DACManagementProposal prop,
        mapping(address => uint256) storage treasuryBalances,
        IDealManager dealManager
    ) internal {
        (uint256 dealId, uint256 trancheId, uint256 rewardsLimit) = abi.decode(
            prop.data(),
            (uint256, uint256, uint256)
        );

        address deal = dealManager.deals(dealId);
        require(deal != address(0), InvalidDealId(dealId));

        uint256 amount = IDealCore(deal).fundingAmount(trancheId);
        address token = IDealCore(deal).fundingToken(trancheId);

        require(treasuryBalances[token] >= amount, InsufficientTreasury());

        if (amount > 0) {
            require(IERC20(token).approve(address(dealManager), type(uint256).max), TransferFailed());
            treasuryBalances[token] -= amount;
        }
        else {
            require(trancheId == 0, InvalidTranche());
        }

        dealManager.approveFunding(dealId, trancheId, rewardsLimit);
    }

    function createManagementProposal(
        uint256 nextId,
        ProposalParams calldata params,
        VotingConfig storage votingConfig,
        address proposalFactory,
        MainToken mainToken,
        bool dividendsEnabled,
        uint256 unreleasedMainTokens,
        IDealManager dealManager,
        mapping(uint256 => address) storage proposals
    ) internal returns (uint256 id) {
        if (msg.sender == address(this)) {
            require(
                (
                    params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE
                ),
                NotAuthorized()
            );
        }
        else {
            require(
                !(
                    params.typ == DACManagementProposalType.APPROVE_DEAL ||
                    params.typ == DACManagementProposalType.APPROVE_TRANCHE
                ),
                NotAuthorized()
            );

            require(
                mainToken.balanceOf(msg.sender) > votingConfig.qualification,
                InsufficientBalance()
            );

            if (params.typ == DACManagementProposalType.RECOVER_DEAL) {
                (uint256 dealId) = abi.decode(params.data, (uint256));

                require(dealManager.isRecoverable(dealId), DealNotRecoverable());
            }

            if (params.typ == DACManagementProposalType.DIVIDEND_PAYOUT) {
                require(dividendsEnabled, DividendsNotEnabled());
            }
        }

        id = nextId;

        address prop = IDACManagementFactory(proposalFactory).deployProposal(
            id,
            params,
            address(this),
            address(mainToken),
            unreleasedMainTokens,
            votingConfig
        );

        proposals[id] = prop;

        emit DACProposalCreated(id, params.typ, params.target, params.i, params.data);

        return id;
    }

    function mintMain(
        address deal, 
        address to, 
        uint256 amount,
        MainToken mainToken,
        mapping(address => DealState) storage dealState
    ) internal {
        require(msg.sender == deal, InvalidDeal(msg.sender));
        require(dealState[deal].rewardsLimit > amount, InsufficientRewards());

        //todo permit mint on evaluator

        // Here we enforce a cup on mint per deal, so rewards are capped by what was agreed 
        // by LP holders, even when both the deal and evaluator are compromised

        dealState[deal].rewardsLimit -= amount;

        mainToken.mint(to, amount);
    }

    function executeCapitalCall(
        uint256 id,
        DACManagementProposal prop,
        mapping(bytes32 => CapitalCallState) storage capitalCalls
    ) internal {
        (address treasuryToken, uint256 cashAmount) = abi.decode(
            prop.data(), 
            (address, uint256)
        );

        CapitalCall memory call = CapitalCall({
            treasuryToken: treasuryToken,
            nonce: id,
            tokenRecipient: prop.target(),
            tokenAmount: uint256(prop.i()),
            cashAmount: cashAmount
        });

        bytes32 hash = keccak256(abi.encode(call));
        capitalCalls[hash] = CapitalCallState({
            call: call,
            fulfilled: false
        });

        emit CapitalCallCreated(id, prop.target(), hash, uint256(prop.i()));
    }

    function _performTransformation(
        uint256 id, 
        uint256 transformationPercent,
        mapping(uint256 => address) storage deals
    ) internal {
        address deal = deals[id];
        IDealAdmin(deal).markAsSuccess(transformationPercent);
    }

    function _performSlash(
        uint256 id, 
        uint256 slashPercent,
        AgentToken agentToken,
        mapping(uint256 => address) storage deals
    ) internal {
        address deal = deals[id];
        uint256 totalTokens = IDealCore(deal).getStakedAgentTotal();
        AgentToken(agentToken).burnFrom(deal, totalTokens);
        IDealAdmin(deal).markAsFailed(slashPercent);
    }

    function evaluateDeal(
        uint256 id,
        AgentToken agentToken,
        mapping(uint256 => address) storage deals,
        mapping(address => DealState) storage dealState
    ) external {
        address deal = deals[id];
        require(deal != address(0), InvalidDeal(deal));

        address evaluatorAddr = dealState[deal].evaluator;
        EvaluationResult memory result = IEvaluator(evaluatorAddr).evaluateDeal(id, deal, address(this));

        if (result.action == 0) {           // slash
            _performSlash(id, result.percent, agentToken, deals);
        } else if (result.action == 1) {    // convert
            _performTransformation(id, result.percent, deals);
        } else if (result.action == 2) {    // extend
            IDealAdmin(deal).extendDeadline(result.newDeadline);
        } else if (result.action == 3) {    // close
            IDealAdmin(deal).closeDeal();
        }

        if (result.action == 1 || result.action == 0) {
            emit DealEvaluated(id, result.action == 1);
        }
    }

    function claimDividend(
        uint256 proposalId,
        uint256 index,
        uint256 amount,
        bytes32[] calldata proof,
        mapping(uint256 => address) storage proposals,
        mapping(uint256 => bytes32) storage dividendMerkleRoots,
        mapping(bytes32 => bool) storage dividendClaimed
    ) external {
        bytes32 root = dividendMerkleRoots[proposalId];
        require(root != bytes32(0), NotFound());

        bytes32 leaf = keccak256(abi.encodePacked(index, msg.sender, amount));

        bytes32 claimedKey = keccak256(abi.encodePacked(root, leaf));
        require(!dividendClaimed[claimedKey], DividendAlreadyClaimed(proposalId, msg.sender));

        require(MerkleProof.verify(proof, root, leaf), InvalidMerkleProof());

        dividendClaimed[claimedKey] = true;

        address prop = proposals[proposalId];

        (address token) = abi.decode(DACManagementProposal(prop).data(), (address));
        require(IERC20(token).transfer(msg.sender, amount), TransferFailed());

        emit DividendClaimed(proposalId, msg.sender, amount);
    }
}
