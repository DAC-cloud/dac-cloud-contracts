// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OracleSnapshot} from "../../interfaces/GovernanceStructs.sol";
import {IGovernanceOracle} from "../../interfaces/IGovernanceOracle.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

contract GovernanceOracle is IGovernanceOracle, Initializable, AccessControlUpgradeable {
    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    mapping(uint256 => OracleSnapshot) private snapshots;
    bool private active;

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address initialPublisher) external initializer {
        require(admin != address(0), DACErrorsLib.NotAllowed());

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        active = true;

        if (initialPublisher != address(0)) {
            _grantRole(PUBLISHER_ROLE, initialPublisher);
            emit DACEventsLib.GovernanceOraclePublisherUpdated(address(this), initialPublisher, true);
        }
    }

    function setPublisher(address publisher, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(publisher != address(0), DACErrorsLib.NotAllowed());

        if (allowed) {
            _grantRole(PUBLISHER_ROLE, publisher);
        } else {
            _revokeRole(PUBLISHER_ROLE, publisher);
        }

        emit DACEventsLib.GovernanceOraclePublisherUpdated(address(this), publisher, allowed);
    }

    function isPublisher(address publisher) external view returns (bool) {
        return hasRole(PUBLISHER_ROLE, publisher);
    }

    function isActive() external view returns (bool) {
        return active;
    }

    function deactivate() external {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(PUBLISHER_ROLE, msg.sender),
            DACErrorsLib.NotAuthorized()
        );
        require(active, DACErrorsLib.NotAllowed());

        active = false;
        emit DACEventsLib.GovernanceOracleDeactivated(address(this), msg.sender);
    }

    function publishSnapshot(
        uint256 proposalId,
        uint256 snapshotBlock,
        bytes32 merkleRoot,
        uint256 totalUnderlyingVotingPower
    ) external onlyRole(PUBLISHER_ROLE) {
        require(active, DACErrorsLib.NotAllowed());
        require(proposalId > 0, DACErrorsLib.NotAllowed());
        require(snapshotBlock > 0, DACErrorsLib.NotAllowed());
        require(merkleRoot != bytes32(0), DACErrorsLib.InvalidMerkleProof());
        require(snapshots[proposalId].merkleRoot == bytes32(0), DACErrorsLib.AlreadyInitialized());

        snapshots[proposalId] = OracleSnapshot({
            snapshotBlock: snapshotBlock,
            merkleRoot: merkleRoot,
            totalUnderlyingVotingPower: totalUnderlyingVotingPower,
            publishedAt: block.timestamp
        });

        emit DACEventsLib.OracleSnapshotPublished(
            proposalId,
            snapshotBlock,
            merkleRoot,
            totalUnderlyingVotingPower
        );
    }

    function getSnapshot(uint256 proposalId) external view returns (OracleSnapshot memory snapshot) {
        snapshot = snapshots[proposalId];
    }
}
