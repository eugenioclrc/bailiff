/** Unit tests never see the demo keys or reach Anvil: see bunfig.toml and scripts/test-preload.ts. */
import { describe, expect, spyOn, test } from 'bun:test';
import { env } from '$env/dynamic/private';
import { ConfigError } from './config';
import { loadContext } from './context';

const DEMO_VARIABLES = [
	'DEMO_MODE',
	'ANVIL_RPC',
	'ISSUER_PK',
	'MM_PK',
	'KEEPER_PK',
	'DEPLOYMENT_FILE',
	'SNAPSHOT_FILE',
	'EVIDENCE_FILE'
];

describe.skipIf(process.env.BAILIFF_INTEGRATION === '1')('unit test environment', () => {
	// Booleans and names only, so a failing run never prints a key.
	test('$env/dynamic/private is a fixed empty env, not process.env', () => {
		expect(env === process.env).toBe(false);
		expect(DEMO_VARIABLES.filter((name) => env[name] !== undefined)).toEqual([]);
	});

	test('loadContext refuses at DEMO_MODE before any request leaves the process', async () => {
		const fetchSpy = spyOn(globalThis, 'fetch').mockImplementation(() =>
			Promise.reject(new TypeError('unit tests must not reach the network'))
		);
		try {
			const refused = loadContext();
			await expect(refused).rejects.toBeInstanceOf(ConfigError);
			await expect(refused).rejects.toThrow('DEMO_MODE');
			expect(fetchSpy).toHaveBeenCalledTimes(0);
		} finally {
			fetchSpy.mockRestore();
		}
	});
});
