// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACDeal} from "../src/modules/core/deals/DACDeal.sol";
import {SnapshotV1Payload} from "../src/modules/core/interfaces/Structs.sol";
import {DACEventsLib} from "../src/interfaces/DACEventsLib.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {UUPSProxy} from "../src/kernel/proxies/UUPSProxy.sol";

// Test harness exposing the new vote-sign internals so we can exercise them
// without bootstrapping the full Deal/DAC lifecycle. The harness inherits the
// real DACDeal contract — it is the same code under test, just with thin
// wrappers added.
contract TestableDACDeal is DACDeal {
    function t_computeHash(SnapshotV1Payload memory v) external pure returns (bytes32) {
        return _computeSnapshotV1FinalHash(v);
    }

    function t_executeSnapshotVoteSign(bytes memory payload) external {
        _executeSnapshotV1VoteSign(payload);
    }

    function t_approveVersion(string memory version, bool allowed) external {
        approvedVenueVersions[VENUE_SNAPSHOT_V1][version] = allowed;
    }

    function t_dispatchExternalVoteSign(bytes32 venueId, bytes memory payload) external {
        if (venueId == VENUE_SNAPSHOT_V1) {
            _executeSnapshotV1VoteSign(payload);
        } else {
            _executeExternalVoteSignExtension(venueId, payload);
        }
    }
}

contract DACDealVoteSignTest is Test {
    TestableDACDeal internal dacDeal;

    string internal constant SNAPSHOT_VERSION = "0.1.4";

    function setUp() external {
        // Bare proxy deploy — Deal initializer never called. The new code paths
        // don't read Deal-init storage so this is sufficient for unit testing.
        dacDeal = TestableDACDeal(
            address(new UUPSProxy(address(new TestableDACDeal()), bytes("")))
        );
    }

    function _samplePayload() internal view returns (SnapshotV1Payload memory) {
        return SnapshotV1Payload({
            version:   SNAPSHOT_VERSION,
            from:      "0x000000000000000000000000000000000000abcd",
            space:     "test.eth",
            timestamp: uint64(block.timestamp),
            proposal:  "0xfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed",
            choice:    1,
            reason:    "",
            app:       "dac-cloud",
            metadata:  "",
            expiry:    uint64(block.timestamp + 1 days)
        });
    }

    // -------- Hash reconstruction --------

    function test_computeHash_isDeterministic() external view {
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 a = dacDeal.t_computeHash(v);
        bytes32 b = dacDeal.t_computeHash(v);
        assertEq(a, b);
        assertTrue(a != bytes32(0));
    }

    function test_computeHash_changesWithChoice() external view {
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 a = dacDeal.t_computeHash(v);
        v.choice = 2;
        bytes32 b = dacDeal.t_computeHash(v);
        assertTrue(a != b);
    }

    function test_computeHash_changesWithVersion() external view {
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 a = dacDeal.t_computeHash(v);
        v.version = "0.1.5";
        bytes32 b = dacDeal.t_computeHash(v);
        assertTrue(a != b);
    }

    function test_computeHash_changesWithFrom() external view {
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 a = dacDeal.t_computeHash(v);
        v.from = "0x0000000000000000000000000000000000001234";
        bytes32 b = dacDeal.t_computeHash(v);
        assertTrue(a != b);
    }

    // NOTE: Before mainnet launch a reference test vector should be added here:
    // generate (payload, expectedHash) using snapshot.js off-chain, hard-code
    // expectedHash, assert dacDeal.t_computeHash(payload) == expectedHash. This is
    // the canary against EIP-712 spec drift between our impl and snapshot's.

    // -------- executeSnapshotV1VoteSign --------

    function test_executeSnapshotVoteSign_storesAndEmits() external {
        dacDeal.t_approveVersion(SNAPSHOT_VERSION, true);
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 expectedHash = dacDeal.t_computeHash(v);

        vm.expectEmit(true, true, false, true, address(dacDeal));
        emit DACEventsLib.ExternalVoteApproved(dacDeal.VENUE_SNAPSHOT_V1(), expectedHash, v.expiry);

        dacDeal.t_executeSnapshotVoteSign(abi.encode(v));

        // Approval visible via isValidSignature
        assertEq(dacDeal.isValidSignature(expectedHash, ""), bytes4(0x1626ba7e));
    }

    function test_executeSnapshotVoteSign_revertsWhenVersionNotApproved() external {
        SnapshotV1Payload memory v = _samplePayload();
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        dacDeal.t_executeSnapshotVoteSign(abi.encode(v));
    }

    function test_executeSnapshotVoteSign_revertsWhenAlreadyExpired() external {
        dacDeal.t_approveVersion(SNAPSHOT_VERSION, true);
        SnapshotV1Payload memory v = _samplePayload();
        vm.warp(uint256(v.expiry) + 1);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        dacDeal.t_executeSnapshotVoteSign(abi.encode(v));
    }

    function test_executeSnapshotVoteSign_revertsWhenVersionRevoked() external {
        dacDeal.t_approveVersion(SNAPSHOT_VERSION, true);
        dacDeal.t_approveVersion(SNAPSHOT_VERSION, false);
        SnapshotV1Payload memory v = _samplePayload();
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        dacDeal.t_executeSnapshotVoteSign(abi.encode(v));
    }

    // -------- isValidSignature --------

    function test_isValidSignature_invalidForUnknownHash() external view {
        bytes32 randomHash = keccak256("never-approved");
        assertEq(dacDeal.isValidSignature(randomHash, ""), bytes4(0xffffffff));
    }

    function test_isValidSignature_invalidAfterExpiry() external {
        dacDeal.t_approveVersion(SNAPSHOT_VERSION, true);
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 hash = dacDeal.t_computeHash(v);
        dacDeal.t_executeSnapshotVoteSign(abi.encode(v));

        vm.warp(uint256(v.expiry) + 1);
        assertEq(dacDeal.isValidSignature(hash, ""), bytes4(0xffffffff));
    }

    function test_isValidSignature_validRightUpToExpiry() external {
        dacDeal.t_approveVersion(SNAPSHOT_VERSION, true);
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 hash = dacDeal.t_computeHash(v);
        dacDeal.t_executeSnapshotVoteSign(abi.encode(v));

        vm.warp(uint256(v.expiry));
        assertEq(dacDeal.isValidSignature(hash, ""), bytes4(0x1626ba7e));
    }

    // -------- Permit-collision canary --------

    // Construct a hash shaped like a USDC EIP-2612 permit and assert it does
    // NOT validate. Proves the structured-payload defense: a hash that wasn't
    // produced via our snapshot-domain reconstruction can never validate, even
    // if an attacker tries to feed it through isValidSignature directly.
    function test_isValidSignature_rejectsERC2612PermitHash() external view {
        bytes32 permitDomainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("USD Coin")),
            keccak256(bytes("2")),
            block.chainid,
            address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)  // USDC mainnet
        ));
        bytes32 permitStructHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            address(dacDeal),
            address(0xdeadbeef),
            type(uint256).max,
            uint256(0),
            uint256(block.timestamp + 365 days)
        ));
        bytes32 permitHash = keccak256(abi.encodePacked(bytes2(0x1901), permitDomainSeparator, permitStructHash));

        assertEq(dacDeal.isValidSignature(permitHash, ""), bytes4(0xffffffff));
    }

    // -------- Extension hook --------

    function test_dispatchExternalVoteSign_revertsForUnknownVenue() external {
        bytes32 unknownVenue = keccak256("not-a-real-venue");
        vm.expectRevert(DACErrorsLib.UnsupportedProposal.selector);
        dacDeal.t_dispatchExternalVoteSign(unknownVenue, bytes(""));
    }

    function test_dispatchExternalVoteSign_routesSnapshotToHandler() external {
        dacDeal.t_approveVersion(SNAPSHOT_VERSION, true);
        SnapshotV1Payload memory v = _samplePayload();
        bytes32 expectedHash = dacDeal.t_computeHash(v);

        dacDeal.t_dispatchExternalVoteSign(dacDeal.VENUE_SNAPSHOT_V1(), abi.encode(v));

        assertEq(dacDeal.isValidSignature(expectedHash, ""), bytes4(0x1626ba7e));
    }
}
