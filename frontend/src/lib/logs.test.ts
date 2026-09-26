import { describe, expect, test } from 'bun:test';
import type { Abi } from 'viem';
import { hookAbi, poolManagerAbi } from './abis.generated';
import { ADDR, POOL_ID, logContext, makeLog, preFixLiquidationLogs } from './fixtures.test-helpers';
import { decodeLogs } from './logs';

describe('decodeLogs', () => {
	test('orders by logIndex and names each emitter', () => {
		const decoded = decodeLogs(preFixLiquidationLogs(), logContext);
		expect(decoded.map((l) => l.logIndex)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
		expect(decoded[0]).toMatchObject({ emitter: 'poolManager', event: 'Swap' });
		expect(decoded[1]).toMatchObject({ emitter: 'hook', event: 'Swap' });
		expect(decoded[10]).toMatchObject({ emitter: 'adapter', event: 'Liquidated' });
		expect(decoded[5]).toMatchObject({ emitter: 'market', event: 'Liquidated' });
	});

	test('attributes Swap by emitter, poolId and sender', () => {
		const [pm, hook] = decodeLogs(preFixLiquidationLogs(), logContext);
		expect(hook.swap).toEqual({ emitter: 'hook', poolIdMatches: true, senderIsAdapter: true, canonical: true });
		expect(pm.swap).toEqual({
			emitter: 'poolManager',
			poolIdMatches: true,
			senderIsAdapter: true,
			canonical: false
		});
	});

	test('a hook Swap for another pool or sender is not canonical', () => {
		const args = {
			id: `0x${'11'.repeat(32)}`,
			sender: ADDR.desk,
			amount0: -1n,
			amount1: 1n,
			sqrtPriceX96: 1n,
			liquidity: 1n,
			tick: 0,
			fee: 3000
		};
		const [log] = decodeLogs([makeLog(ADDR.hook, hookAbi as Abi, 'Swap', args, 0)], logContext);
		expect(log.swap).toEqual({ emitter: 'hook', poolIdMatches: false, senderIsAdapter: false, canonical: false });
	});

	test('a Swap copy from an unrelated address is attributed to "other"', () => {
		const args = {
			id: POOL_ID,
			sender: ADDR.adapter,
			amount0: -1n,
			amount1: 1n,
			sqrtPriceX96: 1n,
			liquidity: 1n,
			tick: 0,
			fee: 3000
		};
		const imposter = '0x000000000000000000000000000000000000dEaD';
		const [log] = decodeLogs([makeLog(imposter, poolManagerAbi as Abi, 'Swap', args, 0)], logContext);
		expect(log.emitter).toBe('0x000000000000000000000000000000000000dEaD');
		expect(log.swap?.emitter).toBe('other');
		expect(log.swap?.canonical).toBe(false);
	});

	test('labels address arguments and keeps integers as decimal strings', () => {
		const decoded = decodeLogs(preFixLiquidationLogs(), logContext);
		const bounty = decoded.find((l) => l.logIndex === 8)!;
		expect(bounty.args).toEqual([
			{ name: 'from', type: 'address', value: ADDR.adapter, label: 'adapter' },
			{ name: 'to', type: 'address', value: ADDR.keeper, label: 'keeper' },
			{ name: 'value', type: 'uint256', value: '4500000000' }
		]);
	});

	test('an unknown topic stays undecoded but visible', () => {
		const [log] = decodeLogs(
			[{ address: ADDR.market, topics: [`0x${'ab'.repeat(32)}`], data: '0x', logIndex: 3 }],
			logContext
		);
		expect(log).toMatchObject({ logIndex: 3, emitter: 'market', event: null, signature: null, args: [] });
	});
});
