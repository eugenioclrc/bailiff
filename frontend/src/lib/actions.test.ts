import { describe, expect, test } from 'bun:test';
import { ACTION_LABELS, parseActionBody } from './actions';
import { ACTIONS } from './types';

describe('parseActionBody', () => {
	test('accepts each of the seven actions', () => {
		for (const action of ACTIONS) {
			expect(parseActionBody({ action })).toEqual({ ok: true, action });
		}
	});

	test('rejects unknown action values', () => {
		for (const action of ['Crash', 'liquidate', '', 'reset ', 1, null, true, ['crash']]) {
			expect(parseActionBody({ action }).ok).toBe(false);
		}
	});

	test('rejects any extra key, even with a valid action', () => {
		const extra = [
			{ action: 'crash', nav: '1' },
			{ action: 'liquidateChunk', repayAssets: '1' },
			{ action: 'revoke', to: '0x0000000000000000000000000000000000000001' }
		];
		for (const body of extra) {
			const result = parseActionBody(body);
			expect(result.ok).toBe(false);
		}
	});

	test('rejects non-object bodies', () => {
		for (const body of [null, undefined, 'crash', 7, [], [{ action: 'crash' }]]) {
			expect(parseActionBody(body).ok).toBe(false);
		}
	});

	test('rejects inherited or prototype keys', () => {
		const body = Object.create({ action: 'crash' });
		expect(parseActionBody(body).ok).toBe(false);
		expect(parseActionBody(JSON.parse('{"__proto__": {"action": "crash"}}')).ok).toBe(false);
	});

	test('every action has a label', () => {
		for (const action of ACTIONS) expect(ACTION_LABELS[action].length).toBeGreaterThan(0);
	});
});
