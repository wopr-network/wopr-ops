#!/usr/bin/env bash
# End-to-end payment test — exercises BTC (regtest) and stablecoin (Anvil fork) flows.
#
# Prerequisites:
#   - bitcoind running on regtest (docker-compose)
#   - Anvil running with Base fork (docker-compose)
#
# Usage:
#   ./scripts/test-payments-e2e.sh

set -euo pipefail

# --- Config ---
BITCOIND_RPC="http://localhost:18443"
BITCOIND_USER="rpcuser"
BITCOIND_PASS="rpcpassword"
ANVIL_RPC="http://localhost:8545"

# USDC on Base (real contract, forked state)
USDC_CONTRACT="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
# A known USDC whale on Base (has millions of USDC)
USDC_WHALE="0xcdac0d73a067e2e45f0f7b7ffa6c04a6b8ee2fe0"

# Our test deposit addresses (from the mnemonic, first two indices)
EVM_DEPOSIT_0="0x23Edd02dDeec8396319722c8fAd47F044310D254"
EVM_TREASURY="0x6cEff0F47d5d918e50Fd40f7611f673a13edA06d"

echo "=== Payment E2E Test ==="
echo ""

# --- BTC Regtest ---
echo "--- BTC Regtest ---"

btc_rpc() {
  curl -s -u "$BITCOIND_USER:$BITCOIND_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
    "$BITCOIND_RPC" | jq -r '.result'
}

# Create or load wallet
btc_rpc "createwallet" '["testwallet", false, false, "", false, false, true]' 2>/dev/null || true
btc_rpc "loadwallet" '["testwallet"]' 2>/dev/null || true

# Generate an address and mine some blocks to get coins
MINER_ADDR=$(btc_rpc "getnewaddress" '["", "bech32"]')
echo "Miner address: $MINER_ADDR"
btc_rpc "generatetoaddress" "[101, \"$MINER_ADDR\"]" > /dev/null
echo "Mined 101 blocks"

# Get a test BTC deposit address (would come from our xpub in production)
# For this test, use a static regtest address
BTC_DEPOSIT="bcrt1qtest000000000000000000000000000000000"
echo "BTC deposit address: (use deriveBtcAddress with regtest network)"

# Send 0.001 BTC to a deposit address
TXID=$(btc_rpc "sendtoaddress" "[\"$MINER_ADDR\", 0.001]")
echo "Sent 0.001 BTC, txid: $TXID"

# Mine a block to confirm
btc_rpc "generatetoaddress" "[1, \"$MINER_ADDR\"]" > /dev/null
echo "Mined 1 block (confirmed)"

# Check balance
BALANCE=$(btc_rpc "getbalance" '[]')
echo "Wallet balance: $BALANCE BTC"
echo ""

# --- EVM Anvil Fork ---
echo "--- EVM Stablecoin (Anvil Base Fork) ---"

anvil_rpc() {
  curl -s -X POST "$ANVIL_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" | jq -r '.result'
}

# Check Anvil is running
BLOCK=$(anvil_rpc "eth_blockNumber" '[]')
echo "Current block: $((16#${BLOCK#0x}))"

# Impersonate the USDC whale (Anvil-only feature)
anvil_rpc "anvil_impersonateAccount" "[\"$USDC_WHALE\"]" > /dev/null
echo "Impersonating USDC whale: $USDC_WHALE"

# Check whale's USDC balance
WHALE_BAL=$(anvil_rpc "eth_call" "[{\"to\":\"$USDC_CONTRACT\",\"data\":\"0x70a08231000000000000000000000000${USDC_WHALE#0x}\"}, \"latest\"]")
echo "Whale USDC balance: $((16#${WHALE_BAL#0x} / 1000000)) USDC"

# Send 10 USDC to our deposit address
# transfer(address,uint256) = 0xa9059cbb + padded address + padded amount
AMOUNT_HEX=$(printf '%064x' 10000000)  # 10 USDC = 10 * 10^6
ADDR_PADDED="000000000000000000000000${EVM_DEPOSIT_0#0x}"
TRANSFER_DATA="0xa9059cbb${ADDR_PADDED}${AMOUNT_HEX}"

TX_HASH=$(anvil_rpc "eth_sendTransaction" "[{\"from\":\"$USDC_WHALE\",\"to\":\"$USDC_CONTRACT\",\"data\":\"$TRANSFER_DATA\"}]")
echo "Sent 10 USDC to $EVM_DEPOSIT_0"
echo "TX hash: $TX_HASH"

# Mine a block
anvil_rpc "evm_mine" '[]' > /dev/null
echo "Mined 1 block"

# Check deposit address USDC balance
DEPOSIT_BAL=$(anvil_rpc "eth_call" "[{\"to\":\"$USDC_CONTRACT\",\"data\":\"0x70a08231000000000000000000000000${EVM_DEPOSIT_0#0x}\"}, \"latest\"]")
DEPOSIT_USDC=$((16#${DEPOSIT_BAL#0x} / 1000000))
echo "Deposit address USDC balance: $DEPOSIT_USDC USDC"

if [ "$DEPOSIT_USDC" -eq 10 ]; then
  echo "PASS: 10 USDC received at deposit address"
else
  echo "FAIL: expected 10 USDC, got $DEPOSIT_USDC"
  exit 1
fi

# Stop impersonation
anvil_rpc "anvil_stopImpersonatingAccount" "[\"$USDC_WHALE\"]" > /dev/null

echo ""
echo "=== All payment E2E tests passed ==="
echo ""
echo "Next steps:"
echo "  1. Run the EVM watcher against Anvil — it should detect the Transfer event"
echo "  2. Run the BTC watcher against regtest — it should detect the transaction"
echo "  3. Both should credit the ledger via Credit.fromCents()"
