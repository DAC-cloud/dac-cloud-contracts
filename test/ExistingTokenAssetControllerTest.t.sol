// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UUPSProxy} from "../src/kernel/proxies/UUPSProxy.sol";
import {WrappedMainToken} from "../src/kernel/tokens/WrappedMainToken.sol";
import {ExistingTokenAssetController} from "../src/kernel/controllers/ExistingTokenAssetController.sol";

contract MockReserveToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ExistingTokenAssetControllerTest is Test {
    MockReserveToken internal underlying;
    MockReserveToken internal usdc;
    WrappedMainToken internal wrapped;
    ExistingTokenAssetController internal controller;

    address internal dac = makeAddr("dac");
    address internal dealManager = makeAddr("deal-manager");
    address internal holder = makeAddr("holder");
    address internal recipient = makeAddr("recipient");

    function setUp() external {
        underlying = new MockReserveToken("Underlying", "UND");
        usdc = new MockReserveToken("USD Coin", "USDC");

        wrapped = WrappedMainToken(
            address(
                new UUPSProxy(
                    address(new WrappedMainToken()),
                    abi.encodeWithSelector(
                        WrappedMainToken.initialize.selector,
                        address(underlying),
                        "Wrapped DAC",
                        "wDAC",
                        address(this)
                    )
                )
            )
        );

        controller = ExistingTokenAssetController(
            address(
                new UUPSProxy(
                    address(new ExistingTokenAssetController()),
                    abi.encodeWithSelector(
                        ExistingTokenAssetController.initialize.selector,
                        dac,
                        address(wrapped)
                    )
                )
            )
        );

        wrapped.setController(address(controller));

        vm.prank(dac);
        controller.setDealManager(dealManager);

        underlying.mint(holder, 1_000e18);
        usdc.mint(holder, 50_000e6);

        vm.startPrank(holder);
        underlying.approve(address(wrapped), type(uint256).max);
        usdc.approve(address(controller), type(uint256).max);
        vm.stopPrank();

        vm.prank(holder);
        wrapped.wrap(400e18);

        vm.prank(dac);
        controller.depositFrom(holder, address(usdc), 20_000e6);

        vm.prank(holder);
        assertTrue(wrapped.transfer(address(controller), 300e18));

        vm.prank(dac);
        controller.recordTreasuryDeposit(address(wrapped), 300e18);
    }

    function test_reservesWrappedRewardsAndSettlesClaimToRecipient() external {
        _mockDeal(1, address(new MockDealCell(address(usdc), 5_000e6, address(new MockStakeToken()))));

        vm.prank(dac);
        controller.approveFunding(1, 0, 120e18);

        assertEq(controller.mainTokenObligations(), 120e18);
        assertEq(controller.committedBalance(address(wrapped)), 120e18);
        assertEq(controller.freeBalance(address(wrapped)), 180e18);

        vm.prank(dealManager);
        controller.settleMainRewardClaim(recipient, 70e18);

        assertEq(wrapped.balanceOf(recipient), 70e18);
        assertEq(controller.mainTokenObligations(), 50e18);
        assertEq(controller.committedBalance(address(wrapped)), 50e18);
        assertEq(controller.freeBalance(address(wrapped)), 180e18);
    }

    function test_dividendPayout_reservesArbitraryTreasuryToken() external {
        bytes32 root = keccak256(abi.encodePacked(uint256(0), recipient, uint256(2_000e6)));

        vm.prank(dac);
        controller.recordDividendPayout(1, address(usdc), 2_000e6, root);

        assertEq(controller.committedBalance(address(usdc)), 2_000e6);
        assertEq(controller.freeBalance(address(usdc)), 18_000e6);

        vm.prank(dac);
        controller.claimDividend(1, 0, recipient, 2_000e6, new bytes32[](0));

        assertEq(usdc.balanceOf(recipient), 2_000e6);
        assertEq(controller.committedBalance(address(usdc)), 0);
        assertEq(controller.freeBalance(address(usdc)), 18_000e6);
    }

    function test_totalReleasedVotable_excludesControlledWrappedBalances() external {
        assertEq(controller.totalReleasedVotable(), 100e18);

        vm.prank(dealManager);
        controller.registerControlledAddress(recipient);

        vm.prank(holder);
        assertTrue(wrapped.transfer(recipient, 20e18));

        assertEq(controller.totalReleasedVotable(), 80e18);

        vm.expectRevert();
        vm.prank(recipient);
        wrapped.delegate(holder);
    }

    function _mockDeal(uint256 dealId, address dealCell) internal {
        vm.store(
            address(controller),
            bytes32(uint256(3)),
            bytes32(uint256(uint160(dealManager)))
        );

        vm.mockCall(
            dealManager,
            abi.encodeWithSignature("deals(uint256)", dealId),
            abi.encode(dealCell)
        );
    }
}

contract MockStakeToken is ERC20 {
    constructor() ERC20("Stake", "STK") {
        _mint(address(this), 1e18);
    }
}

contract MockDealCell {
    address internal fundingToken_;
    uint256 internal fundingAmount_;
    address internal stakeToken_;

    constructor(address fundingToken, uint256 fundingAmount, address stakeTokenAddr) {
        fundingToken_ = fundingToken;
        fundingAmount_ = fundingAmount;
        stakeToken_ = stakeTokenAddr;
    }

    struct Tranche {
        address token;
        uint256 amount;
        uint256 rewards;
        bool settled;
    }

    function fundingTranche(uint256) external view returns (Tranche memory tranche) {
        tranche = Tranche({
            token: fundingToken_,
            amount: fundingAmount_,
            rewards: 0,
            settled: false
        });
    }

    function stakeToken() external view returns (address) {
        return stakeToken_;
    }
}
