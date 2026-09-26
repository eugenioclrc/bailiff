import { afterEach, beforeEach, describe, expect, spyOn, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { ActionResponse, ChainState } from '../types';
import { fakeContext } from './context.test-helpers';
import { recordEvidence, recordFailure } from './evidence';
import { HttpFailure } from './guards';

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

function lines(evidenceFile: string) {
	return readFileSync(evidenceFile, 'utf8')
		.trim()
		.split('\n')
		.map((l) => JSON.parse(l));
}

describe('recordEvidence', () => {
	test('appends the action, and after a reset a branch header with the baseline', async () => {
		const evidenceFile = join(dir, 'evidence.jsonl');
		const { ctx } = fakeContext({ config: { evidenceFile } });
		await recordEvidence(ctx, '0xe', 'crash', mined, async () => ({}) as ChainState);
		await recordEvidence(ctx, '0xe', 'reset', reset, async () => ({ poolId: 'p' }) as ChainState);
		const [crash, resetLine, header] = lines(evidenceFile);
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
		expect(header.blockNumber).toBe('11782760');
		expect(statSync(evidenceFile).mode & 0o777).toBe(0o600);
	});

	test('a failed baseline read still writes the header, with the reason', async () => {
		const evidenceFile = join(dir, 'evidence.jsonl');
		const { ctx } = fakeContext({ config: { evidenceFile } });
		await recordEvidence(ctx, '0xe', 'reset', reset, () => Promise.reject(new Error('rpc down')));
		const header = lines(evidenceFile)[1];
		expect(header.baseline).toBeNull();
		expect(header.baselineError).toContain('rpc down');
	});

	test('a write failure is logged, never thrown', async () => {
		const { ctx } = fakeContext({ config: { evidenceFile: join(dir, 'missing', 'x.jsonl') } });
		const log = spyOn(console, 'error').mockImplementation(() => {});
		await expect(
			recordEvidence(ctx, null, 'crash', mined, async () => ({}) as ChainState)
		).resolves.toBeUndefined();
		expect(log).toHaveBeenCalledTimes(1);
		log.mockRestore();
	});

	test('a reset that reverted the chain and then failed gets an action line and a branch header', async () => {
		const evidenceFile = join(dir, 'evidence.jsonl');
		const { ctx } = fakeContext({ config: { evidenceFile } });
		const failure = new HttpFailure(
			500,
			'The chain is back at the baseline, but evm_snapshot returned no id. Redeploy before the next reset.',
			{ chainReset: true }
		);
		await recordFailure(ctx, '0xe', 'reset', failure, async () => ({ poolId: 'p' }) as ChainState);
		const [action, header] = lines(evidenceFile);
		expect(action).toMatchObject({
			kind: 'action',
			branch: '0xe',
			action: 'reset',
			response: { status: 'http-error', httpStatus: 500, chainReset: true }
		});
		expect(action.response.message).toContain('evm_snapshot returned no id');
		expect(header).toMatchObject({
			kind: 'branch',
			note: 'local Anvil reset, not a transaction',
			revertedTo: '0xe',
			snapshotId: null,
			baseline: { poolId: 'p' }
		});
	});

	test('a snapshot taken but not saved keeps its id in the header', async () => {
		const evidenceFile = join(dir, 'evidence.jsonl');
		const { ctx } = fakeContext({ config: { evidenceFile } });
		const failure = new HttpFailure(500, 'SNAPSHOT_FILE could not be written.', {
			chainReset: true,
			snapshotId: '0x10'
		});
		await recordFailure(ctx, '0xe', 'reset', failure, async () => ({}) as ChainState);
		expect(lines(evidenceFile)[1]).toMatchObject({ revertedTo: '0xe', snapshotId: '0x10' });
	});

	test('a refused reset (evm_revert false) is one action line, with no branch header', async () => {
		const evidenceFile = join(dir, 'evidence.jsonl');
		const { ctx } = fakeContext({ config: { evidenceFile } });
		let reads = 0;
		const failure = new HttpFailure(409, 'evm_revert(0xe) returned false');
		await recordFailure(ctx, '0xe', 'reset', failure, async () => {
			reads += 1;
			return {} as ChainState;
		});
		const written = lines(evidenceFile);
		expect(written).toHaveLength(1);
		expect(written[0].response).toEqual({
			status: 'http-error',
			httpStatus: 409,
			message: 'evm_revert(0xe) returned false'
		});
		expect(reads).toBe(0);
	});

	test('a lost receipt keeps the transaction hash in the evidence', async () => {
		const evidenceFile = join(dir, 'evidence.jsonl');
		const { ctx } = fakeContext({ config: { evidenceFile } });
		const hash = `0x${'cd'.repeat(32)}`;
		const failure = new HttpFailure(502, `Sent ${hash} but no receipt arrived.`, { txHash: hash });
		await recordFailure(ctx, '0xe', 'liquidateFull', failure, async () => ({}) as ChainState);
		expect(lines(evidenceFile)[0].response).toMatchObject({ httpStatus: 502, txHash: hash });
	});
});
