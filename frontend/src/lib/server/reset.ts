/**
 * O4 reset: evm_revert(snapshotId) must return true, then evm_snapshot, then the new id is written
 * back to SNAPSHOT_FILE (each revert consumes the snapshot). This is a local RPC procedure, not a
 * transaction, and the response says so.
 */
import { readFile, rename, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { ActionResponse } from '../types';
import { rpc } from './chain';
import { ConfigError, parseSnapshotRecord, type SnapshotRecord } from './config';
import type { DemoContext } from './context';
import { HttpFailure } from './guards';

const SNAPSHOT_ID = /^0x[0-9a-fA-F]+$/;

async function readRecord(ctx: DemoContext): Promise<SnapshotRecord> {
	let text: string;
	try {
		text = await readFile(ctx.config.snapshotFile, 'utf8');
	} catch {
		throw new ConfigError('SNAPSHOT_FILE cannot be read.');
	}
	let record: SnapshotRecord;
	try {
		record = parseSnapshotRecord(JSON.parse(text));
	} catch (err) {
		if (err instanceof ConfigError) throw err;
		throw new ConfigError('SNAPSHOT_FILE is not valid JSON.');
	}
	if (resolve(record.manifestPath) !== resolve(ctx.config.deploymentFile)) {
		throw new ConfigError('SNAPSHOT_FILE belongs to another manifest than DEPLOYMENT_FILE.');
	}
	if (record.sourceCommit !== ctx.manifest.sourceCommit) {
		throw new ConfigError('SNAPSHOT_FILE sourceCommit does not match the manifest.');
	}
	return record;
}

/** Write-then-rename so a crash never leaves a half-written snapshot file. */
async function writeRecord(path: string, record: SnapshotRecord): Promise<void> {
	const temp = `${path}.${process.pid}.tmp`;
	await writeFile(temp, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
	await rename(temp, path);
}

export async function resetToBaseline(ctx: DemoContext): Promise<ActionResponse> {
	const record = await readRecord(ctx);
	const reverted = await rpc<unknown>(ctx, 'evm_revert', [record.snapshotId]);
	if (reverted !== true) {
		throw new HttpFailure(
			409,
			`evm_revert(${record.snapshotId}) returned ${String(reverted)}: the baseline snapshot is gone. Redeploy the local fixture to rebuild it.`
		);
	}
	const next = await rpc<unknown>(ctx, 'evm_snapshot');
	if (typeof next !== 'string' || !SNAPSHOT_ID.test(next)) {
		throw new HttpFailure(
			500,
			'The chain is back at the baseline, but evm_snapshot returned no id. Redeploy before the next reset.'
		);
	}
	try {
		await writeRecord(ctx.config.snapshotFile, { ...record, snapshotId: next as `0x${string}` });
	} catch {
		throw new HttpFailure(
			500,
			`The chain is back at the baseline and snapshot ${next} was taken, but SNAPSHOT_FILE could not be written. Set its snapshotId to ${next}.`
		);
	}
	const block = await ctx.client.getBlock();
	return {
		status: 'reset',
		snapshotId: next,
		detail: {
			action: 'reset',
			signer: null,
			call: `evm_revert(${record.snapshotId}) then evm_snapshot() on the local Anvil`,
			simulations: [],
			reset: {
				revertedTo: record.snapshotId,
				blockNumber: block.number.toString(),
				blockTimestamp: block.timestamp.toString()
			}
		}
	};
}
