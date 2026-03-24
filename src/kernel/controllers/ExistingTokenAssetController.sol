// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "../../lib/IVotes.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {CapitalCall} from "../../interfaces/Structs.sol";
import {AssetCapability} from "../../interfaces/GovernanceStructs.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {WrappedMainToken} from "../tokens/WrappedMainToken.sol";
import {CapitalCallState} from "../interfaces/Structs.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";

contract ExistingTokenAssetController is IAssetController, Initializable {
    struct DividendPayoutState {
        address token;
        uint256 totalPayout;
        bytes32 merkleRoot;
    }

    address public dacCell;
    WrappedMainToken public mainToken;
    IERC20 public underlyingToken;
    address public dealManager;

    mapping(bytes32 => CapitalCallState) private capitalCalls;
    mapping(address => uint256) private treasuryBalances;
    mapping(address => uint256) private committedBalances;

    mapping(uint256 => DividendPayoutState) private dividendPayouts;
    mapping(bytes32 => bool) private dividendClaimed;

    uint256 private _mainTokenObligations;
    mapping(address => bool) private controlledAddresses;
    uint256 private controlledWrappedBalance;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _dacCell, address _wrappedMainToken) external initializer {
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_wrappedMainToken != address(0), DACErrorsLib.NotAllowed());

        dacCell = _dacCell;
        mainToken = WrappedMainToken(_wrappedMainToken);
        underlyingToken = IERC20(mainToken.underlying());

        controlledAddresses[_dacCell] = true;
        controlledAddresses[address(this)] = true;
    }

    function setDealManager(address _dealManager) external onlyDACCell {
        require(_dealManager != address(0), DACErrorsLib.NotAllowed());
        require(dealManager == address(0), DACErrorsLib.AlreadyInitialized());

        dealManager = _dealManager;
        controlledAddresses[_dealManager] = true;
    }

    function depositFrom(address from, address token, uint256 amount) external onlyDACCell {
        require(IERC20(token).transferFrom(from, address(this), amount), DACErrorsLib.TransferFailed());
        treasuryBalances[token] += amount;
    }

    function recordTreasuryDeposit(address token, uint256 amount) external onlyDACCell {
        treasuryBalances[token] += amount;
    }

    function syncTreasury(address token, address holder, uint256 qualification)
        external
        onlyDACCell
        returns (uint256 previousBalance, uint256 currentBalance)
    {
        require(IVotes(address(mainToken)).getVotes(holder) > qualification, DACErrorsLib.InsufficientBalance());

        previousBalance = treasuryBalances[token];
        currentBalance = IERC20(token).balanceOf(address(this));
        treasuryBalances[token] = currentBalance;
    }

    function createCapitalCall(
        uint256 id,
        address treasuryToken,
        address recipient,
        uint256 amount,
        uint256 cashAmount
    ) external onlyDACCell returns (bytes32 callHash) {
        require(_freeBalance(address(mainToken)) >= amount, DACErrorsLib.InsufficientTreasury());

        CapitalCall memory call = CapitalCall({
            treasuryToken: treasuryToken,
            nonce: id,
            tokenRecipient: recipient,
            tokenAmount: amount,
            cashAmount: cashAmount
        });

        callHash = keccak256(abi.encode(call));

        capitalCalls[callHash] = CapitalCallState({
            call: call,
            fulfilled: false
        });
    }

    function fulfillCapitalCall(CapitalCall calldata call)
        external
        onlyDACCell
        returns (bytes32 callHash, CapitalCall memory storedCall)
    {
        callHash = keccak256(abi.encode(call));
        require(!capitalCalls[callHash].fulfilled, DACErrorsLib.AlreadyFulfilled());

        storedCall = capitalCalls[callHash].call;
        require(storedCall.tokenAmount > 0, DACErrorsLib.InvalidCapitalCall());
        require(_freeBalance(address(mainToken)) >= storedCall.tokenAmount, DACErrorsLib.InsufficientTreasury());

        require(
            IERC20(storedCall.treasuryToken).transferFrom(storedCall.tokenRecipient, address(this), storedCall.cashAmount),
            DACErrorsLib.TransferFailed()
        );

        treasuryBalances[storedCall.treasuryToken] += storedCall.cashAmount;
        treasuryBalances[address(mainToken)] -= storedCall.tokenAmount;

        require(IERC20(address(mainToken)).transfer(storedCall.tokenRecipient, storedCall.tokenAmount), DACErrorsLib.TransferFailed());
        capitalCalls[callHash].fulfilled = true;
    }

    function getCapitalCall(bytes32 callHash) external view returns (CapitalCall memory capitalCall) {
        require(!capitalCalls[callHash].fulfilled, DACErrorsLib.AlreadyFulfilled());
        capitalCall = capitalCalls[callHash].call;
        require(capitalCall.tokenAmount > 0, DACErrorsLib.InvalidCapitalCall());
    }

    function recordDividendPayout(uint256 proposalId, address token, uint256 totalPayout, bytes32 merkleRoot)
        external
        onlyDACCell
    {
        require(dividendPayouts[proposalId].merkleRoot == bytes32(0), DACErrorsLib.AlreadyInitialized());
        require(_freeBalance(token) >= totalPayout, DACErrorsLib.InsufficientTreasury());

        dividendPayouts[proposalId] = DividendPayoutState({
            token: token,
            totalPayout: totalPayout,
            merkleRoot: merkleRoot
        });
        committedBalances[token] += totalPayout;
    }

    function claimDividend(
        uint256 proposalId,
        uint256 index,
        address receiver,
        uint256 amount,
        bytes32[] calldata proof
    ) external onlyDACCell returns (address token) {
        bytes32 root = dividendPayouts[proposalId].merkleRoot;
        require(root != bytes32(0), DACErrorsLib.NotFound());

        bytes32 leaf = keccak256(abi.encodePacked(index, receiver, amount));
        bytes32 claimedKey = keccak256(abi.encodePacked(proposalId, root, leaf));

        require(!dividendClaimed[claimedKey], DACErrorsLib.DividendAlreadyClaimed(proposalId, receiver));
        require(MerkleProof.verify(proof, root, leaf), DACErrorsLib.InvalidMerkleProof());

        dividendClaimed[claimedKey] = true;
        token = dividendPayouts[proposalId].token;
        committedBalances[token] -= amount;
        treasuryBalances[token] -= amount;

        require(IERC20(token).transfer(receiver, amount), DACErrorsLib.TransferFailed());
    }

    function approveFunding(uint256 dealId, uint256 trancheId, uint256 rewardsLimit) external onlyDACCell {
        address dealCell = IDealManager(dealManager).deals(dealId);
        require(dealCell != address(0), DACErrorsLib.InvalidDealId(dealId));

        require(
            IERC20(IDealCell(dealCell).stakeToken()).totalSupply() > 0,
            DACErrorsLib.NoStake()
        );

        address fundingToken = IDealCell(dealCell).fundingTranche(trancheId).token;
        uint256 fundingAmount = IDealCell(dealCell).fundingTranche(trancheId).amount;

        require(_freeBalance(fundingToken) >= fundingAmount, DACErrorsLib.InsufficientTreasury());

        if (fundingAmount > 0) {
            treasuryBalances[fundingToken] -= fundingAmount;
            require(IERC20(fundingToken).transfer(dealManager, fundingAmount), DACErrorsLib.TransferFailed());
        } else {
            require(trancheId == 0, DACErrorsLib.InvalidTranche());
        }

        if (rewardsLimit > 0) {
            require(_freeBalance(address(mainToken)) >= rewardsLimit, DACErrorsLib.InsufficientRewards());
            committedBalances[address(mainToken)] += rewardsLimit;
            _mainTokenObligations += rewardsLimit;
        }
    }

    function settleMainRewardClaim(address to, uint256 amount) external onlyDealManager {
        committedBalances[address(mainToken)] -= amount;
        treasuryBalances[address(mainToken)] -= amount;
        _mainTokenObligations -= amount;

        require(IERC20(address(mainToken)).transfer(to, amount), DACErrorsLib.TransferFailed());
    }

    function releaseUnusedMintRewards(uint256 amount) external onlyDealManager {
        committedBalances[address(mainToken)] -= amount;
        _mainTokenObligations -= amount;
    }

    function mintMainToTreasury(uint256) external pure {
        revert DACErrorsLib.NotAllowed();
    }

    function burnMainFromTreasury(uint256 amount) external view onlyDACCell {
        require(_freeBalance(address(mainToken)) >= amount, DACErrorsLib.InsufficientTreasury());
        revert DACErrorsLib.NotAllowed();
    }

    function delegateVotes(address token, address delegatee) external onlyDACCell {
        IVotes(token).delegate(delegatee);
    }

    function registerControlledAddress(address controlled) external onlyDealManager {
        require(controlled != address(0), DACErrorsLib.NotAllowed());
        require(controlled != address(mainToken), DACErrorsLib.NotAllowed());
        if (controlledAddresses[controlled]) return;
        controlledAddresses[controlled] = true;
        controlledWrappedBalance += IERC20(address(mainToken)).balanceOf(controlled);
    }

    function onMainMove(address from, address to, uint256 amount) external onlyWrappedMainToken {
        if (from != address(0) && controlledAddresses[from]) {
            controlledWrappedBalance -= amount;
        }
        if (to != address(0) && controlledAddresses[to]) {
            controlledWrappedBalance += amount;
        }
    }

    function onMainDelegate(address from, address to) external view onlyWrappedMainToken {
        require(!controlledAddresses[from], DACErrorsLib.NoVotingPower());
        require(!controlledAddresses[to], DACErrorsLib.NoVotingPower());
    }

    function totalReleasedVotable() external view returns (uint256) {
        return IERC20(address(mainToken)).totalSupply() - controlledWrappedBalance;
    }

    function mainTokenObligations() external view returns (uint256) {
        return _mainTokenObligations;
    }

    function treasuryHolder() external view returns (address) {
        return address(this);
    }

    function supportsCapability(AssetCapability capability) external pure returns (bool) {
        return capability == AssetCapability.WRAP
            || capability == AssetCapability.UNWRAP
            || capability == AssetCapability.RESERVE_BACKED_CLAIMS
            || capability == AssetCapability.CAPITAL_CALL;
    }

    function treasuryBalance(address token) external view returns (uint256) {
        return treasuryBalances[token];
    }

    function committedBalance(address token) external view returns (uint256) {
        return committedBalances[token];
    }

    function freeBalance(address token) external view returns (uint256) {
        return _freeBalance(token);
    }

    function _freeBalance(address token) internal view returns (uint256) {
        return treasuryBalances[token] - committedBalances[token];
    }

    modifier onlyDACCell() {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());
        _;
    }

    modifier onlyDealManager() {
        require(msg.sender == dealManager, DACErrorsLib.NotAuthorized());
        _;
    }

    modifier onlyWrappedMainToken() {
        require(msg.sender == address(mainToken), DACErrorsLib.NotAuthorized());
        _;
    }
}
