import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { chmodSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fakeContext, MANIFEST_JSON } from './context.test-helpers';
import { HttpFailure } from './guards';
import { currentBranch, resetToBaseline } from './reset';

let dir: string;
let deploymentFile: string;
let snapshotFile: string;

function writeRecord(snapshotId: string, overrides: Record<string, unknown> = {}) {
	const record = {
		snapshotId,
		chainId: 31337,
		sourceCommit: MANIFEST_JSON.sourceCommit,
		manifestPath: deploymentFile,
		...overrides
	};
	writeFileSync(snapshotFile, JSON.stringify(record), { mode: 0o600 });
}

function rpc(answers: Record<string, unknown>) {
	return fakeContext({
		config: { deploymentFile, snapshotFile },
		request: async (method) => {
			if (!(method in answers)) throw new Error(`unexpected ${method}`);
			return answers[method];
		}
	});
}

async function failureOf(promise: Promise<unknown>): Promise<HttpFailure> {
	try {
		await promise;
	} catch (err) {
		if (err instanceof HttpFailure) return err;
		throw err;
	}
	throw new Error('expected an HttpFailure');
}

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), 'bailiff-reset-'));
	deploymentFile = join(dir, 'anvil.json');
	snapshotFile = join(dir, 'anvil-snapshot.json');
	writeFileSync(deploymentFile, JSON.stringify(MANIFEST_JSON));
});

afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('resetToBaseline', () => {
	test('reverts, snapshots again and persists the new id with mode 600', async () => {
		writeRecord('0xe');
		const fake = rpc({ evm_revert: true, evm_snapshot: '0xf' });
		const response = await resetToBaseline(fake.ctx);
		expect(fake.requests.map((r) => r.method)).toEqual(['evm_revert', 'evm_snapshot']);
		expect(fake.requests[0].params).toEqual(['0xe']);
		expect(response).toMatchObject({ status: 'reset', snapshotId: '0xf' });
		expect(response.txHash).toBeUndefined();
		expect(response.detail.reset?.revertedTo).toBe('0xe');
		const saved = JSON.parse(readFileSync(snapshotFile, 'utf8'));
		expect(saved.snapshotId).toBe('0xf');
		expect(saved.manifestPath).toBe(deploymentFile);
		expect(statSync(snapshotFile).mode & 0o777).toBe(0o600);
		expect(readdirSync(dir).filter((f) => f.endsWith('.tmp'))).toEqual([]);
	});

	test('evm_revert returning false is a 409 and leaves the file untouched', async () => {
		writeRecord('0xe');
		const before = readFileSync(snapshotFile, 'utf8');
		const failure = await failureOf(resetToBaseline(rpc({ evm_revert: false }).ctx));
		expect(failure.status).toBe(409);
		expect(readFileSync(snapshotFile, 'utf8')).toBe(before);
	});

	test('a missing new snapshot id is reported with chainReset, since the revert happened', async () => {
		writeRecord('0xe');
		const failure = await failureOf(
			resetToBaseline(rpc({ evm_revert: true, evm_snapshot: null }).ctx)
		);
		expect(failure.status).toBe(500);
		expect(failure.extra).toEqual({ chainReset: true });
	});

	test('an unwritable snapshot directory names the new id and flags chainReset', async () => {
		writeRecord('0xe');
		chmodSync(dir, 0o500);
		try {
			const failure = await failureOf(
				resetToBaseline(rpc({ evm_revert: true, evm_snapshot: '0x10' }).ctx)
			);
			expect(failure.status).toBe(500);
			expect(failure.message).toContain('0x10');
			expect(failure.extra).toEqual({ chainReset: true });
		} finally {
			chmodSync(dir, 0o700);
		}
		expect(JSON.parse(readFileSync(snapshotFile, 'utf8')).snapshotId).toBe('0xe');
	});

	test('a record for another manifest or commit is refused before any RPC', async () => {
		writeRecord('0xe', { manifestPath: join(dir, 'other.json') });
		const fake = rpc({});
		await expect(resetToBaseline(fake.ctx)).rejects.toThrow('another manifest');
		writeRecord('0xe', { sourceCommit: 'f'.repeat(40) });
		await expect(resetToBaseline(fake.ctx)).rejects.toThrow('sourceCommit');
		expect(fake.requests).toEqual([]);
	});
});

describe('currentBranch', () => {
	test('names the saved snapshot, or null when the file is unusable', async () => {
		writeRecord('0x2a');
		const { ctx } = rpc({});
		expect(await currentBranch(ctx)).toBe('0x2a');
		writeFileSync(snapshotFile, 'not json');
		expect(await currentBranch(ctx)).toBeNull();
	});
});
