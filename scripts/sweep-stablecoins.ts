#!/usr/bin/env npx tsx
/**
 * @deprecated Use `crypto-sweep` from @wopr-network/crypto-plugins instead.
 *
 * Install: pnpm add -g @wopr-network/crypto-plugins
 * Usage:   openssl enc ... | CRYPTO_SERVICE_URL=... crypto-sweep
 *
 * The unified CLI handles all chains (EVM, Tron, UTXO, Solana) automatically
 * by reading chain config from the chain server. No per-chain env vars needed.
 *
 * ---
 *
 * LEGACY: Crypto sweep tool — consolidates ETH + ERC-20s from deposit addresses to treasury.
 *
 * RUNS LOCALLY ONLY. Never on the server. Handles private keys.
 *
 * Usage:
 *   openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -pass pass:<passphrase> \
 *     -in "/mnt/g/My Drive/paperclip-wallet.enc" \
 *     | CRYPTO_SERVICE_URL=http://167.71.118.221:3100 \
 *       CRYPTO_SERVICE_KEY=sk-chain-2026 \
 *       EVM_RPC=https://ethereum-sepolia-rpc.publicnode.com \
 *       EVM_CHAIN=sepolia \
 *       npx tsx scripts/sweep-stablecoins.ts
 */
console.warn("⚠️  DEPRECATED: Use `crypto-sweep` from @wopr-network/crypto-plugins instead.");

import { HDKey } from "@scure/bip32";
import * as bip39 from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import {
	createPublicClient,
	createWalletClient,
	defineChain,
	formatEther,
	formatUnits,
	http,
	type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// --- Config ---

const CRYPTO_SERVICE_URL = process.env.CRYPTO_SERVICE_URL;
const CRYPTO_SERVICE_KEY = process.env.CRYPTO_SERVICE_KEY;
const RPC_URL = process.env.EVM_RPC ?? process.env.EVM_RPC_BASE;
const CHAIN_ID = process.env.EVM_CHAIN;
const DRY_RUN = process.env.SWEEP_DRY_RUN !== "false";
const MAX_INDEX = Number(process.env.MAX_ADDRESSES ?? "200");

if (!CRYPTO_SERVICE_URL) {
	console.error("CRYPTO_SERVICE_URL is required");
	process.exit(1);
}
if (!RPC_URL) {
	console.error("EVM_RPC is required");
	process.exit(1);
}
if (!CHAIN_ID) {
	console.error("EVM_CHAIN is required (e.g. 'base', 'sepolia')");
	process.exit(1);
}

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

// --- Fetch tokens from chain server ---

interface ChainToken {
	id: string;
	token: string;
	chain: string;
	decimals: number;
	contractAddress: string | null;
	displayName: string;
}

async function fetchTokens(): Promise<Array<{ name: string; address: Address; decimals: number }>> {
	const headers: Record<string, string> = { "Content-Type": "application/json" };
	if (CRYPTO_SERVICE_KEY) headers.Authorization = `Bearer ${CRYPTO_SERVICE_KEY}`;

	const res = await fetch(`${CRYPTO_SERVICE_URL}/chains`, { headers });
	if (!res.ok) throw new Error(`Chain server returned ${res.status}`);

	const chains: ChainToken[] = await res.json();

	// Filter to ERC-20 tokens on the target chain (have a contractAddress)
	return chains
		.filter((c) => c.chain === CHAIN_ID && c.contractAddress)
		.map((c) => ({
			name: c.token,
			address: c.contractAddress as Address,
			decimals: c.decimals,
		}));
}

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

	// Fetch tokens from chain server
	console.log(`Fetching tokens from ${CRYPTO_SERVICE_URL} (chain: ${CHAIN_ID})...`);
	const TOKENS = await fetchTokens();
	console.log(`Found ${TOKENS.length} ERC-20 tokens: ${TOKENS.map((t) => t.name).join(", ") || "(none — ETH only)"}`);

	const seed = bip39.mnemonicToSeedSync(mnemonic);
	const master = HDKey.fromMasterSeed(seed);
	const evmAccount = master.derive("m/44'/60'/0'");

	// Treasury = internal chain (1), index 0
	const treasuryAddress = deriveAddress(evmAccount, 1, 0);
	const treasuryPrivKey = derivePrivateKey(evmAccount, 1, 0);
	const treasuryAccount = privateKeyToAccount(treasuryPrivKey);

	// Use a generic chain definition so we can sweep any EVM chain
	const chain = defineChain({
		id: 1,
		name: CHAIN_ID,
		nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
		rpcUrls: { default: { http: [RPC_URL!] } },
	});

	console.log(`\nTreasury: ${treasuryAddress}`);
	console.log(`RPC: ${RPC_URL}`);
	console.log(`Chain: ${CHAIN_ID}`);
	console.log(`Dry run: ${DRY_RUN}`);
	console.log(`Scanning ${MAX_INDEX} deposit addresses...\n`);

	const publicClient = createPublicClient({ chain, transport: http(RPC_URL) });
	const walletClient = createWalletClient({
		chain,
		transport: http(RPC_URL),
		account: treasuryAccount,
	});

	const gasPrice = await publicClient.getGasPrice();
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
			try {
				const balance = await publicClient.readContract({
					address: token.address,
					abi: ERC20_ABI,
					functionName: "balanceOf",
					args: [addr],
				});
				if (balance > 0n) {
					tokenBalances.push({ ...token, balance });
				}
			} catch {
				// Contract may not exist on this chain — skip silently
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
	if (ethDeposits.length > 0) {
		console.log("\n--- Phase 1: Sweeping ETH to treasury (self-funded gas) ---");
		for (const dep of ethDeposits) {
			const depPrivKey = derivePrivateKey(evmAccount, 0, dep.index);
			const depAccount = privateKeyToAccount(depPrivKey);
			const depWallet = createWalletClient({
				chain,
				transport: http(RPC_URL),
				account: depAccount,
			});

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
	// Phase 3: Fund gas + sweep ERC-20s
	// ============================================================
	if (tokenDeposits.length > 0) {
		const treasuryEth = await publicClient.getBalance({ address: treasuryAddress });
		const totalGasNeeded =
			erc20TransferGas * BigInt(tokenDeposits.reduce((n, d) => n + d.tokenBalances.length, 0));

		console.log("\n--- Phase 2: Funding gas for ERC-20 sweeps ---");
		console.log(`Treasury ETH: ${formatEther(treasuryEth)}, gas needed: ${formatEther(totalGasNeeded)}`);

		if (treasuryEth < totalGasNeeded) {
			console.error(
				`Insufficient treasury ETH for gas. Need ${formatEther(totalGasNeeded)}, have ${formatEther(treasuryEth)}.`,
			);
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

		console.log("\n--- Phase 3: Sweeping ERC-20s to treasury ---");
		for (const dep of tokenDeposits) {
			const depPrivKey = derivePrivateKey(evmAccount, 0, dep.index);
			const depAccount = privateKeyToAccount(depPrivKey);
			const depWallet = createWalletClient({
				chain,
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
		try {
			const bal = await publicClient.readContract({
				address: token.address,
				abi: ERC20_ABI,
				functionName: "balanceOf",
				args: [treasuryAddress],
			});
			if (bal > 0n) console.log(`  ${token.name}: ${formatUnits(bal, token.decimals)}`);
		} catch {
			// skip
		}
	}
	console.log("\nDone.");
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
