#!/usr/bin/env npx tsx
/**
 * Crypto sweep tool — consolidates ETH + stablecoins from deposit addresses to treasury.
 *
 * RUNS LOCALLY ONLY. Never on the server. Handles private keys.
 *
 * Order matters (chicken-and-egg):
 *   1. Sweep ETH first — deposit addresses self-fund gas, treasury receives ETH
 *   2. Fund gas — treasury sends ETH to stablecoin deposit addresses
 *   3. Sweep stablecoins — deposit addresses send USDC/USDT/DAI to treasury
 *
 * Without step 1, the treasury may have no ETH to fund gas for step 2.
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

// Stablecoins on Base
const TOKENS: Array<{ name: string; address: Address; decimals: number }> = [
  { name: "USDC", address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6 },
  { name: "USDT", address: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2", decimals: 6 },
  { name: "DAI", address: "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb", decimals: 18 },
];

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

  const gasPrice = await publicClient.getGasPrice();
  // ~21k gas for native ETH transfer, ~65k for ERC-20 transfer
  const ethTransferGas = 21_000n * gasPrice;
  const erc20TransferGas = 65_000n * gasPrice;

  // ============================================================
  // Phase 1: Scan all deposit addresses for ETH + token balances
  // ============================================================
  console.log("--- Scanning deposit addresses ---");

  type DepositInfo = {
    index: number;
    address: Address;
    ethBalance: bigint;
    tokenBalances: Array<{ name: string; address: Address; decimals: number; balance: bigint }>;
  };

  const deposits: DepositInfo[] = [];

  for (let i = 0; i < MAX_INDEX; i++) {
    const addr = deriveAddress(evmAccount, 0, i);
    const ethBalance = await publicClient.getBalance({ address: addr });

    const tokenBalances: DepositInfo["tokenBalances"] = [];
    for (const token of TOKENS) {
      const balance = await publicClient.readContract({
        address: token.address,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [addr],
      });
      if (balance > 0n) {
        tokenBalances.push({ ...token, balance });
      }
    }

    if (ethBalance > 0n || tokenBalances.length > 0) {
      const parts = [`${formatEther(ethBalance)} ETH`];
      for (const t of tokenBalances) parts.push(`${formatUnits(t.balance, t.decimals)} ${t.name}`);
      console.log(`  [${i}] ${addr}: ${parts.join(", ")}`);
      deposits.push({ index: i, address: addr, ethBalance, tokenBalances });
    }
  }

  if (deposits.length === 0) {
    console.log("\nNo deposit addresses with balances. Nothing to sweep.");
    return;
  }

  const ethDeposits = deposits.filter((d) => d.ethBalance > ethTransferGas);
  const tokenDeposits = deposits.filter((d) => d.tokenBalances.length > 0);
  const totalEth = ethDeposits.reduce((sum, d) => sum + d.ethBalance, 0n);

  console.log(`\nFound: ${ethDeposits.length} ETH deposits (${formatEther(totalEth)} ETH)`);
  for (const token of TOKENS) {
    const total = tokenDeposits.reduce(
      (sum, d) => sum + (d.tokenBalances.find((t) => t.name === token.name)?.balance ?? 0n),
      0n,
    );
    if (total > 0n) console.log(`       ${formatUnits(total, token.decimals)} ${token.name}`);
  }

  if (DRY_RUN) {
    console.log("\nDry run — no transactions broadcast. Set SWEEP_DRY_RUN=false to sweep.");
    return;
  }

  // ============================================================
  // Phase 2: Sweep ETH FIRST (self-funded gas → fills treasury)
  // ============================================================
  // This MUST run before stablecoin sweep. Treasury may be empty —
  // ETH deposits self-fund their own gas, so this always works.
  // After this phase, treasury has ETH to fund gas for Phase 3.

  if (ethDeposits.length > 0) {
    console.log("\n--- Phase 1: Sweeping ETH to treasury (self-funded gas) ---");
    for (const dep of ethDeposits) {
      const depPrivKey = derivePrivateKey(evmAccount, 0, dep.index);
      const depAccount = privateKeyToAccount(depPrivKey);
      const depWallet = createWalletClient({
        chain: base,
        transport: http(RPC_URL),
        account: depAccount,
      });

      // Send balance minus gas cost — the deposit pays its own gas
      const sweepAmount = dep.ethBalance - ethTransferGas;
      if (sweepAmount <= 0n) {
        console.log(`  [${dep.index}] Balance too low to cover gas, skipping`);
        continue;
      }

      const hash = await depWallet.sendTransaction({
        to: treasuryAddress,
        value: sweepAmount,
      });
      console.log(`  [${dep.index}] Swept ${formatEther(sweepAmount)} ETH: ${hash}`);
      await publicClient.waitForTransactionReceipt({ hash });
    }
  }

  // ============================================================
  // Phase 3: Fund gas + sweep stablecoins
  // ============================================================
  // Treasury now has ETH (from Phase 2 + any prior balance).

  if (tokenDeposits.length > 0) {
    const treasuryEth = await publicClient.getBalance({ address: treasuryAddress });
    const totalGasNeeded = erc20TransferGas * BigInt(
      tokenDeposits.reduce((n, d) => n + d.tokenBalances.length, 0),
    );

    console.log(`\n--- Phase 2: Funding gas for stablecoin sweeps ---`);
    console.log(`Treasury ETH: ${formatEther(treasuryEth)}, gas needed: ${formatEther(totalGasNeeded)}`);

    if (treasuryEth < totalGasNeeded) {
      console.error(`Insufficient treasury ETH for gas. Need ${formatEther(totalGasNeeded)}, have ${formatEther(treasuryEth)}.`);
      console.error("Sweep more ETH deposits or manually fund the treasury.");
      process.exit(1);
    }

    for (const dep of tokenDeposits) {
      const depEth = await publicClient.getBalance({ address: dep.address });
      const needed = erc20TransferGas * BigInt(dep.tokenBalances.length);
      if (depEth >= needed) {
        console.log(`  [${dep.index}] Already has gas, skipping`);
        continue;
      }

      const hash = await walletClient.sendTransaction({
        to: dep.address,
        value: needed - depEth,
      });
      console.log(`  [${dep.index}] Funded ${formatEther(needed - depEth)} ETH: ${hash}`);
      await publicClient.waitForTransactionReceipt({ hash });
    }

    console.log("\n--- Phase 3: Sweeping stablecoins to treasury ---");
    for (const dep of tokenDeposits) {
      const depPrivKey = derivePrivateKey(evmAccount, 0, dep.index);
      const depAccount = privateKeyToAccount(depPrivKey);
      const depWallet = createWalletClient({
        chain: base,
        transport: http(RPC_URL),
        account: depAccount,
      });

      for (const token of dep.tokenBalances) {
        const hash = await depWallet.writeContract({
          address: token.address,
          abi: ERC20_ABI,
          functionName: "transfer",
          args: [treasuryAddress, token.balance],
        });
        console.log(`  [${dep.index}] Swept ${formatUnits(token.balance, token.decimals)} ${token.name}: ${hash}`);
        await publicClient.waitForTransactionReceipt({ hash });
      }
    }
  }

  // ============================================================
  // Summary
  // ============================================================
  console.log("\n--- Final treasury balances ---");
  const finalEth = await publicClient.getBalance({ address: treasuryAddress });
  console.log(`  ETH: ${formatEther(finalEth)}`);
  for (const token of TOKENS) {
    const bal = await publicClient.readContract({
      address: token.address,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [treasuryAddress],
    });
    if (bal > 0n) console.log(`  ${token.name}: ${formatUnits(bal, token.decimals)}`);
  }
  console.log("\nDone.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
