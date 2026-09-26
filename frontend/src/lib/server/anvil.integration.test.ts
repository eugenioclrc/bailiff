/**
 * Opt-in: BAILIFF_INTEGRATION=1 bun test src/lib/server/anvil.integration.test.ts
 * Runs crash, horizon and reset against the local Anvil named in .env, and ends on the baseline.
 * Never run it while the dev server or a keeper is signing with the same keys.
 */
import { describe, expect, test } from 'bun:test';
import { runAction } from './actions';
import { loadContext } from './context';
import { readState } from './state';

const enabled = process.env.BAILIFF_INTEGRATION === '1';

describe.skipIf(!enabled)('local Anvil walk: crash, horizon, reset', () => {
	test('each step returns its O5 status and reset restores the healthy baseline', async () => {
		const ctx = await loadContext();
		const baseline = await readState(ctx);
		expect(baseline.market.nav).toEqual({ ok: true, value: '100000000000000000000' });

		const crash = await runAction(ctx, 'crash');
		expect(crash.status).toBe('mined');
		expect(crash.txHash).toMatch(/^0x[0-9a-f]{64}$/);
		const crashed = await readState(ctx);
		expect(crashed.market.nav).toEqual({ ok: true, value: '85000000000000000000' });

		const horizon = await runAction(ctx, 'horizon');
		expect(horizon.status).toBe('simulation-reverted');
		expect(horizon.txHash).toBeUndefined();
		expect(horizon.error?.name).toBe('NotAllowlisted');

		const reset = await runAction(ctx, 'reset');
		expect(reset.status).toBe('reset');
		expect(reset.txHash).toBeUndefined();
		const restored = await readState(ctx);
		expect(restored.market.nav).toEqual(baseline.market.nav);
		expect(restored.market.debt).toEqual(baseline.market.debt);
		expect(restored.branch).toBe(reset.snapshotId ?? null);
	}, 60_000);
});
