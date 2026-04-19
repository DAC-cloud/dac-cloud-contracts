#!/usr/bin/env bash
set -euo pipefail

# DAC Cloud — Full local seed sequence
#
# Prerequisites:
#   1. anvil running on 127.0.0.1:8545 (chain 31337)
#   2. PRIVATE_KEY exported (anvil default: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
#   3. forge build passes
#
# Usage:
#   chmod +x script/seed-all.sh
#   export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
#   ./script/seed-all.sh
#
# This script deploys the full protocol, seeds all scenario flows,
# and writes manifests under deployments/31337/.

RPC="${RPC_URL:-http://127.0.0.1:8545}"
FORGE_ARGS="--rpc-url $RPC --broadcast --skip-simulation --slow"

# Defaults — override via env if needed
export FOUNDER_PRIVATE_KEY="${FOUNDER_PRIVATE_KEY:-$PRIVATE_KEY}"
export AGENT_PRIVATE_KEY="${AGENT_PRIVATE_KEY:-$PRIVATE_KEY}"
export PERMIT2_ADDRESS="0x000000000022D473030F116dDEE9F6B43aC78BA3"

step() {
    echo ""
    echo "================================================================"
    echo "  $1"
    echo "================================================================"
}

tick() {
    # Advance anvil time by 1 second + mine a block
    cast rpc --rpc-url "$RPC" evm_increaseTime 1 > /dev/null 2>&1
    cast rpc --rpc-url "$RPC" evm_mine > /dev/null 2>&1
}

warp() {
    # Advance anvil time by N seconds + mine
    cast rpc --rpc-url "$RPC" evm_increaseTime "$1" > /dev/null 2>&1
    cast rpc --rpc-url "$RPC" evm_mine > /dev/null 2>&1
}

run_script() {
    local script_path="$1"
    local contract_name="$2"
    forge script "$script_path:$contract_name" $FORGE_ARGS
    tick
}

# ─── 0. Deploy Permit2 ───────────────────────────────────────────

step "Deploying Permit2"

PERMIT2_BYTECODE=$(cat script/bytecode/permit2-runtime.hex)
cast rpc anvil_setCode "$PERMIT2_ADDRESS" "$PERMIT2_BYTECODE" --rpc-url "$RPC"

echo "Permit2 deployed at: $PERMIT2_ADDRESS"

# ─── 1. Deploy protocol ──────────────────────────────────────────────

step "Deploying protocol"
run_script script/deploy/DeployProtocol.s.sol DeployProtocol

step "Smoke check"
forge script script/deploy/SmokeCheckProtocol.s.sol:SmokeCheckProtocol --rpc-url "$RPC"

step "Preflight check"
forge script script/deploy/PreflightProtocol.s.sol:PreflightProtocol --rpc-url "$RPC"

# ─── 2. Seed basic DAC ───────────────────────────────────────────────

step "Seeding basic DAC"
run_script script/scenarios/SeedBasicDAC.s.sol SeedBasicDAC

# ─── 3. Seed existing-token DAC ──────────────────────────────────────

step "Seeding existing-token DAC"
run_script script/scenarios/SeedExistingTokenDAC.s.sol SeedExistingTokenDAC

# ─── 4. Treasury flow (native DAC) ───────────────────────────────────

step "Treasury flow: create agent mint"
run_script script/scenarios/SeedTreasuryCreateAgentMint.s.sol SeedTreasuryCreateAgentMint

step "Treasury flow: execute agent mint"
run_script script/scenarios/SeedTreasuryExecuteAgentMint.s.sol SeedTreasuryExecuteAgentMint

step "Treasury flow: create deal"
run_script script/scenarios/SeedTreasuryCreateDeal.s.sol SeedTreasuryCreateDeal

step "Treasury flow: approve deal"
run_script script/scenarios/SeedTreasuryApproveDeal.s.sol SeedTreasuryApproveDeal

step "Treasury flow: create actions"
run_script script/scenarios/SeedTreasuryCreateActions.s.sol SeedTreasuryCreateActions

step "Treasury flow: execute actions"
warp 2  # agent spend cooldown
run_script script/scenarios/SeedTreasuryExecuteActions.s.sol SeedTreasuryExecuteActions

# ─── 5. Existing-token treasury flow ─────────────────────────────────

step "Existing treasury flow: create agent mint"
run_script script/scenarios/SeedExistingTreasuryCreateAgentMint.s.sol SeedExistingTreasuryCreateAgentMint

step "Existing treasury flow: publish agent mint"
run_script script/scenarios/SeedExistingTreasuryPublishAgentMint.s.sol SeedExistingTreasuryPublishAgentMint

step "Existing treasury flow: execute agent mint"
run_script script/scenarios/SeedExistingTreasuryExecuteAgentMint.s.sol SeedExistingTreasuryExecuteAgentMint

step "Existing treasury flow: create deal"
run_script script/scenarios/SeedExistingTreasuryCreateDeal.s.sol SeedExistingTreasuryCreateDeal

step "Existing treasury flow: publish approve deal"
run_script script/scenarios/SeedExistingTreasuryPublishApproveDeal.s.sol SeedExistingTreasuryPublishApproveDeal

step "Existing treasury flow: approve deal"
run_script script/scenarios/SeedExistingTreasuryApproveDeal.s.sol SeedExistingTreasuryApproveDeal

# ─── 6. Existing governance flow (primary) ────────────────────────────

step "Existing governance: create primary"
run_script script/scenarios/SeedExistingGovernanceCreatePrimary.s.sol SeedExistingGovernanceCreatePrimary

step "Existing governance: publish primary"
run_script script/scenarios/SeedExistingGovernancePublishPrimary.s.sol SeedExistingGovernancePublishPrimary

step "Existing governance: vote primary"
run_script script/scenarios/SeedExistingGovernanceVotePrimary.s.sol SeedExistingGovernanceVotePrimary

step "Existing governance: execute primary"
run_script script/scenarios/SeedExistingGovernanceExecutePrimary.s.sol SeedExistingGovernanceExecutePrimary

# ─── 7. Existing governance flow (fallback) ───────────────────────────

step "Existing governance: create fallback"
run_script script/scenarios/SeedExistingGovernanceCreateFallback.s.sol SeedExistingGovernanceCreateFallback

step "Existing governance: begin fallback warmup"
warp 86400  # wait for oracle deadline to pass
run_script script/scenarios/SeedExistingGovernanceBeginFallbackWarmup.s.sol SeedExistingGovernanceBeginFallbackWarmup

step "Existing governance: activate fallback"
warp 86400  # wait for warmup to end
run_script script/scenarios/SeedExistingGovernanceActivateFallback.s.sol SeedExistingGovernanceActivateFallback

step "Existing governance: vote fallback"
run_script script/scenarios/SeedExistingGovernanceVoteFallback.s.sol SeedExistingGovernanceVoteFallback

step "Existing governance: execute fallback"
run_script script/scenarios/SeedExistingGovernanceExecuteFallback.s.sol SeedExistingGovernanceExecuteFallback

# ─── 8. Child DAC flow ────────────────────────────────────────────────

step "Child DAC flow: create agent mint"
run_script script/scenarios/SeedChildDACCreateAgentMint.s.sol SeedChildDACCreateAgentMint

step "Child DAC flow: execute agent mint"
run_script script/scenarios/SeedChildDACExecuteAgentMint.s.sol SeedChildDACExecuteAgentMint

step "Child DAC flow: create deal"
run_script script/scenarios/SeedChildDACCreateDeal.s.sol SeedChildDACCreateDeal

step "Child DAC flow: approve deal"
run_script script/scenarios/SeedChildDACApproveDeal.s.sol SeedChildDACApproveDeal

step "Child DAC flow: create child proposal"
run_script script/scenarios/SeedChildDACCreateChildProposal.s.sol SeedChildDACCreateChildProposal

step "Child DAC flow: execute child proposal create"
run_script script/scenarios/SeedChildDACExecuteChildProposalCreate.s.sol SeedChildDACExecuteChildProposalCreate

step "Child DAC flow: execute child proposal vote"
run_script script/scenarios/SeedChildDACExecuteChildProposalVote.s.sol SeedChildDACExecuteChildProposalVote

step "Child DAC flow: create capital call proposal"
run_script script/scenarios/SeedChildDACCreateCapitalCallProposal.s.sol SeedChildDACCreateCapitalCallProposal

step "Child DAC flow: execute capital call create"
run_script script/scenarios/SeedChildDACExecuteCapitalCallCreate.s.sol SeedChildDACExecuteCapitalCallCreate

step "Child DAC flow: execute capital call vote"
run_script script/scenarios/SeedChildDACExecuteCapitalCallVote.s.sol SeedChildDACExecuteCapitalCallVote

step "Child DAC flow: create reinvest proposal"
run_script script/scenarios/SeedChildDACCreateReinvestProposal.s.sol SeedChildDACCreateReinvestProposal

step "Child DAC flow: execute reinvest proposal"
run_script script/scenarios/SeedChildDACExecuteReinvestProposal.s.sol SeedChildDACExecuteReinvestProposal

step "Child DAC flow: create return profits proposal"
run_script script/scenarios/SeedChildDACCreateReturnProfitsProposal.s.sol SeedChildDACCreateReturnProfitsProposal

step "Child DAC flow: execute return profits proposal"
run_script script/scenarios/SeedChildDACExecuteReturnProfitsProposal.s.sol SeedChildDACExecuteReturnProfitsProposal

# ─── Done ─────────────────────────────────────────────────────────────

step "All seeds complete"
echo ""
echo "Manifests written to: deployments/31337/"
ls -la deployments/31337/*.json 2>/dev/null || echo "(no manifests found)"
echo ""
echo "Anvil is seeded and ready for indexer verification."
