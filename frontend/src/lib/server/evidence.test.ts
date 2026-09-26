import { afterEach, beforeEach, describe, expect, spyOn, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { ActionResponse, ChainState } from '../types';
import { fakeContext } from './context.test-helpers';
import { evidencePath, recordEvidence } from './evidence';

let dir: string;
beforeEach(() => (dir = mkdtempSync(join(tmpdir(), 'bailiff-evidence-'))));
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const mined: ActionResponse = {
	status: 'mined',
	txHash: `0x${'ab'.repeat(32)}`,
	detail: { action: 'crash', signer: null, call: 'market.setNav(85e18)', simulations: [] }
};
const reset: ActionResponse = {
	status: 'reset',
	snapshotId: '0xf',
	detail: {
		action: 'reset',
		signer: null,
		call: 'evm_revert(0xe) then evm_snapshot()',
		simulations: [],
		reset: { revertedTo: '0xe', blockNumber: '11782760', blockTimestamp: '1790000000' }
	}
};

function lines(snapshotFile: string) {
	return readFileSync(evidencePath(snapshotFile), 'utf8')
		.trim()
		.split('\n')
		.map((l) => JSON.parse(l));
}

describe('recordEvidence', () => {
	test('appends the action, and after a reset a branch header with the baseline', async () => {
		const snapshotFile = join(dir, 'anvil-snapshot.json');
		const { ctx } = fakeContext({ config: { snapshotFile } });
		await recordEvidence(ctx, '0xe', 'crash', mined, async () => ({}) as ChainState);
		await recordEvidence(ctx, '0xe', 'reset', reset, async () => ({ poolId: 'p' }) as ChainState);
		const [crash, resetLine, header] = lines(snapshotFile);
		expect(crash).toMatchObject({ kind: 'action', branch: '0xe', action: 'crash' });
		expect(crash.response.txHash).toBe(mined.txHash);
		expect(resetLine).toMatchObject({ kind: 'action', action: 'reset', branch: '0xe' });
		expect(header).toMatchObject({
			kind: 'branch',
			note: 'local Anvil reset, not a transaction',
			revertedTo: '0xe',
			snapshotId: '0xf',
			chainId: 31337,
			forkBlock: '11782723',
			sourceCommit: ctx.manifest.sourceCommit,
			baseline: { poolId: 'p' }
		});
		expect(statSync(evidencePath(snapshotFile)).mode & 0o777).toBe(0o600);
	});

	test('a failed baseline read still writes the header, with the reason', async () => {
		const snapshotFile = join(dir, 'anvil-snapshot.json');
		const { ctx } = fakeContext({ config: { snapshotFile } });
		await recordEvidence(ctx, '0xe', 'reset', reset, () => Promise.reject(new Error('rpc down')));
		const header = lines(snapshotFile)[1];
		expect(header.baseline).toBeNull();
		expect(header.baselineError).toContain('rpc down');
	});

	test('a write failure is logged, never thrown', async () => {
		const { ctx } = fakeContext({ config: { snapshotFile: join(dir, 'missing', 'x.json') } });
		const log = spyOn(console, 'error').mockImplementation(() => {});
		await expect(
			recordEvidence(ctx, null, 'crash', mined, async () => ({}) as ChainState)
		).resolves.toBeUndefined();
		expect(log).toHaveBeenCalledTimes(1);
		log.mockRestore();
	});
});
