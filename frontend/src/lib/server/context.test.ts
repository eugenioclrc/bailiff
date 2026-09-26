import { describe, expect, test } from 'bun:test';
import type { Address } from 'viem';
import { ConfigError, parseManifest } from './config';
import { assertLocalAnvil, type AnvilProbe } from './context';
import { MANIFEST_JSON } from './context.test-helpers';

const manifest = parseManifest(MANIFEST_JSON);

function probe(overrides: {
	chainId?: number;
	nodeInfo?: unknown;
	hash?: string;
	noCodeAt?: Address;
}): AnvilProbe {
	return {
		getChainId: async () => overrides.chainId ?? 31337,
		request: (async () => {
			if (overrides.nodeInfo instanceof Error) throw overrides.nodeInfo;
			return overrides.nodeInfo ?? { forkConfig: { forkBlockNumber: 11782723 } };
		}) as unknown as AnvilProbe['request'],
		getBlock: (async () => ({
			hash: overrides.hash ?? manifest.forkBlockHash
		})) as unknown as AnvilProbe['getBlock'],
		getCode: (async ({ address }: { address: Address }) =>
			address === overrides.noCodeAt ? undefined : '0x6080') as AnvilProbe['getCode']
	};
}

async function messageOf(p: Promise<unknown>): Promise<string> {
	try {
		await p;
	} catch (err) {
		expect(err).toBeInstanceOf(ConfigError);
		return (err as Error).message;
	}
	throw new Error('expected a ConfigError');
}

describe('assertLocalAnvil', () => {
	test('accepts the manifest fork', async () => {
		await expect(assertLocalAnvil(probe({}), manifest)).resolves.toBeUndefined();
	});

	test('refuses another chain, a non-Anvil node or another fork block', async () => {
		expect(await messageOf(assertLocalAnvil(probe({ chainId: 11155111 }), manifest))).toContain(
			'11155111'
		);
		expect(
			await messageOf(assertLocalAnvil(probe({ nodeInfo: new Error('no method') }), manifest))
		).toContain('anvil_nodeInfo');
		expect(
			await messageOf(
				assertLocalAnvil(probe({ nodeInfo: { forkConfig: { forkBlockNumber: 1 } } }), manifest)
			)
		).toContain('11782723');
	});

	test('refuses a fork whose block hash differs from the manifest', async () => {
		const message = await messageOf(
			assertLocalAnvil(probe({ hash: `0x${'ab'.repeat(32)}` }), manifest)
		);
		expect(message).toContain('block hash');
	});

	test('names contracts without code, e.g. after an Anvil restart without a redeploy', async () => {
		const message = await messageOf(
			assertLocalAnvil(probe({ noCodeAt: manifest.adapter }), manifest)
		);
		expect(message).toContain('adapter');
		expect(message).toContain('O4');
	});

	test('a USDC address without code is refused, not read as a token with zero balances', async () => {
		const message = await messageOf(assertLocalAnvil(probe({ noCodeAt: manifest.usdc }), manifest));
		expect(message).toContain('usdc');
	});
});
