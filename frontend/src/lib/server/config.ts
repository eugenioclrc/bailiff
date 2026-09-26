/**
 * Validation of the private environment, the O2 manifest and the O4 snapshot record.
 * Pure: no $env, no filesystem, so it runs under `bun test`.
 * Error messages name the offending variable or field and never echo a key.
 */
import { isAbsolute } from 'node:path';
import { encodeAbiParameters, getAddress, isAddress, keccak256, type Address, type Hex } from 'viem';

export const LOCAL_CHAIN_ID = 31337;
const FIXED = { fee: 3000, tickSpacing: 60, tickLower: -887220, tickUpper: 887220, navFloorBps: 9900 };

export class ConfigError extends Error {
	override name = 'ConfigError';
}

export type DemoConfig = {
	rpcUrl: string;
	keys: { issuer: Hex; mm: Hex; keeper: Hex };
	deploymentFile: string;
	snapshotFile: string;
};

export type PoolKey = {
	currency0: Address;
	currency1: Address;
	fee: number;
	tickSpacing: number;
	hooks: Address;
};

const ADDRESS_FIELDS = [
	'poolManager',
	'factory',
	'hook',
	'stateView',
	'rwa',
	'usdc',
	'pa',
	'market',
	'adapter',
	'desk',
	'issuer',
	'mm',
	'keeper',
	'borrower',
	'lender'
] as const;

export type AddressField = (typeof ADDRESS_FIELDS)[number];

export type Manifest = Record<AddressField, Address> & {
	network: 'anvil-fork';
	chainId: typeof LOCAL_CHAIN_ID;
	forkBlock: string | null;
	forkBlockHash: Hex | null;
	poolKey: PoolKey;
	poolId: Hex;
	rwaIsCurrency0: boolean;
	deployBlock: bigint;
	initialLiquidity: bigint;
	tickLower: number;
	tickUpper: number;
	navFloorBps: number;
	keeperBps: number;
	sourceCommit: string;
};

export type SnapshotRecord = {
	snapshotId: Hex;
	chainId: typeof LOCAL_CHAIN_ID;
	sourceCommit: string;
	manifestPath: string;
};

const PRIVATE_KEY = /^0x[0-9a-fA-F]{64}$/;
const BYTES32 = /^0x[0-9a-fA-F]{64}$/;
const DECIMAL = /^\d+$/;
const GIT_SHA = /^[0-9a-f]{40}$/;
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]']);

export function isLoopbackHttpUrl(value: string): boolean {
	try {
		const url = new URL(value);
		return url.protocol === 'http:' && !url.username && !url.password && LOOPBACK_HOSTS.has(url.hostname);
	} catch {
		return false;
	}
}

function requireKey(env: Record<string, string | undefined>, name: string): Hex {
	const value = env[name];
	if (!value || !PRIVATE_KEY.test(value)) {
		throw new ConfigError(`${name} must be a 0x-prefixed 32-byte hex private key.`);
	}
	return value as Hex;
}

function requireJsonPath(env: Record<string, string | undefined>, name: string): string {
	const value = env[name];
	if (!value || !isAbsolute(value) || !value.endsWith('.json')) {
		throw new ConfigError(`${name} must be an absolute path to a .json file.`);
	}
	return value;
}

export function parseEnv(env: Record<string, string | undefined>): DemoConfig {
	if (env.DEMO_MODE !== 'local') {
		throw new ConfigError('DEMO_MODE must be "local"; server actions are disabled in any other mode.');
	}
	const rpcUrl = env.ANVIL_RPC ?? '';
	if (!isLoopbackHttpUrl(rpcUrl)) {
		throw new ConfigError('ANVIL_RPC must be an http:// URL on 127.0.0.1, localhost or [::1].');
	}
	return {
		rpcUrl,
		keys: {
			issuer: requireKey(env, 'ISSUER_PK'),
			mm: requireKey(env, 'MM_PK'),
			keeper: requireKey(env, 'KEEPER_PK')
		},
		deploymentFile: requireJsonPath(env, 'DEPLOYMENT_FILE'),
		snapshotFile: requireJsonPath(env, 'SNAPSHOT_FILE')
	};
}

function asRecord(json: unknown, what: string): Record<string, unknown> {
	if (typeof json !== 'object' || json === null || Array.isArray(json)) {
		throw new ConfigError(`${what} must be a JSON object.`);
	}
	return json as Record<string, unknown>;
}

function address(obj: Record<string, unknown>, field: string, prefix = ''): Address {
	const value = obj[field];
	if (typeof value !== 'string' || !isAddress(value, { strict: false })) {
		throw new ConfigError(`manifest ${prefix}${field} must be an address.`);
	}
	return getAddress(value);
}

function exact<T>(obj: Record<string, unknown>, field: string, expected: T, prefix = ''): T {
	if (obj[field] !== expected) {
		throw new ConfigError(`manifest ${prefix}${field} must be ${JSON.stringify(expected)}.`);
	}
	return expected;
}

function decimal(obj: Record<string, unknown>, field: string): bigint {
	const value = obj[field];
	if (typeof value !== 'string' || !DECIMAL.test(value)) {
		throw new ConfigError(`manifest ${field} must be a decimal string.`);
	}
	return BigInt(value);
}

function integer(obj: Record<string, unknown>, field: string): number {
	const value = obj[field];
	if (typeof value !== 'number' || !Number.isInteger(value)) {
		throw new ConfigError(`manifest ${field} must be an integer.`);
	}
	return value;
}

export function computePoolId(key: PoolKey): Hex {
	return keccak256(
		encodeAbiParameters(
			[
				{ type: 'address' },
				{ type: 'address' },
				{ type: 'uint24' },
				{ type: 'int24' },
				{ type: 'address' }
			],
			[key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]
		)
	);
}

function parsePoolKey(raw: unknown, pa: Address, usdc: Address, hook: Address): PoolKey {
	const obj = asRecord(raw, 'manifest poolKey');
	const key: PoolKey = {
		currency0: address(obj, 'currency0', 'poolKey.'),
		currency1: address(obj, 'currency1', 'poolKey.'),
		fee: exact(obj, 'fee', FIXED.fee, 'poolKey.'),
		tickSpacing: exact(obj, 'tickSpacing', FIXED.tickSpacing, 'poolKey.'),
		hooks: address(obj, 'hooks', 'poolKey.')
	};
	if (key.hooks !== hook) throw new ConfigError('manifest poolKey.hooks must be the manifest hook.');
	const [low, high] = BigInt(pa) < BigInt(usdc) ? [pa, usdc] : [usdc, pa];
	if (key.currency0 !== low || key.currency1 !== high) {
		throw new ConfigError('manifest poolKey currencies must be the sorted pair (pa, usdc).');
	}
	return key;
}

function parseNullable(obj: Record<string, unknown>, field: string, pattern: RegExp): string | null {
	const value = obj[field];
	if (value === null) return null;
	if (typeof value !== 'string' || !pattern.test(value)) {
		throw new ConfigError(`manifest ${field} is malformed.`);
	}
	return value;
}

export function parseManifest(json: unknown): Manifest {
	const obj = asRecord(json, 'manifest');
	exact(obj, 'schemaVersion', 1);
	const network = exact(obj, 'network', 'anvil-fork' as const);
	const chainId = exact(obj, 'chainId', LOCAL_CHAIN_ID);
	const addresses = Object.fromEntries(ADDRESS_FIELDS.map((f) => [f, address(obj, f)])) as Record<
		AddressField,
		Address
	>;
	const poolKey = parsePoolKey(obj.poolKey, addresses.pa, addresses.usdc, addresses.hook);
	const poolId = parseNullable(obj, 'poolId', BYTES32);
	if (!poolId || poolId.toLowerCase() !== computePoolId(poolKey)) {
		throw new ConfigError('manifest poolId does not match keccak256(abi.encode(poolKey)).');
	}
	const sourceCommit = obj.sourceCommit;
	if (typeof sourceCommit !== 'string' || !GIT_SHA.test(sourceCommit)) {
		throw new ConfigError('manifest sourceCommit must be a 40-character git SHA.');
	}
	return {
		...addresses,
		network,
		chainId,
		forkBlock: parseNullable(obj, 'forkBlock', DECIMAL),
		forkBlockHash: parseNullable(obj, 'forkBlockHash', BYTES32) as Hex | null,
		poolKey,
		poolId: poolId.toLowerCase() as Hex,
		rwaIsCurrency0: poolKey.currency0 === addresses.pa,
		deployBlock: decimal(obj, 'deployBlock'),
		initialLiquidity: decimal(obj, 'initialLiquidity'),
		tickLower: exact(obj, 'tickLower', FIXED.tickLower),
		tickUpper: exact(obj, 'tickUpper', FIXED.tickUpper),
		navFloorBps: exact(obj, 'navFloorBps', FIXED.navFloorBps),
		keeperBps: integer(obj, 'keeperBps'),
		sourceCommit
	};
}

export function parseSnapshotRecord(json: unknown): SnapshotRecord {
	const obj = asRecord(json, 'snapshot file');
	const { snapshotId, chainId, sourceCommit, manifestPath } = obj;
	if (typeof snapshotId !== 'string' || !/^0x[0-9a-fA-F]+$/.test(snapshotId)) {
		throw new ConfigError('snapshot file snapshotId must be a hex quantity such as "0x2".');
	}
	if (chainId !== LOCAL_CHAIN_ID) throw new ConfigError(`snapshot file chainId must be ${LOCAL_CHAIN_ID}.`);
	if (typeof sourceCommit !== 'string' || !GIT_SHA.test(sourceCommit)) {
		throw new ConfigError('snapshot file sourceCommit must be a 40-character git SHA.');
	}
	if (typeof manifestPath !== 'string' || !isAbsolute(manifestPath)) {
		throw new ConfigError('snapshot file manifestPath must be an absolute path.');
	}
	return { snapshotId: snapshotId as Hex, chainId: LOCAL_CHAIN_ID, sourceCommit, manifestPath };
}
