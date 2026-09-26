import { describe, expect, test } from 'bun:test';
import {
	ConfigError,
	isLoopbackHttpUrl,
	parseEnv,
	parseManifest,
	parseSnapshotRecord
} from './config';

// Anvil's public dev keys are NOT used here; these are arbitrary 32-byte test values.
const KEY_A = `0x${'11'.repeat(32)}`;
const KEY_B = `0x${'22'.repeat(32)}`;
const KEY_C = `0x${'33'.repeat(32)}`;

const goodEnv = {
	DEMO_MODE: 'local',
	ANVIL_RPC: 'http://127.0.0.1:8545',
	ISSUER_PK: KEY_A,
	MM_PK: KEY_B,
	KEEPER_PK: KEY_C,
	DEPLOYMENT_FILE: '/tmp/devenv/anvil.json',
	SNAPSHOT_FILE: '/tmp/devenv/anvil-snapshot.json'
};

function expectConfigError(fn: () => unknown, fragment: string) {
	try {
		fn();
	} catch (err) {
		expect(err).toBeInstanceOf(ConfigError);
		expect((err as Error).message).toContain(fragment);
		return err as Error;
	}
	throw new Error('expected a ConfigError');
}

describe('parseEnv', () => {
	test('accepts the local demo configuration', () => {
		const config = parseEnv(goodEnv);
		expect(config.rpcUrl).toBe('http://127.0.0.1:8545');
		expect(config.keys.keeper).toBe(KEY_C);
	});

	test('requires DEMO_MODE=local', () => {
		expectConfigError(() => parseEnv({ ...goodEnv, DEMO_MODE: 'live' }), 'DEMO_MODE');
		expectConfigError(() => parseEnv({ ...goodEnv, DEMO_MODE: undefined }), 'DEMO_MODE');
	});

	test('rejects a non-loopback RPC', () => {
		for (const url of [
			'https://sepolia.example.org',
			'http://10.0.0.2:8545',
			'http://127.0.0.1.evil.io:8545'
		]) {
			expectConfigError(() => parseEnv({ ...goodEnv, ANVIL_RPC: url }), 'ANVIL_RPC');
		}
	});

	test('names a malformed key without echoing it', () => {
		const err = expectConfigError(() => parseEnv({ ...goodEnv, MM_PK: '0x1234secret' }), 'MM_PK');
		expect(err.message).not.toContain('secret');
	});

	test('an out-of-range key is refused without echoing it in any form', () => {
		for (const key of [`0x${'00'.repeat(32)}`, `0x${'f'.repeat(64)}`]) {
			const err = expectConfigError(() => parseEnv({ ...goodEnv, KEEPER_PK: key }), 'KEEPER_PK');
			expect(err.message).not.toContain(key.slice(2, 12));
			const decimal = BigInt(key).toString();
			if (decimal.length > 1) expect(err.message).not.toContain(decimal.slice(0, 12));
		}
	});

	test('SNAPSHOT_FILE must not be the manifest', () => {
		expectConfigError(
			() => parseEnv({ ...goodEnv, SNAPSHOT_FILE: '/tmp/devenv/../devenv/anvil.json' }),
			'SNAPSHOT_FILE'
		);
	});

	test('requires absolute JSON paths', () => {
		expectConfigError(
			() => parseEnv({ ...goodEnv, DEPLOYMENT_FILE: 'anvil.json' }),
			'DEPLOYMENT_FILE'
		);
		expectConfigError(() => parseEnv({ ...goodEnv, SNAPSHOT_FILE: '/tmp/x.txt' }), 'SNAPSHOT_FILE');
	});
});

describe('isLoopbackHttpUrl', () => {
	test('loopback hosts only', () => {
		expect(isLoopbackHttpUrl('http://127.0.0.1:8545')).toBe(true);
		expect(isLoopbackHttpUrl('http://localhost:8545')).toBe(true);
		expect(isLoopbackHttpUrl('http://[::1]:8545')).toBe(true);
		expect(isLoopbackHttpUrl('ws://127.0.0.1:8545')).toBe(false);
		expect(isLoopbackHttpUrl('http://user:pw@127.0.0.1:8545')).toBe(false);
		expect(isLoopbackHttpUrl('not a url')).toBe(false);
	});
});

const manifest = {
	schemaVersion: 1,
	network: 'anvil-fork',
	chainId: 31337,
	forkBlock: '11782723',
	forkBlockHash: '0x408c76d91eb65f4b2469b6399c2e07dee5a5a2640fb50565cf487c8e8bbe214e',
	poolManager: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
	factory: '0xE6B0d96919334C33d06266d1420F97f6f434fA2B',
	hook: '0x51247E2291d290d17C08813A175AC86465EdE8c0',
	stateView: '0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C',
	rwa: '0xCc4C8af3781f1040769A6ecAa4f1B71F2e9bB50f',
	usdc: '0xDe70e0eE374e7bD67A47A6F08c2c74A0e23637c9',
	pa: '0x7060947614ECED6CA376A318C81dF6C088f00718',
	market: '0xD3B75A6478E05D33efD4ef87Fc4f26A9356DeD3e',
	adapter: '0x0457329C4AB669D6eB6F4a9ad5E90Ab8551174C6',
	desk: '0xb08Bad5d71024c4cFF8ea81584C814e5434ECD10',
	issuer: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
	mm: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
	keeper: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
	borrower: '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
	lender: '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65',
	poolKey: {
		currency0: '0x7060947614ECED6CA376A318C81dF6C088f00718',
		currency1: '0xDe70e0eE374e7bD67A47A6F08c2c74A0e23637c9',
		fee: 3000,
		tickSpacing: 60,
		hooks: '0x51247E2291d290d17C08813A175AC86465EdE8c0'
	},
	poolId: '0xedc4098ab8ade6e09beeaad5e2dbd4cf38cf5564d652a4e47fcedf317fe8fec2',
	deployBlock: '11782724',
	initialLiquidity: '500000000000000000',
	tickLower: -887220,
	tickUpper: 887220,
	navFloorBps: 9900,
	keeperBps: 5000,
	sourceCommit: '688437ba7b040b694b4676ec41e179fb01d7311a',
	deployTransactions: ['0x12fae8121848b5250851c6e8478e93d37a87572c85948d1576d39dd3218fce39'],
	liquidationTransaction: null
};

describe('parseManifest', () => {
	test('accepts the dev deployment and recomputes the poolId', () => {
		const parsed = parseManifest(manifest);
		expect(parsed.poolId).toBe(manifest.poolId);
		expect(parsed.rwaIsCurrency0).toBe(true);
		expect(parsed.initialLiquidity).toBe(500_000_000_000_000_000n);
	});

	test('accepts lowercase addresses and checksums them', () => {
		const parsed = parseManifest({ ...manifest, keeper: manifest.keeper.toLowerCase() });
		expect(parsed.keeper).toBe(manifest.keeper);
	});

	test('refuses anything but the local fork', () => {
		expectConfigError(() => parseManifest({ ...manifest, network: 'sepolia' }), 'network');
		expectConfigError(() => parseManifest({ ...manifest, chainId: 11155111 }), 'chainId');
	});

	test('rejects a poolId that does not match the poolKey', () => {
		expectConfigError(
			() => parseManifest({ ...manifest, poolId: `0x${'00'.repeat(32)}` }),
			'poolId'
		);
	});

	test('rejects a poolKey with another hook or unsorted currencies', () => {
		expectConfigError(
			() => parseManifest({ ...manifest, poolKey: { ...manifest.poolKey, hooks: manifest.desk } }),
			'poolKey.hooks'
		);
		expectConfigError(
			() =>
				parseManifest({
					...manifest,
					poolKey: { ...manifest.poolKey, currency0: manifest.usdc, currency1: manifest.pa }
				}),
			'poolKey'
		);
	});

	test('a fork manifest must name its fork block and hash', () => {
		expectConfigError(() => parseManifest({ ...manifest, forkBlock: null }), 'forkBlock');
		expectConfigError(() => parseManifest({ ...manifest, forkBlockHash: null }), 'forkBlock');
	});

	test('the Labs contracts are pinned to the O2 addresses', () => {
		const dead = '0x000000000000000000000000000000000000dEaD';
		for (const field of ['poolManager', 'factory', 'stateView'] as const) {
			expectConfigError(() => parseManifest({ ...manifest, [field]: dead }), field);
		}
		expectConfigError(
			() =>
				parseManifest({ ...manifest, hook: dead, poolKey: { ...manifest.poolKey, hooks: dead } }),
			'hook'
		);
	});

	test('O2 fixed values are enforced', () => {
		expectConfigError(
			() => parseManifest({ ...manifest, initialLiquidity: '1' }),
			'initialLiquidity'
		);
		expectConfigError(() => parseManifest({ ...manifest, keeperBps: 20_000 }), 'keeperBps');
	});

	test('zero and duplicate addresses are refused', () => {
		expectConfigError(
			() => parseManifest({ ...manifest, market: '0x0000000000000000000000000000000000000000' }),
			'market'
		);
		expectConfigError(() => parseManifest({ ...manifest, keeper: manifest.issuer }), 'distinct');
	});

	test('deployTransactions must be a list of transaction hashes', () => {
		const { deployTransactions: _omit, ...withoutTxs } = manifest;
		expectConfigError(() => parseManifest(withoutTxs), 'deployTransactions');
		expectConfigError(
			() => parseManifest({ ...manifest, deployTransactions: ['0x1234'] }),
			'deployTransactions'
		);
		expectConfigError(
			() => parseManifest({ ...manifest, liquidationTransaction: 'simulated' }),
			'liquidationTransaction'
		);
	});

	test('rejects malformed fields with the field name', () => {
		expectConfigError(() => parseManifest({ ...manifest, market: '0x1234' }), 'market');
		expectConfigError(() => parseManifest({ ...manifest, deployBlock: 11782724 }), 'deployBlock');
		expectConfigError(() => parseManifest({ ...manifest, schemaVersion: 2 }), 'schemaVersion');
		expectConfigError(() => parseManifest(null), 'object');
	});
});

describe('parseSnapshotRecord', () => {
	const record = {
		snapshotId: '0x2',
		chainId: 31337,
		sourceCommit: manifest.sourceCommit,
		manifestPath: '/tmp/devenv/anvil.json'
	};

	test('accepts a hex snapshot id', () => {
		expect(parseSnapshotRecord(record).snapshotId).toBe('0x2');
	});

	test('rejects other chains and malformed ids', () => {
		expectConfigError(() => parseSnapshotRecord({ ...record, chainId: 1 }), 'chainId');
		expectConfigError(() => parseSnapshotRecord({ ...record, snapshotId: '2' }), 'snapshotId');
		expectConfigError(
			() => parseSnapshotRecord({ ...record, manifestPath: 'anvil.json' }),
			'manifestPath'
		);
	});
});
