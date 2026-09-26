import { describe, expect, test } from 'bun:test';
import type { ActionResponse, ReadValue } from './types';
import {
	argUnit,
	atHealthyBaseline,
	callParts,
	emitterName,
	healthStatus,
	showBool,
	showFlags,
	showRead,
	probeStatusLabel,
	probeSummary,
	statusLabel,
	summarize,
	syncText
} from './view';

const ok = (value: string): ReadValue => ({ ok: true, value });
const missing: ReadValue = { ok: false, reason: 'not-implemented', message: 'not implemented yet' };
const failed: ReadValue = { ok: false, reason: 'reverted', message: 'Healthy(...)' };

function response(partial: Partial<ActionResponse>): ActionResponse {
	return {
		status: 'mined',
		detail: { action: 'crash', signer: null, call: 'market.setNav(85e18)', simulations: [] },
		...partial
	};
}

describe('showRead', () => {
	test('formats values and never turns a missing getter into zero', () => {
		expect(showRead(ok('75000000000'), 'usdc')).toEqual({ text: '75,000.00', tone: 'value' });
		expect(showRead(missing, 'usdc')).toEqual({ text: 'not implemented yet', tone: 'missing' });
		expect(showRead(failed, 'usdc')).toEqual({ text: 'read failed', tone: 'failed' });
	});

	test('a value not read yet is not reported as a failed read', () => {
		const notRead = { text: 'not read yet', tone: 'missing' };
		expect(showRead(undefined, 'usdc')).toEqual(notRead);
		expect(showFlags(undefined)).toEqual(notRead);
		expect(showBool(undefined, 'yes', 'no')).toEqual(notRead);
	});

	test('flags read as names', () => {
		expect(showFlags({ ok: true, value: 0x8003 }).text).toBe('HOLDER, SWAP, LIQUIDITY');
		expect(showFlags({ ok: true, value: 0 }).text).toBe('NONE');
	});
});

describe('callParts', () => {
	const shape = (call: string) => callParts(call).map(({ kind, text }) => ({ kind, text }));

	test('parts are keyed by their offset in the call', () => {
		expect(callParts('market.setNav(85e18)').map((p) => p.at)).toEqual([0, 14, 19]);
	});

	test('hex goes to code, amounts to figures, identifiers stay text', () => {
		expect(shape('adapter.liquidate(borrower, maxUint256, minBounty 4,365.00 USDC)')).toEqual([
			{ kind: 'text', text: 'adapter.liquidate(borrower, maxUint256, minBounty ' },
			{ kind: 'num', text: '4,365.00' },
			{ kind: 'text', text: ' USDC)' }
		]);
		expect(shape('market.setNav(85e18)')).toEqual([
			{ kind: 'text', text: 'market.setNav(' },
			{ kind: 'num', text: '85e18' },
			{ kind: 'text', text: ')' }
		]);
		expect(shape('evm_revert(0x1f) then evm_snapshot() on the local Anvil')).toEqual([
			{ kind: 'text', text: 'evm_revert(' },
			{ kind: 'hex', text: '0x1f' },
			{ kind: 'text', text: ') then evm_snapshot() on the local Anvil' }
		]);
	});

	test('signed and scientific amounts stay whole', () => {
		expect(
			shape('desk.modifyLiquidity(poolKey, -887220, 887220, -4.75e17)').filter(
				(p) => p.kind === 'num'
			)
		).toEqual([
			{ kind: 'num', text: '-887220' },
			{ kind: 'num', text: '887220' },
			{ kind: 'num', text: '-4.75e17' }
		]);
	});
});

describe('syncText', () => {
	const state = {
		block: { number: '11782757' },
		navStatus: { ageSeconds: '162' }
	} as unknown as Parameters<typeof syncText>[0];

	test('names the local chain, not a live network', () => {
		expect(syncText(state, false, null)).toBe(
			'Local chain at block 11782757, NAV\u00a0set\u00a02m\u00a042s\u00a0ago'
		);
	});

	test('the NAV age never breaks across lines', () => {
		const text = syncText(state, false, null);
		expect(text.slice(text.indexOf('NAV'))).not.toMatch(/ /);
	});

	test('a failed read wins over a pending refresh, so the header never waits forever', () => {
		expect(syncText(state, true, 'down')).toBe(
			'Read failed after the last action: figures predate it'
		);
		expect(syncText(state, false, 'down')).toBe('Last good read at local block 11782757');
		expect(syncText(state, true, null)).toBe('Updating after the last action…');
	});

	test('before the first read it says whether the read is running or failed', () => {
		expect(syncText(null, false, null)).toBe('Reading chain state…');
		expect(syncText(null, false, 'down')).toBe('No chain state yet');
	});
});

describe('healthStatus', () => {
	test('classifies the health factor', () => {
		expect(healthStatus(ok('1066666666666666666'))).toBe('healthy');
		expect(healthStatus(ok('906666666666666666'))).toBe('liquidatable');
		expect(healthStatus(ok((2n ** 256n - 1n).toString()))).toBe('no-debt');
		expect(healthStatus(missing)).toBe('unknown');
	});
});

describe('statusLabel', () => {
	test('never presents a simulation or a reset as a transaction', () => {
		expect(statusLabel(response({ status: 'mined', txHash: '0x1' }))).toBe('Mined on local Anvil');
		expect(statusLabel(response({ status: 'simulation-reverted' }))).toBe(
			'Simulation: would revert'
		);
		expect(statusLabel(response({ status: 'reset' }))).toBe('Local reset, not a transaction');
		expect(statusLabel(response({ status: 'mined', error: { name: 'X', message: 'm' } }))).toBe(
			'Mined on local Anvil, reverted'
		);
	});

	test('a recorded adapter quote is a simulation either way', () => {
		expect(probeStatusLabel({ repayAssets: '1', ok: true, bounty: '4500000000' })).toBe(
			'Simulation: would succeed'
		);
		expect(
			probeStatusLabel({
				repayAssets: '1',
				ok: false,
				error: { name: 'Unauthorized', message: '' }
			})
		).toBe('Simulation: would revert');
	});
});

describe('summarize', () => {
	test('announces the outcome in words', () => {
		expect(summarize('crash', response({ status: 'mined', txHash: '0xabc' }))).toBe(
			'Cut NAV to 85: mined on local Anvil, transaction 0xabc.'
		);
		expect(
			summarize(
				'horizon',
				response({ status: 'simulation-reverted', error: { name: 'NotAllowlisted', message: '' } })
			)
		).toBe('Simulate direct route: simulation would revert with NotAllowlisted. Nothing was sent.');
		expect(summarize('reset', response({ status: 'reset', snapshotId: '0x3' }))).toBe(
			'Local reset to the healthy snapshot; new snapshot 0x3. The previous branch moved to earlier branches.'
		);
	});

	test('announces a recorded adapter quote without claiming a send', () => {
		expect(probeSummary({ repayAssets: '1', ok: true, bounty: '4500000000' })).toBe(
			'Adapter route simulation would succeed with a 4,500.00 USDC bounty. Nothing was sent.'
		);
		expect(
			probeSummary({ repayAssets: '1', ok: false, error: { name: 'Unauthorized', message: '' } })
		).toBe('Adapter route simulation would revert with Unauthorized. Nothing was sent.');
	});
});

describe('atHealthyBaseline', () => {
	const chain = (nav: string, wrapper: boolean) =>
		({
			market: { nav: ok(nav) },
			permissions: { adapterWrapper: { ok: true, value: wrapper } }
		}) as unknown as Parameters<typeof atHealthyBaseline>[0];

	test('is true only at NAV 100 with the adapter wrapper allowed', () => {
		expect(atHealthyBaseline(chain('100000000000000000000', true))).toBe(true);
		expect(atHealthyBaseline(chain('85000000000000000000', true))).toBe(false);
		expect(atHealthyBaseline(chain('100000000000000000000', false))).toBe(false);
	});

	test('an unread state is not the baseline', () => {
		expect(atHealthyBaseline(null)).toBe(false);
		const unread = {
			market: { nav: missing },
			permissions: { adapterWrapper: { ok: true, value: true } }
		} as unknown as Parameters<typeof atHealthyBaseline>[0];
		expect(atHealthyBaseline(unread)).toBe(false);
	});
});

describe('argUnit', () => {
	test('picks token decimals from the emitter and argument', () => {
		expect(argUnit('usdc', 'Transfer', 'value', true)).toBe('usdc');
		expect(argUnit('rwa', 'Transfer', 'value', true)).toBe('rwa');
		expect(argUnit('pa', 'Transfer', 'value', true)).toBe('rwa');
		expect(argUnit('adapter', 'Liquidated', 'seized', true)).toBe('rwa');
		expect(argUnit('adapter', 'Liquidated', 'bounty', true)).toBe('usdc');
		expect(argUnit('hook', 'Swap', 'amount0', true)).toBe('rwa');
		expect(argUnit('poolManager', 'Swap', 'amount1', true)).toBe('usdc');
		expect(argUnit('poolManager', 'Swap', 'amount0', false)).toBe('usdc');
		expect(argUnit('market', 'NavUpdated', 'nav', true)).toBe('wad');
	});

	test('integers that are not amounts print as the chain returns them, with no grouping', () => {
		expect(argUnit('market', 'NavUpdated', 'timestamp', true)).toBe('int');
		for (const arg of ['tick', 'sqrtPriceX96', 'liquidity', 'fee']) {
			expect(argUnit('hook', 'Swap', arg, true)).toBe('int');
		}
		for (const arg of ['tickLower', 'tickUpper', 'liquidityDelta']) {
			expect(argUnit('poolManager', 'ModifyLiquidity', arg, true)).toBe('int');
		}
		expect(argUnit('poolManager', 'Initialize', 'tickSpacing', true)).toBe('int');
		expect(argUnit('poolManager', 'ProtocolFeeUpdated', 'protocolFee', true)).toBe('int');
		expect(argUnit('poolManager', 'Transfer', 'id', true)).toBe('int');
		expect(argUnit('rwa', 'FlagsSet', 'flags', true)).toBe('int');
	});

	test('an unnamed integer still falls back to the grouped raw unit', () => {
		expect(argUnit('market', 'Supplied', 'shares', true)).toBe('raw');
	});

	test('names emitters for people', () => {
		expect(emitterName('poolManager')).toBe('PoolManager');
		expect(emitterName('0xabc')).toBe('0xabc');
	});
});
