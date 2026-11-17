// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "../../lib/IVotes.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {CapitalCall} from "../../interfaces/Structs.sol";
import {AssetCapability, GovernanceLimits} from "../../interfaces/GovernanceStructs.sol";
import {IDealManager} from "../../interfaces/IDealManager.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {MainToken} from "../tokens/MainToken.sol";
import {CapitalCallState} from "../interfaces/Structs.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

contract NativeAssetController is IAssetController, Initializable {
    using Checkpoints for Checkpoints.Trace208;
    using SafeERC20 for IERC20;

    struct DividendPayoutState {
        address token;
        uint256 totalPayout;
        uint256 claimedPayout;
        bytes32 merkleRoot;
        uint256 claimDeadline;
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

    // Votable supply keyed by the main token's `mode=timestamp` clock. A proposal reads its
    // quorum base here at the same past timepoint it reads vote weights from the token, so
    // nothing that becomes votable after the snapshot can vote outside the base.
    Checkpoints.Trace208 private _votableCheckpoints;

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
        // Past votes against the past base: a balance borrowed inside this transaction does not qualify.
        uint256 snapshot = block.timestamp - 1;
        require(
            IVotes(address(mainToken)).getPastVotes(holder, snapshot)
                > MathLib.mul(_votableCheckpoints.upperLookupRecent(uint48(snapshot)), qualification),
            DACErrorsLib.InsufficientBalance()
        );

        previousBalance = treasuryBalances[token];
        currentBalance = IERC20(token).balanceOf(address(this));
        treasuryBalances[token] = currentBalance;
    }

    function createCapitalCall(
        uint256 id,
        address treasuryToken,
        address recipient,
        uint256 amount,
        uint256 cashAmount,
        uint256 expiry
    ) external onlyDACCell returns (bytes32 callHash) {
        // A call is an offer at a fixed price: it carries the last second it can be taken.
        // Zero means no expiry and is used only for a DAC's root call.
        require(expiry == 0 || expiry > block.timestamp, DACErrorsLib.CapitalCallExpired());

        _requireMintHeadroom(amount);

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
            fulfilled: false,
            expiry: expiry
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
        _requireNotExpired(callHash);

        _requireMintHeadroom(storedCall.tokenAmount);

        IERC20(call.treasuryToken).safeTransferFrom(storedCall.tokenRecipient, address(this), call.cashAmount);

        treasuryBalances[call.treasuryToken] += call.cashAmount;
        mainToken.mint(call.tokenRecipient, call.tokenAmount);
        capitalCalls[callHash].fulfilled = true;
    }

    function getCapitalCall(bytes32 callHash) external view returns (CapitalCall memory capitalCall) {
        require(!capitalCalls[callHash].fulfilled, DACErrorsLib.AlreadyFulfilled());
        capitalCall = capitalCalls[callHash].call;
        require(capitalCall.tokenAmount > 0, DACErrorsLib.InvalidCapitalCall());
        _requireNotExpired(callHash);
    }

    function getCapitalCallExpiry(bytes32 callHash) external view returns (uint256) {
        return capitalCalls[callHash].expiry;
    }

    function _requireNotExpired(bytes32 callHash) internal view {
        uint256 expiry = capitalCalls[callHash].expiry;
        require(expiry == 0 || block.timestamp <= expiry, DACErrorsLib.CapitalCallExpired());
    }

    function recordDividendPayout(uint256 proposalId, address token, uint256 totalPayout, bytes32 merkleRoot)
        external
        onlyDACCell
    {
        require(dividendPayouts[proposalId].merkleRoot == bytes32(0), DACErrorsLib.AlreadyInitialized());
        // A zero root can never be claimed against and there is no un-commit path.
        require(merkleRoot != bytes32(0) && totalPayout > 0, DACErrorsLib.NotAllowed());
        require(_freeBalance(token) >= totalPayout, DACErrorsLib.InsufficientTreasury());

        dividendPayouts[proposalId] = DividendPayoutState({
            token: token,
            totalPayout: totalPayout,
            claimedPayout: 0,
            merkleRoot: merkleRoot,
            claimDeadline: block.timestamp + GovernanceLimits.DIVIDEND_CLAIM_WINDOW
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

        // The merkle root is governance-supplied and its leaf sum cannot be
        // verified on-chain. Cap cumulative claims at the committed amount so a
        // malformed root can never draw on other commitments or free treasury.
        DividendPayoutState storage payout = dividendPayouts[proposalId];
        require(block.timestamp <= payout.claimDeadline, DACErrorsLib.DividendClaimWindowClosed());
        require(payout.claimedPayout + amount <= payout.totalPayout, DACErrorsLib.DividendPayoutExceeded());
        payout.claimedPayout += amount;

        dividendClaimed[claimedKey] = true;
        token = payout.token;
        committedBalances[token] = committedBalances[token] >= amount ? committedBalances[token] - amount : 0;
        treasuryBalances[token] = treasuryBalances[token] >= amount ? treasuryBalances[token] - amount : 0;

        IERC20(token).safeTransfer(receiver, amount);
    }

    /// Once a payout's claim window has closed, releases whatever was not claimed back to
    /// the free treasury. Nothing leaves the treasury, so the DAC cell lets anyone call it.
    function sweepDividend(uint256 proposalId) external onlyDACCell returns (address token, uint256 unclaimed) {
        DividendPayoutState storage payout = dividendPayouts[proposalId];
        require(payout.merkleRoot != bytes32(0), DACErrorsLib.NotFound());
        require(block.timestamp > payout.claimDeadline, DACErrorsLib.DividendClaimWindowOpen());

        unclaimed = payout.totalPayout - payout.claimedPayout;
        require(unclaimed > 0, DACErrorsLib.NotAllowed());
        payout.claimedPayout = payout.totalPayout;

        token = payout.token;
        committedBalances[token] = committedBalances[token] >= unclaimed ? committedBalances[token] - unclaimed : 0;
    }

    function dividendClaimDeadline(uint256 proposalId) external view returns (uint256) {
        return dividendPayouts[proposalId].claimDeadline;
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
        _requireMintHeadroom(amount);
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
        bool fromControlled = from != address(0) && controlledAddresses[from];
        bool toControlled = to != address(0) && controlledAddresses[to];

        if (from == address(0)) {
            if (toControlled) {
                lockedMainTokens[to] += amount;
                unreleasedMainTokens += amount;
            }
        } else if (fromControlled) {
            if (lockedMainTokens[from] < amount) {
                amount = lockedMainTokens[from];
            }

            lockedMainTokens[from] -= amount;
            if (toControlled) {
                lockedMainTokens[to] += amount;
            } else {
                unreleasedMainTokens -= amount;
            }
        }

        // Votable supply can only change on a mint, a burn, or a move that touches a
        // controlled address. Holder-to-holder transfers leave it alone and cost nothing here.
        if (from == address(0) || to == address(0) || fromControlled || toControlled) {
            _votableCheckpoints.push(uint48(block.timestamp), uint208(_totalReleasedVotable()));
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
        return _totalReleasedVotable();
    }

    function _totalReleasedVotable() internal view returns (uint256) {
        return (mainToken.totalSupply() - unreleasedMainTokens)
            - (mainToken.balanceOf(dacCell) - lockedMainTokens[dacCell])
            - (mainToken.balanceOf(address(this)) - lockedMainTokens[address(this)]);
    }

    function getPastVotableSupply(uint256 timepoint) external view returns (uint256) {
        return _votableCheckpoints.upperLookupRecent(uint48(timepoint));
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

    // Treasury mints and capital calls must leave room under maxSupply for every
    // reward the DAC has already promised to active deals, or those claims revert.
    function _requireMintHeadroom(uint256 amount) internal view {
        require(
            mainToken.totalSupply() + _mainTokenObligations + amount <= mainToken.maxSupply(),
            DACErrorsLib.MaxSupplyExceeded()
        );
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
