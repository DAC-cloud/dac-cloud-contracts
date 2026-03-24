// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct ProtocolConfig {
    address permit2;
}

struct ProtocolDeployment {
    uint256 chainId;
    uint256 blockNumber;
    address deployer;
    address permit2;
    address mainTokenFactory;
    address mainTokenImpl;
    address agentTokenFactory;
    address agentTokenImpl;
    address stakedAgentFactory;
    address stakedAgentImpl;
    address dacCellFactory;
    address dacCellImpl;
    address dealCellFactory;
    address dealCellImpl;
    address dealManagerFactory;
    address dealManagerImpl;
    address moduleRegistryFactory;
    address moduleRegistryImpl;
    address assetControllerFactory;
    address assetControllerImpl;
    address existingAssetControllerFactory;
    address existingAssetControllerImpl;
    address governanceSchemaFactory;
    address governanceSchemaImpl;
    address hybridGovernanceSchemaFactory;
    address hybridGovernanceSchemaImpl;
    address dacGovernanceFactory;
    address dacGovernanceImpl;
    address hybridProposalFactory;
    address hybridProposalImpl;
    address governanceOracleFactory;
    address governanceOracleImpl;
    address wrappedMainTokenFactory;
    address wrappedMainTokenImpl;
    address coreDealGovernanceFactory;
    address coreDealGovernanceImpl;
    address dacDealFactory;
    address dacDealImpl;
    address treasuryDealFactory;
    address treasuryDealImpl;
    address permit2TreasuryFactory;
    address milestoneEvaluatorFactory;
    address milestoneEvaluatorImpl;
    address revenueEvaluatorFactory;
    address revenueEvaluatorImpl;
    address coreModuleFactory;
    address dacFactory;
}

struct BasicDACSeedConfig {
    string label;
    string symbol;
    string name;
    string description;
    uint256 mainTokenMaxSupply;
    uint256 defaultQuorum;
    uint256 founderAllocation;
    uint256 founderCommitment;
    bool dividendsEnabled;
    address treasuryToken;
    bool deployMockTreasuryToken;
    uint8 mockTreasuryDecimals;
    uint256 mockTreasuryMint;
}

struct ExistingDACSeedConfig {
    string label;
    string symbol;
    string name;
    string description;
    bool dividendsEnabled;
    address underlyingToken;
    bool deployMockUnderlyingToken;
    uint8 mockUnderlyingDecimals;
    uint256 mockUnderlyingMint;
    uint256 wrapAmount;
    uint256 treasurySeedAmount;
    address oracleAdmin;
    address oraclePublisher;
    uint256 quorumPercent;
    uint256 highQuorumPercent;
    uint256 blockingPercent;
    uint256 duration;
    uint256 qualification;
    uint256 oraclePublishDeadline;
    uint256 fallbackWarmupDuration;
    uint256 fallbackDuration;
}

struct BasicDACSeed {
    uint256 chainId;
    uint256 blockNumber;
    string label;
    address broadcaster;
    address dacFactory;
    address founder;
    address dac;
    address mainToken;
    address agentToken;
    address dealManager;
    address treasuryToken;
    uint256 founderAllocation;
    uint256 founderCommitment;
    bool dividendsEnabled;
    bool usedMockTreasuryToken;
}

struct ExistingDACSeed {
    uint256 chainId;
    uint256 blockNumber;
    string label;
    address broadcaster;
    address founder;
    address dacFactory;
    address dac;
    address mainToken;
    address agentToken;
    address dealManager;
    address assetController;
    address underlyingToken;
    address governanceOracle;
    uint256 wrapAmount;
    uint256 treasurySeedAmount;
    bool dividendsEnabled;
    bool usedMockUnderlyingToken;
}

struct ExistingGovernanceFlowSeedConfig {
    string label;
    string existingDACLabel;
    uint256 agentMintAmount;
    uint256 merkleIndex;
    uint256 merkleAmountOverride;
}

struct ExistingGovernanceFlowSeed {
    uint256 chainId;
    uint256 blockNumber;
    string label;
    string existingDACLabel;
    address founder;
    address recipient;
    address dac;
    address mainToken;
    address agentToken;
    address underlyingToken;
    address governanceOracle;
    uint256 primaryProposalId;
    address primaryProposal;
    uint256 primarySnapshotBlock;
    bytes32 primaryMerkleRoot;
    uint256 primaryUnderlyingAmount;
    bool primaryPublished;
    bool primaryActivated;
    bool primaryVoted;
    bool primaryExecuted;
    uint256 fallbackProposalId;
    address fallbackProposal;
    uint256 fallbackSnapshotBlock;
    bool fallbackWarmupStarted;
    bool fallbackActivated;
    bool fallbackVoted;
    bool fallbackExecuted;
}

struct TreasuryFlowSeedConfig {
    string label;
    string basicDACLabel;
    uint256 agentMintAmount;
    uint256 stakeAmount;
    uint256 fundingAmount;
    uint256 rewardsLimit;
    uint256 expectedReturn;
    uint256 directSpendAmount;
    uint160 permit2SpendAmount;
    uint256 assignClaimAmount;
    uint160 agentSpendTotalAmount;
    uint160 agentSpendSingleTxAmount;
    uint256 agentSpendDuration;
}

struct ChildDACFlowSeedConfig {
    string label;
    string basicDACLabel;
    uint256 agentMintAmount;
    uint256 stakeAmount;
    uint256 fundingAmount;
    uint256 rewardsLimit;
    uint256 managedEquity;
    uint256 childMainTokenMaxSupply;
    uint256 childDefaultQuorum;
    uint256 childMintAgentAmount;
    uint256 childCapitalCallTokenAmount;
    uint256 childCapitalCallCashAmount;
    uint256 reinvestAmount;
    uint256 returnProfitAmount;
}

struct TreasuryFlowSeed {
    uint256 chainId;
    uint256 blockNumber;
    string label;
    string basicDACLabel;
    address founder;
    address agent;
    address recipient;
    address dac;
    address mainToken;
    address agentToken;
    address treasuryToken;
    uint256 dealId;
    address dealCell;
    address deal;
    address treasury;
    address evaluator;
    uint256 dacProposalId;
    uint256 mintAgentProposalId;
    uint256 directSpendProposalId;
    uint256 permit2ProposalId;
    uint256 assignClaimerProposalId;
    uint256 agentSpendProposalId;
    uint256 agentSpendExecutionAmount;
    bool agentMinted;
    bool dealApproved;
    bool actionProposalsCreated;
    bool actionProposalsExecuted;
}

struct ChildDACFlowSeed {
    uint256 chainId;
    uint256 blockNumber;
    string label;
    string basicDACLabel;
    address founder;
    address agent;
    address beneficiary;
    address dac;
    address mainToken;
    address agentToken;
    address treasuryToken;
    uint256 dealId;
    address dealCell;
    address deal;
    address evaluator;
    address childDac;
    address childMainToken;
    address childAgentToken;
    uint256 mintAgentProposalId;
    uint256 dacProposalId;
    uint256 childCreateProposalId;
    uint256 childProposalId;
    uint256 childVoteProposalId;
    uint256 capitalCallCreateProposalId;
    uint256 capitalCallProposalId;
    uint256 capitalCallVoteProposalId;
    uint256 reinvestProposalId;
    uint256 returnProfitProposalId;
    bytes32 childCapitalCallHash;
    bool agentMinted;
    bool dealApproved;
    bool childProposalCreated;
    bool childProposalExecuted;
    bool childCapitalCallCreated;
    bool childCapitalCallExecuted;
    bool reinvestExecuted;
    bool returnProfitExecuted;
}
