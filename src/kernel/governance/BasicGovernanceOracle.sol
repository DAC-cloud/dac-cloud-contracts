// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OracleSnapshot} from "../../interfaces/GovernanceStructs.sol";
import {IBasicGovernanceOracle} from "../../interfaces/IBasicGovernanceOracle.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

contract BasicGovernanceOracle is IBasicGovernanceOracle, Initializable, AccessControlUpgradeable {
    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    // Snapshots namespaced per DAC so a single instance can serve many DACs
    // without proposalId collisions.
    mapping(address => mapping(uint256 => OracleSnapshot)) private snapshots;

    // Per-DAC kill-switch. Default false = active. Once flipped, that DAC
    // falls back to on-chain voting; flipping a single DAC must not affect
    // others sharing this oracle.
    mapping(address => bool) private deactivated;

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address initialPublisher) external initializer {
        require(admin != address(0), DACErrorsLib.NotAllowed());

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

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

    function isActive(address dac) external view returns (bool) {
        return !deactivated[dac];
    }

    function deactivate(address dac) external {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(PUBLISHER_ROLE, msg.sender),
            DACErrorsLib.NotAuthorized()
        );
        require(dac != address(0), DACErrorsLib.NotAllowed());
        require(!deactivated[dac], DACErrorsLib.NotAllowed());

        deactivated[dac] = true;
        emit DACEventsLib.GovernanceOracleDeactivated(address(this), dac, msg.sender);
    }

    function publishSnapshot(
        address dac,
        uint256 proposalId,
        uint256 snapshotBlock,
        bytes32 merkleRoot,
        uint256 totalUnderlyingVotingPower
    ) external onlyRole(PUBLISHER_ROLE) {
        require(dac != address(0), DACErrorsLib.NotAllowed());
        require(!deactivated[dac], DACErrorsLib.NotAllowed());
        require(proposalId > 0, DACErrorsLib.NotAllowed());
        require(snapshotBlock > 0, DACErrorsLib.NotAllowed());
        require(merkleRoot != bytes32(0), DACErrorsLib.InvalidMerkleProof());
        require(snapshots[dac][proposalId].merkleRoot == bytes32(0), DACErrorsLib.AlreadyInitialized());

        snapshots[dac][proposalId] = OracleSnapshot({
            snapshotBlock: snapshotBlock,
            merkleRoot: merkleRoot,
            totalUnderlyingVotingPower: totalUnderlyingVotingPower,
            publishedAt: block.timestamp
        });

        emit DACEventsLib.OracleSnapshotPublished(
            dac,
            proposalId,
            snapshotBlock,
            merkleRoot,
            totalUnderlyingVotingPower
        );
    }

    function getSnapshot(address dac, uint256 proposalId)
        external
        view
        returns (OracleSnapshot memory snapshot)
    {
        snapshot = snapshots[dac][proposalId];
    }
}
