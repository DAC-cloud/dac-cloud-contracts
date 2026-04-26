// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "../../lib/IVotes.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {CapitalCall} from "../../interfaces/Structs.sol";
import {AssetCapability} from "../../interfaces/GovernanceStructs.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {MainToken} from "../tokens/MainToken.sol";
import {CapitalCallState} from "../interfaces/Structs.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";

contract NativeAssetController is IAssetController, Initializable {
    using SafeERC20 for IERC20;

    struct DividendPayoutState {
        address token;
        uint256 totalPayout;
        bytes32 merkleRoot;
    }

    address public dacCell;
    MainToken public mainToken;
    address public dealManager;
    address public agentToken;

    mapping(bytes32 => CapitalCallState) private capitalCalls;
    mapping(address => uint256) private treasuryBalances;
    mapping(address => uint256) private committedBalances;

    mapping(uint256 => DividendPayoutState) private dividendPayouts;
    mapping(bytes32 => bool) private dividendClaimed;

    uint256 private _mainTokenObligations;
    uint256 private unreleasedMainTokens;
    mapping(address => uint256) private lockedMainTokens;
    mapping(address => bool) private controlledAddresses;
    mapping(address => bool) private distributorAddresses;
    mapping(address => uint256) private distributorAllowances;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _dacCell, address _mainToken) external initializer {
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_mainToken != address(0), DACErrorsLib.NotAllowed());

        dacCell = _dacCell;
        mainToken = MainToken(_mainToken);

        controlledAddresses[_dacCell] = true;
        controlledAddresses[address(this)] = true;
    }

    function setDealManager(address _dealManager) external onlyDACCell {
        require(_dealManager != address(0), DACErrorsLib.NotAllowed());
        require(dealManager == address(0), DACErrorsLib.AlreadyInitialized());

        dealManager = _dealManager;
        controlledAddresses[_dealManager] = true;
    }

    function setAgentToken(address _agentToken) external onlyDACCell {
        require(_agentToken != address(0), DACErrorsLib.NotAllowed());
        require(agentToken == address(0), DACErrorsLib.AlreadyInitialized());

        agentToken = _agentToken;
        controlledAddresses[_agentToken] = true;
    }

    function depositFrom(address from, address token, uint256 amount) external onlyDACCell {
        IERC20(token).safeTransferFrom(from, address(this), amount);
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
        require(IVotes(address(mainToken)).getVotes(holder) > MathLib.mul(this.totalReleasedVotable(), qualification), DACErrorsLib.InsufficientBalance());

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

        IERC20(call.treasuryToken).safeTransferFrom(storedCall.tokenRecipient, address(this), call.cashAmount);

        treasuryBalances[call.treasuryToken] += call.cashAmount;
        mainToken.mint(call.tokenRecipient, call.tokenAmount);
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
        committedBalances[token] = committedBalances[token] >= amount ? committedBalances[token] - amount : 0;
        treasuryBalances[token] = treasuryBalances[token] >= amount ? treasuryBalances[token] - amount : 0;

        IERC20(token).safeTransfer(receiver, amount);
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
            IERC20(fundingToken).safeTransfer(dealManager, fundingAmount);
        } else {
            require(trancheId == 0, DACErrorsLib.InvalidTranche());
        }

        if (rewardsLimit > 0) {
            require(
                (mainToken.totalSupply() + _mainTokenObligations) + rewardsLimit <= mainToken.maxSupply(),
                DACErrorsLib.InsufficientRewards()
            );

            _mainTokenObligations += rewardsLimit;
        }
    }

    function settleMainRewardClaim(address to, uint256 amount) external onlyDealManager {
        _mainTokenObligations = _mainTokenObligations >= amount ? _mainTokenObligations - amount : 0;
        mainToken.mint(to, amount);
    }

    function releaseUnusedMintRewards(uint256 amount) external onlyDealManager {
        _mainTokenObligations = _mainTokenObligations >= amount ? _mainTokenObligations - amount : 0;
    }

    function mintMainToTreasury(uint256 amount) external onlyDACCell {
        mainToken.mint(address(this), amount);
        treasuryBalances[address(mainToken)] += amount;
    }

    function burnMainFromTreasury(uint256 amount) external onlyDACCell {
        require(_freeBalance(address(mainToken)) >= amount, DACErrorsLib.InsufficientTreasury());
        treasuryBalances[address(mainToken)] -= amount;
        mainToken.burn(amount);
    }

    function delegateVotes(address token, address delegatee) external onlyDACCell {
        IVotes(token).delegate(delegatee);
    }

    function registerControlledAddress(address controlled) external onlyDealManager {
        require(controlled != address(0), DACErrorsLib.NotAllowed());
        require(controlled != address(mainToken), DACErrorsLib.NotAllowed());

        controlledAddresses[controlled] = true;
    }

    function validateBoundAgentRecipient(address recipient) external view {
        _validateBoundAgentRecipient(recipient);
    }

    function authorizeAgentDistributor(address distributor, uint256 allowance) external onlyDACCell {
        require(distributor != address(0), DACErrorsLib.NotAllowed());
        require(!_isInvalidAgentRecipient(distributor), DACErrorsLib.NotAllowed());

        if (!distributorAddresses[distributor]) {
            require(agentToken == address(0) || IERC20(agentToken).balanceOf(distributor) == 0, DACErrorsLib.NotAllowed());
            distributorAddresses[distributor] = true;
        }

        distributorAllowances[distributor] += allowance;
    }

    function revokeAgentDistributor(address distributor) external onlyDACCell {
        require(distributorAddresses[distributor], DACErrorsLib.NotFound());
        distributorAllowances[distributor] = 0;
    }

    function handleAgentDistribution(address distributor, address recipient, uint256 amount) external onlyAgentToken {
        require(distributorAddresses[distributor], DACErrorsLib.NotTransferable());
        require(distributorAllowances[distributor] >= amount, DACErrorsLib.InsufficientBalance());

        _validateBoundAgentRecipient(recipient);

        distributorAllowances[distributor] -= amount;
    }

    function isAgentDistributor(address account) external view returns (bool) {
        return distributorAddresses[account];
    }

    function agentDistributorAllowance(address account) external view returns (uint256) {
        return distributorAllowances[account];
    }

    function onMainMove(address from, address to, uint256 amount) external onlyDealManager {
        if (from == address(0)) {
            if (controlledAddresses[to]) {
                lockedMainTokens[to] += amount;
                unreleasedMainTokens += amount;
            }
            return;
        }

        if (controlledAddresses[from]) {
            if (lockedMainTokens[from] < amount) {
                amount = lockedMainTokens[from];
            }

            lockedMainTokens[from] -= amount;
            if (controlledAddresses[to]) {
                lockedMainTokens[to] += amount;
            } else {
                unreleasedMainTokens -= amount;
            }
        }
    }

    function onMainDelegate(address from, address to) external view onlyDealManager {
        require(!controlledAddresses[from], DACErrorsLib.NoVotingPower());
        require(!controlledAddresses[to], DACErrorsLib.NoVotingPower());
    }

    function isControlledAddress(address addr) external view returns (bool) {
        return controlledAddresses[addr];
    }

    function totalReleasedVotable() external view returns (uint256) {
        return (mainToken.totalSupply() - unreleasedMainTokens)
            - (mainToken.balanceOf(dacCell) - lockedMainTokens[dacCell])
            - (mainToken.balanceOf(address(this)) - lockedMainTokens[address(this)]);
    }

    // Native mode uses mint-provenance tracking, not controlled-balance checkpoints.
    // This stub satisfies the interface; native DAC proposals use ERC20Votes snapshots directly.
    function getPastControlledBalance(uint256) external pure returns (uint256) {
        return 0;
    }

    function mainTokenObligations() external view returns (uint256) {
        return _mainTokenObligations;
    }

    function treasuryHolder() external view returns (address) {
        return address(this);
    }

    function supportsCapability(AssetCapability capability) external pure returns (bool) {
        return capability == AssetCapability.MINT
            || capability == AssetCapability.BURN
            || capability == AssetCapability.CAPITAL_CALL;
    }

    function _freeBalance(address token) internal view returns (uint256) {
        // Floor at 0: tolerate accounting drift (e.g. fee-on-transfer tokens) since
        // contracts are non-upgradeable and a hard underflow would brick the DAC.
        return treasuryBalances[token] >= committedBalances[token]
            ? treasuryBalances[token] - committedBalances[token]
            : 0;
    }

    function _validateBoundAgentRecipient(address recipient) internal view {
        require(recipient != address(0), DACErrorsLib.NotAllowed());
        require(!_isInvalidAgentRecipient(recipient), DACErrorsLib.NotAllowed());
        require(!distributorAddresses[recipient], DACErrorsLib.NotAllowed());
    }

    function _isInvalidAgentRecipient(address recipient) internal view returns (bool) {
        return
            controlledAddresses[recipient] ||
            recipient == address(mainToken) ||
            recipient == agentToken;
    }

    modifier onlyDACCell() {
        _onlyDACCell();
        _;
    }

    modifier onlyDealManager() {
        _onlyDealManager();
        _;
    }

    function _onlyDACCell() internal view {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());
    }

    function _onlyDealManager() internal view {
        require(msg.sender == dealManager, DACErrorsLib.NotAuthorized());
    }

    modifier onlyAgentToken() {
        require(msg.sender == agentToken, DACErrorsLib.NotAuthorized());
        _;
    }
}
