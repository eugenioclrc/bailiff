/**
 * Per-request demo context: validated env and manifest, viem clients, and a live check that the
 * RPC really is the local Anvil fork the manifest describes. Keys stay inside the wallet clients.
 */
import { env } from '$env/dynamic/private';
import { readFile } from 'node:fs/promises';
import {
	createPublicClient,
	createWalletClient,
	defineChain,
	http,
	type Account,
	type Chain,
	type PublicClient,
	type Transport,
	type WalletClient
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import type { LogContext } from '../logs';
import {
	ConfigError,
	LOCAL_CHAIN_ID,
	parseEnv,
	parseManifest,
	type AddressField,
	type DemoConfig,
	type Manifest
} from './config';

export const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11' as const;
const RPC_TIMEOUT_MS = 20_000;

export type Role = 'issuer' | 'mm' | 'keeper';

export type DemoContext = {
	config: DemoConfig;
	manifest: Manifest;
	chain: Chain;
	client: PublicClient<Transport, Chain>;
	wallets: Record<Role, WalletClient<Transport, Chain, Account>>;
	logContext: LogContext;
};

const LABELS: Record<AddressField, string> = {
	poolManager: 'PoolManager',
	factory: 'factory',
	hook: 'hook',
	stateView: 'StateView',
	rwa: 'RWA token',
	usdc: 'USDC',
	pa: 'pool wrapper (PA)',
	market: 'market',
	adapter: 'adapter',
	desk: 'desk',
	issuer: 'issuer',
	mm: 'market maker',
	keeper: 'keeper',
	borrower: 'borrower',
	lender: 'lender'
};

async function loadManifest(path: string): Promise<Manifest> {
	let text: string;
	try {
		text = await readFile(path, 'utf8');
	} catch {
		throw new ConfigError('DEPLOYMENT_FILE cannot be read.');
	}
	try {
		return parseManifest(JSON.parse(text));
	} catch (err) {
		if (err instanceof ConfigError) throw err;
		throw new ConfigError('DEPLOYMENT_FILE is not valid JSON.');
	}
}

function buildLogContext(manifest: Manifest): LogContext {
	const labels = Object.fromEntries(
		(Object.keys(LABELS) as AddressField[]).map((field) => [
			manifest[field].toLowerCase(),
			LABELS[field]
		])
	);
	const { market, adapter, rwa, usdc, pa, hook, poolManager, desk, factory } = manifest;
	return {
		labels,
		contracts: { market, adapter, rwa, usdc, pa, hook, poolManager, desk, factory },
		poolId: manifest.poolId
	};
}

type NodeInfo = { forkConfig?: { forkBlockNumber?: number | string | null } };

/** Contracts that must have code: the four O2 Labs contracts and the local deployment the UI drives. */
const CODE_FIELDS = [
	'poolManager',
	'factory',
	'hook',
	'stateView',
	'market',
	'adapter',
	'rwa',
	'pa',
	'desk'
] as const satisfies readonly AddressField[];

/** The subset of the public client this check needs, so tests can pass a stub. */
export type AnvilProbe = Pick<
	PublicClient<Transport, Chain>,
	'getChainId' | 'request' | 'getBlock' | 'getCode'
>;

/**
 * Chain id 31337, an Anvil node forked at the manifest's block and block hash, and code at every
 * manifest contract. A restarted Anvil without a redeploy fails here with an operator message
 * instead of surfacing as an ABI decoding error later.
 */
export async function assertLocalAnvil(client: AnvilProbe, manifest: Manifest): Promise<void> {
	const chainId = await client.getChainId();
	if (chainId !== LOCAL_CHAIN_ID)
		throw new ConfigError(`the RPC reports chain ${chainId}, not ${LOCAL_CHAIN_ID}.`);
	const request = client.request as unknown as (args: {
		method: string;
		params: unknown[];
	}) => Promise<unknown>;
	let info: NodeInfo;
	try {
		info = (await request({ method: 'anvil_nodeInfo', params: [] })) as NodeInfo;
	} catch {
		throw new ConfigError('the RPC does not answer anvil_nodeInfo, so it is not an Anvil node.');
	}
	const forkBlock = info.forkConfig?.forkBlockNumber;
	if (String(forkBlock ?? '') !== manifest.forkBlock) {
		throw new ConfigError(
			`Anvil is not forked at block ${manifest.forkBlock} as the manifest says.`
		);
	}
	const [forkHeader, ...codes] = await Promise.all([
		client.getBlock({ blockNumber: BigInt(manifest.forkBlock) }),
		...CODE_FIELDS.map((field) => client.getCode({ address: manifest[field] }))
	]);
	if (forkHeader.hash?.toLowerCase() !== manifest.forkBlockHash.toLowerCase()) {
		throw new ConfigError('Anvil fork block hash does not match the manifest.');
	}
	const missing = CODE_FIELDS.filter((_, i) => codes[i] === undefined || codes[i] === '0x');
	if (missing.length) {
		throw new ConfigError(
			`manifest contracts have no code on this Anvil (${missing.join(', ')}); rerun the local deploy and seed (O4).`
		);
	}
}

/** Never lets viem's own message through: for an out-of-range scalar it prints the key. */
function accountOf(key: DemoConfig['keys'][Role], role: Role): Account {
	try {
		return privateKeyToAccount(key);
	} catch {
		throw new ConfigError(`${role.toUpperCase()}_PK is not a valid secp256k1 private key.`);
	}
}

export async function loadContext(): Promise<DemoContext> {
	const config = parseEnv(env);
	const manifest = await loadManifest(config.deploymentFile);
	const chain = defineChain({
		id: LOCAL_CHAIN_ID,
		name: 'Anvil fork',
		nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
		rpcUrls: { default: { http: [config.rpcUrl] } },
		contracts: { multicall3: { address: MULTICALL3 } }
	});
	const transport = http(config.rpcUrl, { timeout: RPC_TIMEOUT_MS, retryCount: 0 });
	const client = createPublicClient({ chain, transport });
	await assertLocalAnvil(client, manifest);

	const wallet = (role: Role) => {
		const account = accountOf(config.keys[role], role);
		if (account.address !== manifest[role]) {
			throw new ConfigError(
				`${role.toUpperCase()}_PK does not belong to the manifest ${role} address.`
			);
		}
		return createWalletClient({ account, chain, transport });
	};
	const wallets = { issuer: wallet('issuer'), mm: wallet('mm'), keeper: wallet('keeper') };
	return { config, manifest, chain, client, wallets, logContext: buildLogContext(manifest) };
}
