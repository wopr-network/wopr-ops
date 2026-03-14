#!/usr/bin/env npx tsx
/**
 * Stablecoin sweep tool — consolidates funds from HD-derived deposit addresses to treasury.
 *
 * RUNS LOCALLY ONLY. Never on the server. Handles private keys.
 *
 * Usage:
 *   openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -pass pass:<passphrase> \
 *     -in "/mnt/g/My Drive/paperclip-wallet.enc" | npx tsx scripts/sweep-stablecoins.ts
 *
 * Or interactively:
 *   npx tsx scripts/sweep-stablecoins.ts
 *   (paste mnemonic, press Ctrl+D)
 *
 * Env vars:
 *   EVM_RPC_BASE    — Base node RPC URL (default: http://localhost:8545)
 *   SWEEP_DRY_RUN   — set to "false" to actually broadcast (default: true)
 */

import { HDKey } from "@scure/bip32";
import * as bip39 from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import {
  createPublicClient,
  createWalletClient,
  formatEther,
  formatUnits,
  http,
  parseEther,
  type Address,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

// --- Config ---

const RPC_URL = process.env.EVM_RPC_BASE ?? "http://localhost:8545";
const DRY_RUN = process.env.SWEEP_DRY_RUN !== "false";
const MAX_INDEX = 200; // scan up to 200 deposit addresses

// USDC on Base
const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address;
const USDC_DECIMALS = 6;

// ERC-20 balanceOf + transfer ABI (minimal)
const ERC20_ABI = [
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "transfer",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

// --- Helpers ---

function derivePrivateKey(master: HDKey, chainIndex: number, addressIndex: number): `0x${string}` {
  const child = master.deriveChild(chainIndex).deriveChild(addressIndex);
  if (!child.privateKey) throw new Error(`No private key at ${chainIndex}/${addressIndex}`);
  return `0x${Array.from(child.privateKey, (b) => b.toString(16).padStart(2, "0")).join("")}` as `0x${string}`;
}

function deriveAddress(master: HDKey, chainIndex: number, addressIndex: number): Address {
  const privKey = derivePrivateKey(master, chainIndex, addressIndex);
  return privateKeyToAccount(privKey).address;
}

// --- Main ---

async function main() {
  // Read mnemonic from stdin
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  const mnemonic = Buffer.concat(chunks).toString("utf-8").trim();

  if (!bip39.validateMnemonic(mnemonic, wordlist)) {
    console.error("Invalid mnemonic");
    process.exit(1);
  }

  const seed = bip39.mnemonicToSeedSync(mnemonic);
  const master = HDKey.fromMasterSeed(seed);
  const evmAccount = master.derive("m/44'/60'/0'");

  // Treasury = internal chain (1), index 0
  const treasuryAddress = deriveAddress(evmAccount, 1, 0);
  const treasuryPrivKey = derivePrivateKey(evmAccount, 1, 0);
  const treasuryAccount = privateKeyToAccount(treasuryPrivKey);

  console.log(`Treasury: ${treasuryAddress}`);
  console.log(`RPC: ${RPC_URL}`);
  console.log(`Dry run: ${DRY_RUN}`);
  console.log(`Scanning ${MAX_INDEX} deposit addresses...\n`);

  const publicClient = createPublicClient({ chain: base, transport: http(RPC_URL) });
  const walletClient = createWalletClient({
    chain: base,
    transport: http(RPC_URL),
    account: treasuryAccount,
  });

  // Check treasury ETH balance (needed for gas funding)
  const treasuryEth = await publicClient.getBalance({ address: treasuryAddress });
  console.log(`Treasury ETH balance: ${formatEther(treasuryEth)}`);

  // Scan deposit addresses for USDC balances
  const deposits: Array<{ index: number; address: Address; balance: bigint }> = [];

  for (let i = 0; i < MAX_INDEX; i++) {
    const addr = deriveAddress(evmAccount, 0, i);
    const balance = await publicClient.readContract({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [addr],
    });

    if (balance > 0n) {
      console.log(`  [${i}] ${addr}: ${formatUnits(balance, USDC_DECIMALS)} USDC`);
      deposits.push({ index: i, address: addr, balance });
    }
  }

  if (deposits.length === 0) {
    console.log("\nNo deposit addresses with USDC balances. Nothing to sweep.");
    return;
  }

  const totalUsdc = deposits.reduce((sum, d) => sum + d.balance, 0n);
  console.log(`\nFound ${deposits.length} addresses with ${formatUnits(totalUsdc, USDC_DECIMALS)} USDC total.`);

  if (DRY_RUN) {
    console.log("\nDry run — no transactions broadcast. Set SWEEP_DRY_RUN=false to sweep.");
    return;
  }

  // Estimate gas needed per sweep (~65k gas for ERC-20 transfer)
  const gasPerSweep = 65_000n;
  const gasPrice = await publicClient.getGasPrice();
  const ethPerSweep = gasPerSweep * gasPrice;
  const totalEthNeeded = ethPerSweep * BigInt(deposits.length);

  console.log(`\nGas estimate: ${formatEther(ethPerSweep)} ETH per sweep, ${formatEther(totalEthNeeded)} ETH total`);

  if (treasuryEth < totalEthNeeded) {
    console.error(`\nInsufficient treasury ETH. Need ${formatEther(totalEthNeeded)}, have ${formatEther(treasuryEth)}.`);
    console.error("Fund the treasury with ETH first, then re-run.");
    process.exit(1);
  }

  // Step 1: Fund each deposit address with gas
  console.log("\n--- Funding deposit addresses with gas ---");
  for (const dep of deposits) {
    const depEth = await publicClient.getBalance({ address: dep.address });
    if (depEth >= ethPerSweep) {
      console.log(`  [${dep.index}] Already has gas, skipping`);
      continue;
    }

    const hash = await walletClient.sendTransaction({
      to: dep.address,
      value: ethPerSweep,
    });
    console.log(`  [${dep.index}] Funded: ${hash}`);

    // Wait for confirmation
    await publicClient.waitForTransactionReceipt({ hash });
  }

  // Step 2: Sweep USDC from each deposit address to treasury
  console.log("\n--- Sweeping USDC to treasury ---");
  for (const dep of deposits) {
    const depPrivKey = derivePrivateKey(evmAccount, 0, dep.index);
    const depAccount = privateKeyToAccount(depPrivKey);
    const depWallet = createWalletClient({
      chain: base,
      transport: http(RPC_URL),
      account: depAccount,
    });

    const hash = await depWallet.writeContract({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: "transfer",
      args: [treasuryAddress, dep.balance],
    });
    console.log(`  [${dep.index}] Swept ${formatUnits(dep.balance, USDC_DECIMALS)} USDC: ${hash}`);

    await publicClient.waitForTransactionReceipt({ hash });
  }

  // Final balance
  const finalBalance = await publicClient.readContract({
    address: USDC_ADDRESS,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [treasuryAddress],
  });
  console.log(`\nDone. Treasury USDC balance: ${formatUnits(finalBalance, USDC_DECIMALS)}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
