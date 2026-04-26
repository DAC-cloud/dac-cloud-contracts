// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Permit2Treasury, Permit2TreasuryFactory} from "../src/modules/core/deals/Permit2Treasury.sol";
import {TreasurySpendAllowance} from "../src/modules/core/interfaces/Structs.sol";
import {IPermit2} from "../src/lib/IPermit2.sol";

contract MockPermit2Token is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVotesTokenForPermit2 is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Permit2 Gov Token", "P2G") ERC20Permit("Permit2 Gov Token") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

contract MockPermit2Impl is IPermit2 {
    struct ApproveCall {
        address token;
        address spender;
        uint160 amount;
        uint48 expiration;
    }

    struct TransferFromCall {
        address from;
        address to;
        uint160 amount;
        address token;
    }

    struct PermitTransferCall {
        address owner;
        address token;
        uint256 permittedAmount;
        uint256 nonce;
        uint256 deadline;
        address to;
        uint256 requestedAmount;
    }

    ApproveCall public lastApproveCall;
    TransferFromCall public lastTransferFromCall;
    PermitTransferCall public lastPermitTransferCall;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        lastApproveCall = ApproveCall({
            token: token,
            spender: spender,
            amount: amount,
            expiration: expiration
        });
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        lastTransferFromCall = TransferFromCall({
            from: from,
            to: to,
            amount: amount,
            token: token
        });

        ERC20(token).transferFrom(from, to, amount);
    }

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata
    ) external {
        lastPermitTransferCall = PermitTransferCall({
            owner: owner,
            token: permit.permitted.token,
            permittedAmount: permit.permitted.amount,
            nonce: permit.nonce,
            deadline: permit.deadline,
            to: transferDetails.to,
            requestedAmount: transferDetails.requestedAmount
        });

        ERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}

contract Permit2TreasuryTest is Test {
    MockPermit2Impl internal permit2;
    Permit2Treasury internal treasury;
    MockPermit2Token internal token;
    MockVotesTokenForPermit2 internal votesToken;

    address internal treasuryDeal = makeAddr("treasury-deal");
    address internal agent = makeAddr("agent");
    address internal source = makeAddr("source");
    address internal otherSource = makeAddr("other-source");
    address internal destination = makeAddr("destination");
    address internal delegatee = makeAddr("delegatee");

    function setUp() public {
        permit2 = new MockPermit2Impl();
        Permit2TreasuryFactory factory = new Permit2TreasuryFactory(address(permit2));
        treasury = factory.deployPermit2Treasury(treasuryDeal);

        token = new MockPermit2Token("Mock Dollar", "mUSD");
        votesToken = new MockVotesTokenForPermit2();

        token.mint(source, 10_000);
        token.mint(otherSource, 10_000);
        token.mint(address(treasury), 10_000);
        votesToken.mint(address(treasury), 1_000e18);

        vm.prank(source);
        token.approve(address(permit2), type(uint256).max);
        vm.prank(otherSource);
        token.approve(address(permit2), type(uint256).max);
    }

    function test_clockMetadata() public view {
        assertEq(treasury.CLOCK_MODE(), "mode=timestamp");
        assertEq(treasury.clock(), uint48(block.timestamp));
    }

    function test_onlyDealFunctions_revertForOutsiders() public {
        TreasurySpendAllowance memory allowance = TreasurySpendAllowance({
            totalAmount: 100,
            singleTxAmount: 50,
            clockLimit: 0,
            duration: 1 hours
        });

        vm.expectRevert(Permit2Treasury.NotAuthorized.selector);
        treasury.approveSpend(address(token), destination, 100, uint48(block.timestamp + 1 days));

        vm.expectRevert(Permit2Treasury.NotAuthorized.selector);
        treasury.directSpend(address(token), destination, 100);

        vm.expectRevert(Permit2Treasury.NotAuthorized.selector);
        treasury.approveSpendAllowance(agent, address(token), destination, allowance);

        vm.expectRevert(Permit2Treasury.NotAuthorized.selector);
        treasury.revokeAgent(agent, address(token), destination);

        vm.expectRevert(Permit2Treasury.NotAuthorized.selector);
        treasury.approveReceive(agent, source, address(token), 100);

        vm.expectRevert(Permit2Treasury.NotAuthorized.selector);
        treasury.delegateVotes(address(votesToken), delegatee);

        vm.expectRevert(Permit2Treasury.NotAuthorized.selector);
        treasury.returnCapitalToDeal(address(token), 100);
    }

    function test_approveSpend_recordsPermit2Approval() public {
        vm.prank(treasuryDeal);
        treasury.approveSpend(address(token), destination, 250, uint48(block.timestamp + 2 days));

        assertEq(token.allowance(address(treasury), address(permit2)), uint256(type(uint160).max));

        (
            address approvedToken,
            address approvedSpender,
            uint160 approvedAmount,
            uint48 approvedExpiration
        ) = permit2.lastApproveCall();

        assertEq(approvedToken, address(token));
        assertEq(approvedSpender, destination);
        assertEq(approvedAmount, 250);
        assertEq(approvedExpiration, uint48(block.timestamp + 2 days));
    }

    function test_directSpend_transfersFunds() public {
        uint256 before = token.balanceOf(destination);

        vm.prank(treasuryDeal);
        treasury.directSpend(address(token), destination, 300);

        assertEq(token.balanceOf(destination), before + 300);
        assertEq(token.balanceOf(address(treasury)), 9_700);
    }

    function test_approveReceive_and_revokeAgent_updateReceiveAllowance() public {
        vm.prank(treasuryDeal);
        treasury.approveReceive(agent, source, address(token), 600);

        bytes32 allowanceHash = keccak256(abi.encode(agent, address(token), source));
        assertEq(treasury.approvedAgents(allowanceHash), 600);

        vm.prank(treasuryDeal);
        treasury.revokeAgent(agent, address(token), source);

        assertEq(treasury.approvedAgents(allowanceHash), 0);
    }

    function test_approveSpendAllowance_and_revokeAgent_updateSpendAllowance() public {
        TreasurySpendAllowance memory allowance = TreasurySpendAllowance({
            totalAmount: 700,
            singleTxAmount: 200,
            clockLimit: 0,
            duration: 1 hours
        });

        vm.prank(treasuryDeal);
        treasury.approveSpendAllowance(agent, address(token), destination, allowance);

        bytes32 allowanceHash = keccak256(abi.encode(agent, address(token), destination));
        (
            uint160 totalAmount,
            uint160 singleTxAmount,
            uint256 clockLimit,
            uint256 duration
        ) = treasury.agentAllowance(allowanceHash);

        assertEq(totalAmount, allowance.totalAmount);
        assertEq(singleTxAmount, allowance.singleTxAmount);
        assertEq(clockLimit, allowance.clockLimit);
        assertEq(duration, allowance.duration);

        vm.prank(treasuryDeal);
        treasury.revokeAgent(agent, address(token), destination);

        (totalAmount, singleTxAmount, clockLimit, duration) = treasury.agentAllowance(allowanceHash);
        assertEq(totalAmount, 0);
        assertEq(singleTxAmount, 0);
        assertEq(clockLimit, 0);
        assertEq(duration, 0);
    }

    function test_delegateVotes_delegatesTreasuryHeldVotes() public {
        vm.prank(treasuryDeal);
        treasury.delegateVotes(address(votesToken), delegatee);

        assertEq(votesToken.delegates(address(treasury)), delegatee);
    }

    function test_returnCapitalToDeal_transfersBackToDeal() public {
        uint256 before = token.balanceOf(treasuryDeal);

        vm.prank(treasuryDeal);
        treasury.returnCapitalToDeal(address(token), 450);

        assertEq(token.balanceOf(treasuryDeal), before + 450);
        assertEq(token.balanceOf(address(treasury)), 9_550);
    }

    function test_executeReceivePermit2_usesExactApproval() public {
        _approveReceive(source, 800);

        vm.prank(agent);
        treasury.executeReceivePermit2(address(token), source, 300);

        bytes32 allowanceHash = keccak256(abi.encode(agent, address(token), source));
        assertEq(treasury.approvedAgents(allowanceHash), 500);
        assertEq(token.balanceOf(address(treasury)), 10_300);

        (address from, address to, uint160 amount, address transferToken) = permit2.lastTransferFromCall();
        assertEq(from, source);
        assertEq(to, address(treasury));
        assertEq(amount, 300);
        assertEq(transferToken, address(token));
    }

    function test_executeReceivePermit2_fallsBackToWildcardSource() public {
        _approveReceive(address(0), 500);

        vm.prank(agent);
        treasury.executeReceivePermit2(address(token), otherSource, 200);

        bytes32 wildcardHash = keccak256(abi.encode(agent, address(token), address(0)));
        assertEq(treasury.approvedAgents(wildcardHash), 300);
        assertEq(token.balanceOf(address(treasury)), 10_200);
    }

    function test_executeReceivePermit2_revertsWithoutApproval() public {
        vm.expectRevert(Permit2Treasury.ReceiveNotApproved.selector);
        vm.prank(agent);
        treasury.executeReceivePermit2(address(token), source, 100);
    }

    function test_executeReceivePermit2Signature_revertsForInvalidRecipient() public {
        _approveReceive(source, 400);

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({
                token: address(token),
                amount: 400
            }),
            nonce: 1,
            deadline: block.timestamp + 1 days
        });

        IPermit2.SignatureTransferDetails memory transferDetails = IPermit2.SignatureTransferDetails({
            to: destination,
            requestedAmount: 150
        });

        vm.expectRevert(Permit2Treasury.InvalidTransfer.selector);
        vm.prank(agent);
        treasury.executeReceivePermit2Signature(permit, transferDetails, source, hex"");
    }

    function test_executeReceivePermit2Signature_usesWildcardApproval() public {
        _approveReceive(address(0), 900);

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({
                token: address(token),
                amount: 900
            }),
            nonce: 7,
            deadline: block.timestamp + 2 days
        });

        IPermit2.SignatureTransferDetails memory transferDetails = IPermit2.SignatureTransferDetails({
            to: address(treasury),
            requestedAmount: 250
        });

        vm.prank(agent);
        treasury.executeReceivePermit2Signature(permit, transferDetails, otherSource, hex"1234");

        bytes32 wildcardHash = keccak256(abi.encode(agent, address(token), address(0)));
        assertEq(treasury.approvedAgents(wildcardHash), 650);
        assertEq(token.balanceOf(address(treasury)), 10_250);

        (
            address owner,
            address permitToken,
            uint256 permittedAmount,
            uint256 nonce,
            uint256 deadline,
            address recipient,
            uint256 requestedAmount
        ) = permit2.lastPermitTransferCall();

        assertEq(owner, otherSource);
        assertEq(permitToken, address(token));
        assertEq(permittedAmount, 900);
        assertEq(nonce, 7);
        assertEq(deadline, block.timestamp + 2 days);
        assertEq(recipient, address(treasury));
        assertEq(requestedAmount, 250);
    }

    function test_executeAgentSpend_usesExactDestinationAllowanceAndCooldown() public {
        _approveSpendAllowance(destination, 600, 300, 0, 1 hours);

        vm.prank(agent);
        treasury.executeAgentSpend(address(token), destination, 200);

        bytes32 allowanceHash = keccak256(abi.encode(agent, address(token), destination));
        (
            uint160 totalAmount,
            uint160 singleTxAmount,
            uint256 clockLimit,
            uint256 duration
        ) = treasury.agentAllowance(allowanceHash);

        assertEq(totalAmount, 400);
        assertEq(singleTxAmount, 300);
        assertEq(duration, 1 hours);
        assertEq(clockLimit, block.timestamp + 1 hours);
        assertEq(token.balanceOf(destination), 200);

        vm.expectRevert(Permit2Treasury.InvalidDealTimeBounds.selector);
        vm.prank(agent);
        treasury.executeAgentSpend(address(token), destination, 1);
    }

    function test_executeAgentSpend_fallsBackToWildcardDestination() public {
        _approveSpendAllowance(address(0), 500, 250, 0, 30 minutes);

        vm.prank(agent);
        treasury.executeAgentSpend(address(token), destination, 150);

        bytes32 wildcardHash = keccak256(abi.encode(agent, address(token), address(0)));
        (uint160 totalAmount,,,) = treasury.agentAllowance(wildcardHash);

        assertEq(totalAmount, 350);
        assertEq(token.balanceOf(destination), 150);
    }

    function test_executeAgentSpend_revertsWhenTotalAmountInsufficient() public {
        _approveSpendAllowance(destination, 100, 100, 0, 1 hours);

        vm.expectRevert(Permit2Treasury.SpendNotApproved.selector);
        vm.prank(agent);
        treasury.executeAgentSpend(address(token), destination, 101);
    }

    function test_executeAgentSpend_revertsWhenSingleTxAmountExceeded() public {
        _approveSpendAllowance(destination, 500, 100, 0, 1 hours);

        vm.expectRevert(Permit2Treasury.InvalidDealSize.selector);
        vm.prank(agent);
        treasury.executeAgentSpend(address(token), destination, 101);
    }

    function _approveReceive(address approvedSource, uint160 amount) internal {
        vm.prank(treasuryDeal);
        treasury.approveReceive(agent, approvedSource, address(token), amount);
    }

    function _approveSpendAllowance(
        address approvedDestination,
        uint160 totalAmount,
        uint160 singleTxAmount,
        uint256 clockLimit,
        uint256 duration
    ) internal {
        vm.prank(treasuryDeal);
        treasury.approveSpendAllowance(
            agent,
            address(token),
            approvedDestination,
            TreasurySpendAllowance({
                totalAmount: totalAmount,
                singleTxAmount: singleTxAmount,
                clockLimit: clockLimit,
                duration: duration
            })
        );
    }
}
