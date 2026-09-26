import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
	RpcRequestError,
	encodeErrorResult,
	encodeFunctionData,
	encodeFunctionResult,
	maxUint256,
	type Hex
} from 'viem';
import { adapterAbi, errorsAbi } from '../abis.generated';
import { PROBE_CALL } from '../timeline';
import { fakeContext, type FakeOptions } from './context.test-helpers';
import { readProbe } from './state';

let dir: string;
beforeEach(() => (dir = mkdtempSync(join(tmpdir(), 'bailiff-probe-'))));
afterEach(() => rmSync(dir, { recursive: true, force: true }));

/** A fake context whose SNAPSHOT_FILE names branch 0xe, so the probe can report it. */
function onBranch(call: FakeOptions['call']) {
	const deploymentFile = join(dir, 'anvil.json');
	const snapshotFile = join(dir, 'anvil-snapshot.json');
	const fake = fakeContext({ call, config: { deploymentFile, snapshotFile } });
	const record = {
		snapshotId: '0xe',
		chainId: 31337,
		sourceCommit: fake.ctx.manifest.sourceCommit,
		manifestPath: deploymentFile
	};
	writeFileSync(snapshotFile, JSON.stringify(record));
	return fake;
}

const revertWith = (data: Hex) =>
	new RpcRequestError({
		body: { method: 'eth_call' },
		error: { code: 3, message: 'execution reverted', data },
		url: 'http://127.0.0.1:8545'
	});

describe('readProbe (O7 control pair)', () => {
	test('one keeper eth_call of adapter.liquidate(borrower, maxUint256, 0) on the pending block', async () => {
		const bounty = encodeFunctionResult({
			abi: adapterAbi,
			functionName: 'liquidate',
			result: 4_500_000_000n
		});
		const fake = onBranch(async () => ({ data: bounty }));
		const m = fake.ctx.manifest;
		const probe = await readProbe(fake.ctx);
		expect(fake.calls).toEqual([
			{
				account: m.keeper,
				to: m.adapter,
				data: encodeFunctionData({
					abi: adapterAbi,
					functionName: 'liquidate',
					args: [m.borrower, maxUint256, 0n]
				}),
				blockTag: 'pending'
			}
		]);
		expect(probe).toEqual({
			branch: '0xe',
			block: '101',
			from: m.keeper,
			call: PROBE_CALL,
			quote: { repayAssets: maxUint256.toString(), ok: true, bounty: '4500000000' }
		});
		expect(fake.sent).toEqual([]);
		expect(fake.requests).toEqual([]);
	});

	test('after a revoke the same call comes back as a decoded revert, and nothing is sent', async () => {
		const unauthorized = encodeErrorResult({ abi: errorsAbi, errorName: 'Unauthorized' });
		const fake = onBranch(() => Promise.reject(revertWith(unauthorized)));
		const probe = await readProbe(fake.ctx);
		expect(probe.quote.ok).toBe(false);
		expect(!probe.quote.ok && probe.quote.error.name).toBe('Unauthorized');
		expect(fake.calls).toHaveLength(1);
		expect(fake.sent).toEqual([]);
		expect(fake.requests).toEqual([]);
	});
});
