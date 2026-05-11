// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProposalParams, DealParams, VotingConfig, DACConfig, CapitalCall, Tranche} from "../../../interfaces/Structs.sol";
import {IVotes} from "../../../lib/IVotes.sol";
import {IVoting} from "../../../interfaces/IVoting.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {IDACFactory} from "../../../interfaces/IDACFactory.sol";
import {DealManagementProposal} from "../../../kernel/governance/DealManagementProposal.sol";
import {IDACCell} from "../../../interfaces/IDACCell.sol";
import {IDealCellAdapter} from "../../../kernel/interfaces/IDealCellAdapter.sol";
import {AbstractDealManagementType} from "../../../kernel/governance/AbstractDealManagementProposals.sol";
import {Deal} from "../../../kernel/Deal.sol";
import {DACDealConfig, SnapshotV1Payload} from "../interfaces/Structs.sol";
import {CoreDealManagementType} from "../governance/CoreDealManagementProposals.sol";
import {DACErrorsLib} from "../../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../../interfaces/DACEventsLib.sol";

contract DACDeal is Deal {
    using SafeERC20 for IERC20;

    struct DACCellDNA {
        address dacMainToken;
        address dacAgentToken;
    }

    // ERC-1271 magic value: bytes4(keccak256("isValidSignature(bytes32,bytes)"))
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant ERC1271_INVALID     = 0xffffffff;

    // Venue discriminator for snapshot.org single-choice Vote (Vote schema with uint32 choice).
    // Forks adding new venues should pick a distinct constant for routing.
    bytes32 public constant VENUE_SNAPSHOT_V1 = keccak256("snapshot-v1");

    // EIP-712 type hashes for snapshot. Domain only declares (name, version),
    // so neither chainId nor verifyingContract enter the separator.
    bytes32 internal constant SNAPSHOT_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version)");
    bytes32 internal constant SNAPSHOT_VOTE_TYPEHASH =
        keccak256("Vote(string from,string space,uint64 timestamp,string proposal,uint32 choice,string reason,string app,string metadata)");
    bytes32 internal constant SNAPSHOT_NAME_HASH = keccak256(bytes("snapshot"));

    uint256 private _allocation;
    uint256 private _rootCapitalCallId;

    DACCellDNA public dacCellDNA;

    // Allowlist of (venueId, version) pairs usable in EXTERNAL_VOTE_SIGN.
    mapping(bytes32 => mapping(string => bool)) public approvedVenueVersions;

    // Snapshot vote approvals keyed by reconstructed EIP-712 final hash.
    // Stored payload lets isValidSignature recompute and tamper-check on read.
    mapping(bytes32 => SnapshotV1Payload) internal approvedSnapshotVotes;

    // Events
    event ChildVoteCreated(uint256 indexed childProposalId, uint256 proposalId);
    event ChildVoteCasted(uint256 indexed childProposalId, bool support);
    event RootCapitalCallLinked(bytes32 indexed callHash, uint256 capitalCallId);

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

    function _beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override {
        require(params.fundingAmount > 0, DACErrorsLib.NoFunding());

        if (params.dealTarget == address(0)) {
            (DACDealConfig memory dacDeal) = abi.decode(params.dealConfig, (DACDealConfig));
            (address dacFactory, address deployer, bytes32 salt, DACConfig memory config) = abi.decode(dacDeal.config, (address, address, bytes32, DACConfig));

            require(config.founderAllocation == dacDeal.managedEquity, DACErrorsLib.ConfigMismatchParams());
            require(config.treasuryToken == params.fundingToken, DACErrorsLib.ConfigMismatchParams());
            require(config.founderCommitment == params.fundingAmount, DACErrorsLib.ConfigMismatchParams());

            config.founder = address(this);

            (address dacAddr, address mainTokenAddr, address agentTokenAddr) = IDACFactory(dacFactory).deployDAC(config, salt, deployer);

            managedEntity = dacAddr;
            dacCellDNA = DACCellDNA({
                dacMainToken: mainTokenAddr,
                dacAgentToken: agentTokenAddr
            });

            _registerRelatedContract(managedEntity, bytes32("CHILD_DAC"), false, true);
            _registerRelatedContract(dacCellDNA.dacMainToken, bytes32("CHILD_MAIN_TOKEN"), false, false);
            _registerRelatedContract(dacCellDNA.dacAgentToken, bytes32("CHILD_AGENT_TOKEN"), false, false);
            
            _allocation = config.founderAllocation;
        }
    }

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override {
        (DACDealConfig memory dacDeal) = abi.decode(params.dealConfig, (DACDealConfig));

        if (params.dealTarget != address(0)) {
            managedEntity = params.dealTarget;

            dacCellDNA = DACCellDNA({
                dacMainToken: IDACCell(params.dealTarget).getMainToken(),
                dacAgentToken: IDACCell(params.dealTarget).getAgentToken()
            });

            _registerRelatedContract(managedEntity, bytes32("CHILD_DAC"), false, true);
            _registerRelatedContract(dacCellDNA.dacMainToken, bytes32("CHILD_MAIN_TOKEN"), false, false);
            _registerRelatedContract(dacCellDNA.dacAgentToken, bytes32("CHILD_AGENT_TOKEN"), false, false);

            _allocation = dacDeal.managedEquity;
        }
    }

    function _afterApprove(uint256 trancheId) internal override {
        // Approving spend towards DAC, so child can fulfill capital call
        // We always approve the last tranche amount, as we immediately sending the funds out

        address token = IDealCell(dealCell).fundingTranche(trancheId).token;
        uint256 amount = IDealCell(dealCell).fundingTranche(trancheId).amount;

        IERC20(token).forceApprove(IDACCell(managedEntity).getAssetController(), amount);

        if (trancheId == 0) {
            CapitalCall memory call = CapitalCall({
                treasuryToken: token,
                nonce: _rootCapitalCallId,
                tokenRecipient: address(this),
                tokenAmount: _allocation,
                cashAmount: amount
            });

            IDACCell(managedEntity).fulfillCapitalCall(call);
        }

        else {
            address prop = getProposal(trancheId);

            (, bytes32 calldataHash) = abi.decode(
                DealManagementProposal(prop).data(), 
                (uint256, bytes32)
            );

            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(calldataHash);
            IDACCell(managedEntity).fulfillCapitalCall(call);

            _allocation += call.tokenAmount;
        }

        IVotes(IDACCell(managedEntity).getMainToken()).delegate(address(this));
    }

    function _afterClaimMainToken(address grantee, uint256 amount) internal override {
        if (grantee != address(this) || amount == 0) {
            return;
        }

        IERC20(mainTokenAddr).safeTransfer(managedEntity, amount);
        IDACCell(managedEntity).recoverERC20(mainTokenAddr);
    }

    function claimDealRewardPool(uint256 evaluatorId) external onlyStakedAgent nonReentrant {
        IDealCell(dealCell).claimMainToken(evaluatorId);
    }

    function setRootCapitalCallID(uint256 capitalCallId) external onlyStakedAgent {
        require(!IDealCell(dealCell).isApproved(), DACErrorsLib.DealAlreadyApproved());

        Tranche memory tranche = IDealCell(dealCell).fundingTranche(0);

        CapitalCall memory call = CapitalCall({
            treasuryToken: tranche.token,
            nonce: capitalCallId,
            tokenRecipient: address(this),
            tokenAmount: _allocation,
            cashAmount: tranche.amount
        });

        bytes32 callHash = keccak256(abi.encode(call));
        IDACCell(managedEntity).getCapitalCall(callHash);

        _rootCapitalCallId = capitalCallId;

        emit RootCapitalCallLinked(callHash, capitalCallId);
    }

    function _beforeClose() internal override {
        // On close we transfer child Main token to our DAC
        // Now this equity is chickens' problem, they can distribute
        // these equity tokens as dividends, or establish a new Deal
        // with new management

        address token = IDACCell(managedEntity).getMainToken();
        uint256 balance = IERC20(token).balanceOf(address(this));

        IERC20(token).forceApprove(dealCell, balance);

        IDealCellAdapter(dealCell).transferCapital(token, balance);
    }

    function _checkStackedAgentProposalSupported(ProposalParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == CoreDealManagementType.REINVEST_PROFITS ||
            params.typ == CoreDealManagementType.CREATE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.VOTE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.RETURN_PROFITS ||
            params.typ == CoreDealManagementType.APPROVE_VOTING_VENUE_VERSION ||
            params.typ == CoreDealManagementType.EXTERNAL_VOTE_SIGN
        );
    }

    function _beforeCreateProposal(ProposalParams calldata params) internal virtual override {
        if (params.typ == AbstractDealManagementType.REQUEST_TRANCHE) {
            // Checking that capital call exists
            (, bytes32 calldataHash) = abi.decode(params.data, (uint256, bytes32));
            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(calldataHash);

            // Verifying capital call parameters
            require(call.treasuryToken == params.target);
            require(call.cashAmount == uint256(params.i));
            require(call.tokenRecipient == address(this));
        }

        else if (params.typ == CoreDealManagementType.REINVEST_PROFITS) {
            // Checking a reinvest profit proposal
            address token = params.target;
            (uint256 fundingAmount, bytes32 capitalCallHash) = abi.decode(params.data, (uint256, bytes32));

            // If token is our funding token
            if (IDealCell(dealCell).getInvestedCapital(token) > 0) {
                // With early returns, all capital in any of funding tokens is siphoned back
                // to chickens by any manager will, and automatically counts into returns
                // so we make reinvest not possible
                require(!IDealCell(dealCell).allowEarlyReturns(), DACErrorsLib.NotAllowed());
            }
            else {
                address mainTokenAddress = IDACCell(managedEntity).getMainToken();
                require(token != mainTokenAddress);
            }
            
            require(
                IERC20(token).balanceOf(address(this)) >= fundingAmount,
                DACErrorsLib.NotEnoughBalance()
            );

            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(capitalCallHash);

            require(call.treasuryToken == token);
            require(call.cashAmount == fundingAmount);
            require(call.tokenRecipient == address(this));
        }
    }

    function _executeModuleManagementProposal(DealManagementProposal proposal) internal virtual override {
        bytes4 typ = proposal.typ();

        if (typ == CoreDealManagementType.CREATE_DAC_PROPOSAL) {
            (ProposalParams memory childProposal) = abi.decode(
                proposal.data(), 
                (ProposalParams)
            );

            uint256 childProposalId = IDACCell(managedEntity).createManagementProposal(childProposal);

            ProposalParams memory dealProposalParams = ProposalParams({
                typ: CoreDealManagementType.VOTE_DAC_PROPOSAL,
                target: address(0),
                i: bytes32(childProposalId),
                data: abi.encode(true)
            });

            uint256 proposalId = this.createStakedAgentProposal(dealProposalParams);

            emit ChildVoteCreated(childProposalId, proposalId);
        }

        else if (typ == CoreDealManagementType.VOTE_DAC_PROPOSAL) {
            uint256 childProposalId = uint256(proposal.i());
            (bool support) = abi.decode(
                proposal.data(), 
                (bool)
            );

            address childVoting = IDACCell(managedEntity).getProposalVoting(childProposalId);
            IVoting(childVoting).vote(support);

            emit ChildVoteCasted(childProposalId, support);
        }
        
        else if (typ == CoreDealManagementType.REINVEST_PROFITS) {
            address token = proposal.target();
            (uint256 amount, bytes32 callHash) = abi.decode(proposal.data(), (uint256, bytes32));

            IERC20(token).forceApprove(IDACCell(managedEntity).getAssetController(), amount);

            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(callHash);
            IDACCell(managedEntity).fulfillCapitalCall(call);

            _allocation += call.tokenAmount;
        }

        else if (typ == CoreDealManagementType.RETURN_PROFITS) {
            address token = proposal.target();
            (uint256 amount) = abi.decode(proposal.data(), (uint256));

            require(token != IDACCell(managedEntity).getMainToken(), DACErrorsLib.NotAllowed());

            IERC20(token).forceApprove(dealCell, amount);
            IDealCellAdapter(dealCell).transferCapital(token, amount);
        }

        else if (typ == CoreDealManagementType.APPROVE_VOTING_VENUE_VERSION) {
            (bytes32 venueId, string memory version, bool allowed) = abi.decode(
                proposal.data(),
                (bytes32, string, bool)
            );
            require(venueId != bytes32(0), DACErrorsLib.NotAllowed());
            require(bytes(version).length > 0, DACErrorsLib.NotAllowed());

            approvedVenueVersions[venueId][version] = allowed;
            emit DACEventsLib.VenueVersionApproved(venueId, version, allowed);
        }

        else if (typ == CoreDealManagementType.EXTERNAL_VOTE_SIGN) {
            (bytes32 venueId, bytes memory payload) = abi.decode(proposal.data(), (bytes32, bytes));

            if (venueId == VENUE_SNAPSHOT_V1) {
                _executeSnapshotV1VoteSign(payload);
            } else {
                _executeExternalVoteSignExtension(venueId, payload);
            }
        }

        else {
            revert DACErrorsLib.UnsupportedProposal();
        }
    }

    function _executeSnapshotV1VoteSign(bytes memory payload) internal {
        SnapshotV1Payload memory v = abi.decode(payload, (SnapshotV1Payload));

        require(approvedVenueVersions[VENUE_SNAPSHOT_V1][v.version], DACErrorsLib.NotAllowed());
        require(v.expiry > block.timestamp, DACErrorsLib.NotAllowed());

        bytes32 finalHash = _computeSnapshotV1FinalHash(v);
        approvedSnapshotVotes[finalHash] = v;

        emit DACEventsLib.ExternalVoteApproved(VENUE_SNAPSHOT_V1, finalHash, v.expiry);
    }

    // Reconstructs snapshot.org's EIP-712 final hash from the structured payload.
    // Pure: every input comes from `v`. Strings used verbatim — proposer-supplied
    // `from` must equal what snapshot's backend will compute (lowercase hex of
    // address(this) by snapshot convention) or the hash will mismatch on read.
    function _computeSnapshotV1FinalHash(SnapshotV1Payload memory v) internal pure returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(
            SNAPSHOT_DOMAIN_TYPEHASH,
            SNAPSHOT_NAME_HASH,
            keccak256(bytes(v.version))
        ));
        bytes32 structHash = keccak256(abi.encode(
            SNAPSHOT_VOTE_TYPEHASH,
            keccak256(bytes(v.from)),
            keccak256(bytes(v.space)),
            v.timestamp,
            keccak256(bytes(v.proposal)),
            v.choice,
            keccak256(bytes(v.reason)),
            keccak256(bytes(v.app)),
            keccak256(bytes(v.metadata))
        ));
        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, structHash));
    }

    // ERC-1271. Forks add new venues by overriding _isValidSignatureExtension —
    // returning the magic value only for hashes they themselves approved.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        if (_isApprovedSnapshotV1Vote(hash)) return ERC1271_MAGIC_VALUE;
        return _isValidSignatureExtension(hash);
    }

    function _isApprovedSnapshotV1Vote(bytes32 hash) internal view returns (bool) {
        SnapshotV1Payload memory v = approvedSnapshotVotes[hash];
        if (v.timestamp == 0) return false;
        if (block.timestamp > v.expiry) return false;
        // Tamper check: storage entry must hash back to the queried hash.
        // Defense in depth — closes any future storage-collision class of bugs.
        if (_computeSnapshotV1FinalHash(v) != hash) return false;
        return true;
    }

    // Fork hooks. Override to dispatch additional venues without touching core paths.
    function _executeExternalVoteSignExtension(bytes32, bytes memory) internal virtual {
        revert DACErrorsLib.UnsupportedProposal();
    }

    function _isValidSignatureExtension(bytes32) internal view virtual returns (bytes4) {
        return ERC1271_INVALID;
    }

    function _beforeWithdrawCapital() internal override {
        // DAC deal always transfer capital in all funding tokens back to parent DAC
        // following the core return logic and `earlyReturns` configuration

        // If early returns logic is not turned-on, DAC deal can reinvest
        // profits in the funding token into a child DAC
    }
}
