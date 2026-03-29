#!/usr/bin/env node
/**
 * Generate TON address pool from a BIP39 mnemonic using SLIP-0010 (Ed25519).
 *
 * Derives addresses at m/44'/607'/{0..N}' (3 hardened levels per Tonkeeper standard)
 * using WalletV4R2 StateInit for correct address derivation.
 *
 * Prerequisites:
 *   npm install @wopr-network/crypto-plugins @noble/curves @scure/bip39
 *
 * Usage:
 *   MNEMONIC="your twenty four words ..." node scripts/generate-ton-pool.mjs
 *
 * Options:
 *   --count=N         Number of addresses to generate (default: 1000)
 *   --dry-run         Print addresses but don't upload
 *   --server=URL      Crypto key server URL (default: http://167.71.118.221:3100)
 *   --admin-token=T   Admin token (default: from ADMIN_TOKEN env var)
 */

import { ed25519 } from "@noble/curves/ed25519";
import { hmac } from "@noble/hashes/hmac";
import { sha512 } from "@noble/hashes/sha512";
import { TonAddressEncoder } from "@wopr-network/crypto-plugins";
import * as bip39 from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english";

const MNEMONIC = process.env.MNEMONIC;
if (!MNEMONIC) {
	console.error("MNEMONIC env var required.");
	process.exit(1);
}

const COUNT = Number(process.argv.find((a) => a.startsWith("--count="))?.split("=")[1] ?? 1000);
const DRY_RUN = process.argv.includes("--dry-run");
const SERVER = process.argv.find((a) => a.startsWith("--server="))?.split("=")[1] ?? "http://167.71.118.221:3100";
const ADMIN_TOKEN = process.argv.find((a) => a.startsWith("--admin-token="))?.split("=")[1] ?? process.env.ADMIN_TOKEN ?? "ks-admin-2026";

// --- SLIP-0010 Ed25519 HD derivation ---

function slip0010MasterKey(seed) {
	const I = hmac(sha512, new TextEncoder().encode("ed25519 seed"), seed);
	return { key: I.slice(0, 32), chainCode: I.slice(32) };
}

function slip0010Derive(parentKey, parentChainCode, index) {
	// Ed25519 SLIP-0010 only supports hardened derivation
	const hardenedIndex = (index | 0x80000000) >>> 0;
	const data = new Uint8Array(37);
	data[0] = 0x00;
	data.set(parentKey, 1);
	data[33] = (hardenedIndex >>> 24) & 0xff;
	data[34] = (hardenedIndex >>> 16) & 0xff;
	data[35] = (hardenedIndex >>> 8) & 0xff;
	data[36] = hardenedIndex & 0xff;
	const I = hmac(sha512, parentChainCode, data);
	return { key: I.slice(0, 32), chainCode: I.slice(32) };
}

function deriveEd25519Path(seed, path) {
	let { key, chainCode } = slip0010MasterKey(seed);
	for (const index of path) {
		({ key, chainCode } = slip0010Derive(key, chainCode, index));
	}
	return key;
}

// --- TON address encoding (uses V4R2 StateInit from crypto-plugins) ---
const tonEncoder = new TonAddressEncoder();

// --- Main ---

async function main() {
	// Validate mnemonic
	if (!bip39.validateMnemonic(MNEMONIC, wordlist)) {
		console.error("Invalid mnemonic.");
		process.exit(1);
	}

	// Derive seed
	const seed = await bip39.mnemonicToSeed(MNEMONIC);

	// SLIP-0010 path: m/44'/607'/{index}' (3 hardened levels, per Tonkeeper standard)
	// For multiple accounts, increment the account index, not a sub-path
	// 607 = TON coin type
	const addresses = [];
	console.log(`Generating ${COUNT} TON addresses...`);

	for (let i = 0; i < COUNT; i++) {
		// m/44'/607'/{i}' — each account is a separate hardened derivation
		const privateKey = deriveEd25519Path(seed, [44, 607, i]);
		const publicKey = ed25519.getPublicKey(privateKey);
		const address = tonEncoder.encode(publicKey, {});

		addresses.push({
			derivation_index: i,
			public_key: Buffer.from(publicKey).toString("hex"),
			address,
		});

		if (i % 100 === 0) console.log(`  ${i}/${COUNT}...`);
	}

	console.log(`Generated ${addresses.length} addresses.`);
	console.log(`First: ${addresses[0].address}`);
	console.log(`Last:  ${addresses[addresses.length - 1].address}`);

	if (DRY_RUN) {
		console.log("\nDry run — not uploading.");
		for (const a of addresses.slice(0, 5)) {
			console.log(`  [${a.derivation_index}] ${a.address} (${a.public_key.slice(0, 16)}...)`);
		}
		console.log(`  ... and ${addresses.length - 5} more.`);
		return;
	}

	// Upload to admin API
	console.log(`\nUploading to ${SERVER}/admin/pool/replenish ...`);
	const res = await fetch(`${SERVER}/admin/pool/replenish`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			Authorization: `Bearer ${ADMIN_TOKEN}`,
		},
		body: JSON.stringify({
			key_ring_id: "ton-main",
			plugin_id: "ton",
			encoding: "ton-base64url",
			addresses,
		}),
	});

	if (!res.ok) {
		const body = await res.text();
		console.error(`Upload failed: ${res.status} ${body}`);
		process.exit(1);
	}

	const result = await res.json();
	console.log("Upload complete:", result);
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
