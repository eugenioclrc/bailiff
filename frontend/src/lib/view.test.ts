import { describe, expect, test } from 'bun:test';
import type { ActionResponse, ReadValue } from './types';
import {
	argUnit,
	emitterName,
	healthStatus,
	showFlags,
	showRead,
	statusLabel,
	summarize
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
		expect(showRead(undefined, 'usdc').tone).toBe('failed');
	});

	test('flags read as names', () => {
		expect(showFlags({ ok: true, value: 0x8003 }).text).toBe('HOLDER, SWAP, LIQUIDITY');
		expect(showFlags({ ok: true, value: 0 }).text).toBe('NONE');
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
		expect(statusLabel(response({ status: 'mined', txHash: '0x1' }))).toBe('Mined transaction');
		expect(statusLabel(response({ status: 'simulation-reverted' }))).toBe(
			'Simulation: would revert'
		);
		expect(statusLabel(response({ status: 'reset' }))).toBe('Local reset, not a transaction');
		expect(statusLabel(response({ status: 'mined', error: { name: 'X', message: 'm' } }))).toBe(
			'Mined, reverted on-chain'
		);
	});
});

describe('summarize', () => {
	test('announces the outcome in words', () => {
		expect(summarize('crash', response({ status: 'mined', txHash: '0xabc' }))).toBe(
			'Cut NAV to 85: mined transaction 0xabc.'
		);
		expect(
			summarize(
				'horizon',
				response({ status: 'simulation-reverted', error: { name: 'NotAllowlisted', message: '' } })
			)
		).toBe(
			'Simulate direct liquidation: simulation would revert with NotAllowlisted. Nothing was sent.'
		);
		expect(summarize('reset', response({ status: 'reset', snapshotId: '0x3' }))).toBe(
			'Local reset to the healthy snapshot; new snapshot 0x3. Timeline cleared.'
		);
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
		expect(argUnit('market', 'NavUpdated', 'timestamp', true)).toBe('raw');
	});

	test('names emitters for people', () => {
		expect(emitterName('poolManager')).toBe('PoolManager');
		expect(emitterName('0xabc')).toBe('0xabc');
	});
});
