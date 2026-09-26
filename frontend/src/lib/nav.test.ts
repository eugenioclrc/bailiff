import { describe, expect, test } from 'bun:test';
import { liquidationGate, navStatus } from './nav';

const NAV = 85n * 10n ** 18n;
const DAY = 86_400n;
const SET_AT = 1_790_382_705n;

describe('navStatus', () => {
	test('fresh up to and including navUpdatedAt + MAX_STALENESS, as MiniLend checks it', () => {
		const inputs = { nav: NAV, updatedAt: SET_AT, maxStaleness: DAY };
		expect(navStatus(inputs, SET_AT + 19n, 9900)).toEqual({
			fresh: true,
			ageSeconds: '19',
			floor: '84150000000000000000'
		});
		expect(navStatus(inputs, SET_AT + DAY, 9900).fresh).toBe(true);
		expect(navStatus(inputs, SET_AT + DAY + 1n, 9900).fresh).toBe(false);
	});

	test('unknown when any input is missing', () => {
		expect(navStatus({ nav: NAV, updatedAt: SET_AT }, SET_AT, 9900)).toEqual({
			fresh: null,
			ageSeconds: null,
			floor: null
		});
	});
});

describe('liquidationGate', () => {
	test('open while the NAV is fresh', () => {
		expect(liquidationGate({ fresh: true, ageSeconds: '5', floor: '1' }, DAY)).toEqual({
			enabled: true,
			reason: null
		});
	});

	test('closed with the reason when the NAV is stale', () => {
		const gate = liquidationGate({ fresh: false, ageSeconds: '90000', floor: '1' }, DAY);
		expect(gate.enabled).toBe(false);
		expect(gate.reason).toBe(
			'NAV is stale: last update 1d 1h ago, limit 1d. MiniLend would revert with StaleNav.'
		);
	});

	test('closed when the NAV cannot be read', () => {
		const gate = liquidationGate({ fresh: null, ageSeconds: null, floor: null }, undefined);
		expect(gate).toEqual({
			enabled: false,
			reason: 'NAV could not be read, so liquidation is disabled.'
		});
	});
});
