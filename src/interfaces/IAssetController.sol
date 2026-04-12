// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CapitalCall} from "./Structs.sol";
import {AssetCapability} from "./GovernanceStructs.sol";

interface IAssetController {
    function initialize(address _dacCell, address _mainToken) external;
    function setDealManager(address _dealManager) external;
    function setAgentToken(address _agentToken) external;

    function depositFrom(address from, address token, uint256 amount) external;
    function recordTreasuryDeposit(address token, uint256 amount) external;
    function syncTreasury(address token, address holder, uint256 qualification)
        external
        returns (uint256 previousBalance, uint256 currentBalance);

    function createCapitalCall(
        uint256 id,
        address treasuryToken,
        address recipient,
        uint256 amount,
        uint256 cashAmount
    ) external returns (bytes32 callHash);

    function fulfillCapitalCall(CapitalCall calldata call)
        external
        returns (bytes32 callHash, CapitalCall memory storedCall);

    function getCapitalCall(bytes32 callHash) external view returns (CapitalCall memory capitalCall);

    function recordDividendPayout(uint256 proposalId, address token, uint256 totalPayout, bytes32 merkleRoot) external;
    function claimDividend(
        uint256 proposalId,
        uint256 index,
        address receiver,
        uint256 amount,
        bytes32[] calldata proof
    ) external returns (address token);

    function approveFunding(uint256 dealId, uint256 trancheId, uint256 rewardsLimit) external;

    function settleMainRewardClaim(address to, uint256 amount) external;
    function releaseUnusedMintRewards(uint256 amount) external;

    function mintMainToTreasury(uint256 amount) external;
    function burnMainFromTreasury(uint256 amount) external;
    function delegateVotes(address token, address delegatee) external;

    function registerControlledAddress(address controlled) external;
    function onMainMove(address from, address to, uint256 amount) external;
    function onMainDelegate(address from, address to) external view;

    function validateBoundAgentRecipient(address recipient) external view;
    function authorizeAgentDistributor(address distributor, uint256 allowance) external;
    function revokeAgentDistributor(address distributor) external;
    function handleAgentDistribution(address distributor, address recipient, uint256 amount) external;
    function isAgentDistributor(address account) external view returns (bool);
    function agentDistributorAllowance(address account) external view returns (uint256);

    function totalReleasedVotable() external view returns (uint256);
    function getPastControlledBalance(uint256 blockNumber) external view returns (uint256);
    function mainTokenObligations() external view returns (uint256);
    function treasuryHolder() external view returns (address);
    function supportsCapability(AssetCapability capability) external view returns (bool);
}
