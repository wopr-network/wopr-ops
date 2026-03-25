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
 * LEGACY: Tron sweep tool — consolidates TRX + TRC-20s from deposit addresses to treasury.
 *
 * RUNS LOCALLY ONLY. Never on the server. Handles private keys.
 *
 * Usage:
 *   openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -pass pass:<passphrase> \
 *     -in "/mnt/g/My Drive/paperclip-wallet.enc" \
 *     | CRYPTO_SERVICE_URL=http://167.71.118.221:3100 \
 *       CRYPTO_SERVICE_KEY=sk-chain-2026 \
 *       TRON_RPC=https://api.trongrid.io \
 *       npx tsx scripts/sweep-tron.ts
 */
console.warn("⚠️  DEPRECATED: Use `crypto-sweep` from @wopr-network/crypto-plugins instead.");

import { HDKey } from "@scure/bip32";
import * as bip39 from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { createRequire } from "node:module";
import { sha256 } from "@noble/hashes/sha2.js";
import { keccak_256 } from "@noble/hashes/sha3.js";

// Use noble/curves v1 bundled with viem (has ProjectivePoint, recovery, toCompactRawBytes)
const require2 = createRequire(import.meta.url);
const viemDir = require2.resolve("viem/package.json").replace("/package.json", "");
const { secp256k1: sec } = require2(`${viemDir}/node_modules/@noble/curves/secp256k1.js`) as {
	secp256k1: {
		ProjectivePoint: { fromHex(hex: string): { toRawBytes(compressed: boolean): Uint8Array } };
		sign(msg: Uint8Array, privKey: Uint8Array, opts?: { lowS: boolean }): {
			toCompactRawBytes(): Uint8Array;
			recovery: number;
		};
		getPublicKey(privKey: Uint8Array, compressed?: boolean): Uint8Array;
	};
};

// --- Config ---

const CRYPTO_SERVICE_URL = process.env.CRYPTO_SERVICE_URL;
const CRYPTO_SERVICE_KEY = process.env.CRYPTO_SERVICE_KEY;
const TRON_RPC = process.env.TRON_RPC;
const TRON_API_KEY = process.env.TRON_API_KEY;
const DRY_RUN = process.env.SWEEP_DRY_RUN !== "false";
const MAX_INDEX = Number(process.env.MAX_ADDRESSES ?? "200");

// TRX has 6 decimals (1 TRX = 1,000,000 SUN)
const SUN_PER_TRX = 1_000_000n;
// Min TRX to keep for a transfer (~1 TRX covers bandwidth for simple transfer)
const TRX_TRANSFER_COST = 1_100_000n; // 1.1 TRX in SUN
// Energy needed for TRC-20 transfer (~30,000 energy ≈ 14 TRX if no free bandwidth)
const TRC20_ENERGY_COST = 15_000_000n; // 15 TRX in SUN (conservative)

if (!CRYPTO_SERVICE_URL) { console.error("CRYPTO_SERVICE_URL is required"); process.exit(1); }
if (!TRON_RPC) { console.error("TRON_RPC is required (e.g. https://api.trongrid.io)"); process.exit(1); }

// --- Base58 / Address encoding ---

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function base58encode(data: Uint8Array): string {
	let num = 0n;
	for (const byte of data) num = num * 256n + BigInt(byte);
	let encoded = "";
	while (num > 0n) {
		encoded = BASE58_ALPHABET[Number(num % 58n)] + encoded;
		num = num / 58n;
	}
	for (const byte of data) {
		if (byte !== 0) break;
		encoded = `1${encoded}`;
	}
	return encoded;
}

function base58decode(str: string): Uint8Array {
	let num = 0n;
	for (const ch of str) {
		const idx = BASE58_ALPHABET.indexOf(ch);
		if (idx < 0) throw new Error(`Invalid Base58 char: ${ch}`);
		num = num * 58n + BigInt(idx);
	}
	const hex = num.toString(16).padStart(50, "0"); // 25 bytes = 50 hex chars
	const bytes = new Uint8Array(hex.match(/.{2}/g)!.map((h) => Number.parseInt(h, 16)));
	// Restore leading zeros
	let leadingZeros = 0;
	for (const ch of str) {
		if (ch !== "1") break;
		leadingZeros++;
	}
	const result = new Uint8Array(leadingZeros + bytes.length);
	result.set(bytes, leadingZeros);
	return result;
}

function toHex(data: Uint8Array): string {
	return Array.from(data, (b) => b.toString(16).padStart(2, "0")).join("");
}

function fromHex(hex: string): Uint8Array {
	const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
	return new Uint8Array(clean.match(/.{2}/g)!.map((h) => Number.parseInt(h, 16)));
}

/** Derive T-address from compressed public key */
function pubkeyToTronAddress(pubkey: Uint8Array): string {
	// Decompress: get uncompressed (65-byte, 04-prefixed) from compressed (33-byte)
	const uncompressed: Uint8Array = sec.ProjectivePoint.fromHex(toHex(pubkey)).toRawBytes(false);
	// Keccak256 of uncompressed key (without 04 prefix) — last 20 bytes
	// Tron uses keccak256 like Ethereum for address derivation
	const hash = keccak_256(uncompressed.slice(1));
	const addressBytes = hash.slice(-20);
	// Add 0x41 prefix + Base58Check
	const payload = new Uint8Array(21);
	payload[0] = 0x41;
	payload.set(addressBytes, 1);
	const checksum = sha256(sha256(payload));
	const full = new Uint8Array(25);
	full.set(payload);
	full.set(checksum.slice(0, 4), 21);
	return base58encode(full);
}

/** Convert T-address to hex (41-prefixed, no 0x) */
function tronAddressToHex(tAddr: string): string {
	const decoded = base58decode(tAddr);
	return toHex(decoded.slice(0, 21)); // drop 4-byte checksum
}

function formatTrx(sun: bigint): string {
	const whole = sun / SUN_PER_TRX;
	const frac = sun % SUN_PER_TRX;
	if (frac === 0n) return `${whole}`;
	return `${whole}.${frac.toString().padStart(6, "0").replace(/0+$/, "")}`;
}

// --- Tron RPC helpers ---

function tronHeaders(): Record<string, string> {
	const h: Record<string, string> = { "Content-Type": "application/json" };
	if (TRON_API_KEY) h["TRON-PRO-API-KEY"] = TRON_API_KEY;
	return h;
}

async function tronPost(path: string, body: Record<string, unknown>): Promise<unknown> {
	const res = await fetch(`${TRON_RPC}${path}`, {
		method: "POST",
		headers: tronHeaders(),
		body: JSON.stringify(body),
	});
	if (!res.ok) throw new Error(`Tron RPC ${path} returned ${res.status}: ${await res.text()}`);
	return res.json();
}

async function getTrxBalance(addressHex: string): Promise<bigint> {
	const result = (await tronPost("/wallet/getaccount", {
		address: addressHex,
		visible: false,
	})) as { balance?: number };
	return BigInt(result.balance ?? 0);
}

async function getTrc20Balance(ownerHex: string, contractHex: string): Promise<bigint> {
	// Tron hex addresses start with 41, we need the 20-byte part for ABI encoding
	const ownerBytes = ownerHex.startsWith("41") ? ownerHex.slice(2) : ownerHex;
	const parameter = ownerBytes.padStart(64, "0");

	const result = (await tronPost("/wallet/triggerconstantcontract", {
		owner_address: ownerHex,
		contract_address: contractHex,
		function_selector: "balanceOf(address)",
		parameter,
		visible: false,
	})) as { constant_result?: string[] };

	if (!result.constant_result?.[0]) return 0n;
	return BigInt(`0x${result.constant_result[0]}`);
}

// --- Transaction building + signing ---

async function createTrxTransfer(
	fromHex: string,
	toHex: string,
	amountSun: bigint,
): Promise<{ raw_data: unknown; raw_data_hex: string; txID: string }> {
	const result = (await tronPost("/wallet/createtransaction", {
		owner_address: fromHex,
		to_address: toHex,
		amount: Number(amountSun),
		visible: false,
	})) as { raw_data: unknown; raw_data_hex: string; txID: string };
	if (!result.txID) throw new Error(`Failed to create TRX transfer: ${JSON.stringify(result)}`);
	return result;
}

async function createTrc20Transfer(
	fromHex: string,
	contractHex: string,
	toHex: string,
	amount: bigint,
): Promise<{ transaction: { raw_data: unknown; raw_data_hex: string; txID: string } }> {
	const toBytes = toHex.startsWith("41") ? toHex.slice(2) : toHex;
	const amountHex = amount.toString(16).padStart(64, "0");
	const parameter = toBytes.padStart(64, "0") + amountHex;

	const result = (await tronPost("/wallet/triggersmartcontract", {
		owner_address: fromHex,
		contract_address: contractHex,
		function_selector: "transfer(address,uint256)",
		parameter,
		fee_limit: 100_000_000, // 100 TRX max fee
		visible: false,
	})) as { result?: { result: boolean }; transaction: { raw_data: unknown; raw_data_hex: string; txID: string } };
	if (!result.result?.result) throw new Error(`Failed to create TRC-20 transfer: ${JSON.stringify(result)}`);
	return result as { transaction: { raw_data: unknown; raw_data_hex: string; txID: string } };
}

function signTransaction(
	tx: { raw_data: unknown; raw_data_hex: string; txID: string },
	privateKey: Uint8Array,
): { raw_data: unknown; raw_data_hex: string; txID: string; signature: string[] } {
	const txHash = fromHex(tx.txID);
	const sig: { toCompactRawBytes(): Uint8Array; recovery: number } = sec.sign(txHash, privateKey, { lowS: true });
	// Tron signature = r (32) + s (32) + recovery (1)
	const sigBytes = new Uint8Array(65);
	sigBytes.set(sig.toCompactRawBytes(), 0);
	sigBytes[64] = sig.recovery;
	return { ...tx, signature: [toHex(sigBytes)] };
}

async function broadcastTransaction(signedTx: unknown): Promise<string> {
	const result = (await tronPost("/wallet/broadcasttransaction", signedTx as Record<string, unknown>)) as {
		result?: boolean;
		txid?: string;
		message?: string;
	};
	if (!result.result) throw new Error(`Broadcast failed: ${result.message ?? JSON.stringify(result)}`);
	return result.txid ?? (signedTx as { txID: string }).txID;
}

// --- Fetch tokens from chain server ---

interface ChainToken {
	id: string;
	token: string;
	chain: string;
	decimals: number;
	contractAddress: string | null;
	displayName: string;
}

async function fetchTronTokens(): Promise<Array<{ name: string; contractHex: string; decimals: number }>> {
	const headers: Record<string, string> = { "Content-Type": "application/json" };
	if (CRYPTO_SERVICE_KEY) headers.Authorization = `Bearer ${CRYPTO_SERVICE_KEY}`;

	const res = await fetch(`${CRYPTO_SERVICE_URL}/chains`, { headers });
	if (!res.ok) throw new Error(`Chain server returned ${res.status}`);

	const chains: ChainToken[] = await res.json();
	return chains
		.filter((c) => c.chain === "tron" && c.contractAddress)
		.map((c) => ({
			name: c.token,
			contractHex: tronAddressToHex(c.contractAddress!),
			decimals: c.decimals,
		}));
}

// --- Key derivation ---

function deriveTronPrivateKey(master: HDKey, chainIndex: number, addressIndex: number): Uint8Array {
	const child = master.deriveChild(chainIndex).deriveChild(addressIndex);
	if (!child.privateKey) throw new Error(`No private key at ${chainIndex}/${addressIndex}`);
	return child.privateKey;
}

function deriveTronAddress(master: HDKey, chainIndex: number, addressIndex: number): string {
	const child = master.deriveChild(chainIndex).deriveChild(addressIndex);
	if (!child.publicKey) throw new Error(`No public key at ${chainIndex}/${addressIndex}`);
	return pubkeyToTronAddress(child.publicKey);
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

	// Fetch TRC-20 tokens from chain server
	console.log(`Fetching Tron tokens from ${CRYPTO_SERVICE_URL}...`);
	const TOKENS = await fetchTronTokens();
	console.log(`Found ${TOKENS.length} TRC-20 tokens: ${TOKENS.map((t) => t.name).join(", ") || "(none — TRX only)"}`);

	const seed = bip39.mnemonicToSeedSync(mnemonic);
	const master = HDKey.fromMasterSeed(seed);
	const tronAccount = master.derive("m/44'/195'/0'"); // BIP-44 coin type 195

	// Treasury = internal chain (1), index 0
	const treasuryAddress = deriveTronAddress(tronAccount, 1, 0);
	const treasuryHex = tronAddressToHex(treasuryAddress);
	const treasuryPrivKey = deriveTronPrivateKey(tronAccount, 1, 0);

	console.log(`\nTreasury: ${treasuryAddress}`);
	console.log(`RPC: ${TRON_RPC}`);
	console.log(`Dry run: ${DRY_RUN}`);
	console.log(`Scanning ${MAX_INDEX} deposit addresses...\n`);

	// ============================================================
	// Phase 1: Scan all deposit addresses for TRX + TRC-20 balances
	// ============================================================
	console.log("--- Scanning deposit addresses ---");

	type DepositInfo = {
		index: number;
		address: string;
		addressHex: string;
		trxBalance: bigint;
		tokenBalances: Array<{ name: string; contractHex: string; decimals: number; balance: bigint }>;
	};

	const deposits: DepositInfo[] = [];

	for (let i = 0; i < MAX_INDEX; i++) {
		const addr = deriveTronAddress(tronAccount, 0, i);
		const addrHex = tronAddressToHex(addr);
		const trxBalance = await getTrxBalance(addrHex);

		const tokenBalances: DepositInfo["tokenBalances"] = [];
		for (const token of TOKENS) {
			try {
				const balance = await getTrc20Balance(addrHex, token.contractHex);
				if (balance > 0n) {
					tokenBalances.push({ ...token, balance });
				}
			} catch {
				// Contract call failed — skip
			}
		}

		if (trxBalance > 0n || tokenBalances.length > 0) {
			const parts = [`${formatTrx(trxBalance)} TRX`];
			for (const t of tokenBalances) {
				const formatted = Number(t.balance) / 10 ** t.decimals;
				parts.push(`${formatted} ${t.name}`);
			}
			console.log(`  [${i}] ${addr}: ${parts.join(", ")}`);
			deposits.push({ index: i, address: addr, addressHex: addrHex, trxBalance, tokenBalances });
		}

		// Rate limit protection
		if (i % 10 === 9) await new Promise((r) => setTimeout(r, 200));
	}

	if (deposits.length === 0) {
		console.log("\nNo deposit addresses with balances. Nothing to sweep.");
		return;
	}

	const trxDeposits = deposits.filter((d) => d.trxBalance > TRX_TRANSFER_COST);
	const tokenDeposits = deposits.filter((d) => d.tokenBalances.length > 0);
	const totalTrx = trxDeposits.reduce((sum, d) => sum + d.trxBalance, 0n);

	console.log(`\nFound: ${trxDeposits.length} TRX deposits (${formatTrx(totalTrx)} TRX)`);
	for (const token of TOKENS) {
		const total = tokenDeposits.reduce(
			(sum, d) => sum + (d.tokenBalances.find((t) => t.name === token.name)?.balance ?? 0n),
			0n,
		);
		if (total > 0n) {
			const formatted = Number(total) / 10 ** token.decimals;
			console.log(`       ${formatted} ${token.name}`);
		}
	}

	if (DRY_RUN) {
		console.log("\nDry run — no transactions broadcast. Set SWEEP_DRY_RUN=false to sweep.");
		return;
	}

	// ============================================================
	// Phase 2: Sweep TRX FIRST (self-funded → fills treasury)
	// ============================================================
	if (trxDeposits.length > 0) {
		console.log("\n--- Phase 1: Sweeping TRX to treasury ---");
		for (const dep of trxDeposits) {
			const privKey = deriveTronPrivateKey(tronAccount, 0, dep.index);
			const sweepAmount = dep.trxBalance - TRX_TRANSFER_COST;
			if (sweepAmount <= 0n) {
				console.log(`  [${dep.index}] Balance too low to cover fees, skipping`);
				continue;
			}

			try {
				const tx = await createTrxTransfer(dep.addressHex, treasuryHex, sweepAmount);
				const signed = signTransaction(tx, privKey);
				const txId = await broadcastTransaction(signed);
				console.log(`  [${dep.index}] Swept ${formatTrx(sweepAmount)} TRX: ${txId}`);
				await new Promise((r) => setTimeout(r, 3000)); // Wait for confirmation
			} catch (err) {
				console.error(`  [${dep.index}] Failed: ${err}`);
			}
		}
	}

	// ============================================================
	// Phase 3: Fund energy + sweep TRC-20s
	// ============================================================
	if (tokenDeposits.length > 0) {
		const treasuryTrx = await getTrxBalance(treasuryHex);
		const totalEnergyNeeded =
			TRC20_ENERGY_COST * BigInt(tokenDeposits.reduce((n, d) => n + d.tokenBalances.length, 0));

		console.log("\n--- Phase 2: Funding energy for TRC-20 sweeps ---");
		console.log(`Treasury TRX: ${formatTrx(treasuryTrx)}, energy cost: ${formatTrx(totalEnergyNeeded)}`);

		if (treasuryTrx < totalEnergyNeeded) {
			console.error(
				`Insufficient treasury TRX for energy. Need ${formatTrx(totalEnergyNeeded)}, have ${formatTrx(treasuryTrx)}.`,
			);
			console.error("Sweep more TRX deposits or manually fund the treasury.");
			process.exit(1);
		}

		for (const dep of tokenDeposits) {
			const depTrx = await getTrxBalance(dep.addressHex);
			const needed = TRC20_ENERGY_COST * BigInt(dep.tokenBalances.length);
			if (depTrx >= needed) {
				console.log(`  [${dep.index}] Already has energy TRX, skipping`);
				continue;
			}

			try {
				const fundAmount = needed - depTrx;
				const tx = await createTrxTransfer(treasuryHex, dep.addressHex, fundAmount);
				const signed = signTransaction(tx, treasuryPrivKey);
				const txId = await broadcastTransaction(signed);
				console.log(`  [${dep.index}] Funded ${formatTrx(fundAmount)} TRX: ${txId}`);
				await new Promise((r) => setTimeout(r, 3000));
			} catch (err) {
				console.error(`  [${dep.index}] Fund failed: ${err}`);
			}
		}

		console.log("\n--- Phase 3: Sweeping TRC-20s to treasury ---");
		for (const dep of tokenDeposits) {
			const privKey = deriveTronPrivateKey(tronAccount, 0, dep.index);

			for (const token of dep.tokenBalances) {
				try {
					const { transaction: tx } = await createTrc20Transfer(
						dep.addressHex,
						token.contractHex,
						treasuryHex,
						token.balance,
					);
					const signed = signTransaction(tx, privKey);
					const txId = await broadcastTransaction(signed);
					const formatted = Number(token.balance) / 10 ** token.decimals;
					console.log(`  [${dep.index}] Swept ${formatted} ${token.name}: ${txId}`);
					await new Promise((r) => setTimeout(r, 3000));
				} catch (err) {
					console.error(`  [${dep.index}] ${token.name} sweep failed: ${err}`);
				}
			}
		}
	}

	// ============================================================
	// Summary
	// ============================================================
	console.log("\n--- Final treasury balances ---");
	const finalTrx = await getTrxBalance(treasuryHex);
	console.log(`  TRX: ${formatTrx(finalTrx)}`);
	for (const token of TOKENS) {
		try {
			const bal = await getTrc20Balance(treasuryHex, token.contractHex);
			if (bal > 0n) {
				const formatted = Number(bal) / 10 ** token.decimals;
				console.log(`  ${token.name}: ${formatted}`);
			}
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
