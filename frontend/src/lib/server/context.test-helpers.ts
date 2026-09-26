/**
 * A recording stand-in for DemoContext: no RPC, no keys. Each test scripts the eth_call results,
 * the RPC answers and the receipt, then reads back what would have been simulated or sent.
 */
import type { Address, Hex, TransactionReceipt } from 'viem';
import { logContext } from '../fixtures.test-helpers';
import { parseManifest, type ContextConfig } from './config';
import type { DemoContext, Role } from './context';

export const MANIFEST_JSON = {
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

export type SimCall = {
	account?: Address;
	to?: Address;
	data?: Hex;
	blockTag?: string;
	blockNumber?: bigint;
};
export type SentTx = { role: Role; to: Address; data: Hex };
export type RpcCall = { method: string; params: unknown[] };

export type FakeOptions = {
	/** eth_call answer for the n-th simulation (0-based). Throw to simulate a revert. */
	call?: (args: SimCall, index: number) => Promise<{ data?: Hex }>;
	request?: (method: string, params: unknown[]) => Promise<unknown>;
	send?: (tx: SentTx) => Promise<Hex>;
	receipt?: Partial<TransactionReceipt>;
	readContract?: () => Promise<unknown>;
	config?: Partial<ContextConfig>;
	/** When set, waitForTransactionReceipt rejects with it after the send returned a hash. */
	receiptError?: unknown;
};

export type Fake = { ctx: DemoContext; calls: SimCall[]; sent: SentTx[]; requests: RpcCall[] };

const TX_HASH = `0x${'ab'.repeat(32)}` as Hex;

export function fakeContext(options: FakeOptions = {}): Fake {
	const manifest = parseManifest(MANIFEST_JSON);
	const calls: SimCall[] = [];
	const sent: SentTx[] = [];
	const requests: RpcCall[] = [];
	const client = {
		call: (args: SimCall) => {
			calls.push(args);
			return options.call ? options.call(args, calls.length - 1) : Promise.resolve({ data: '0x' });
		},
		request: ({ method, params }: RpcCall) => {
			requests.push({ method, params });
			return options.request ? options.request(method, params) : Promise.resolve(null);
		},
		waitForTransactionReceipt: async () => {
			if (options.receiptError !== undefined) throw options.receiptError;
			return {
				status: 'success',
				blockNumber: 100n,
				gasUsed: 21_000n,
				logs: [],
				...options.receipt
			};
		},
		readContract: () =>
			options.readContract
				? options.readContract()
				: Promise.reject(new Error('no reads scripted')),
		getBlock: async () => ({ number: 101n, timestamp: 1_790_000_000n, hash: TX_HASH })
	};
	const wallet = (role: Role) => ({
		account: { address: manifest[role] },
		sendTransaction: ({ to, data }: { to: Address; data: Hex }) => {
			const tx = { role, to, data };
			sent.push(tx);
			return options.send ? options.send(tx) : Promise.resolve(TX_HASH);
		}
	});
	const config: ContextConfig = {
		rpcUrl: 'http://127.0.0.1:8545',
		deploymentFile: '/tmp/bailiff-test/anvil.json',
		snapshotFile: '/tmp/bailiff-test/anvil-snapshot.json',
		evidenceFile: '/tmp/bailiff-test/evidence.jsonl',
		...options.config
	};
	const ctx = {
		config,
		manifest,
		chain: { id: 31337 },
		client,
		wallets: { issuer: wallet('issuer'), mm: wallet('mm'), keeper: wallet('keeper') },
		logContext
	} as unknown as DemoContext;
	return { ctx, calls, sent, requests };
}
