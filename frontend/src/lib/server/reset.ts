/**
 * O4 reset: evm_revert(snapshotId) must return true, then evm_snapshot, then the new id is written
 * back to SNAPSHOT_FILE (each revert consumes the snapshot). Between the two, the reverted chain is
 * checked against the O3 baseline so a stray transaction is never saved into the new snapshot.
 * This is a local RPC procedure, not a transaction, and the response says so.
 */
import { readFile, rename, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { Abi } from 'viem';
import { miniLendAbi, paAbi, stateViewAbi } from '../abis.generated';
import type { ActionResponse } from '../types';
import { readMany, rpc, type ReadCall } from './chain';
import { ConfigError, parseSnapshotRecord, type SnapshotRecord } from './config';
import type { DemoContext } from './context';
import { HttpFailure, describeForLog } from './guards';

const SNAPSHOT_ID = /^0x[0-9a-fA-F]+$/;
/** The revert already happened: the page must drop the old branch even though this is an error. */
const CHAIN_RESET = { chainReset: true } as const;

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

/** Snapshot id of the current branch; every reset writes a new one. null when the file is unusable. */
export async function currentBranch(ctx: DemoContext): Promise<string | null> {
	try {
		return (await readRecord(ctx)).snapshotId;
	} catch {
		return null;
	}
}

/** Write-then-rename so a crash never leaves a half-written snapshot file. */
async function writeRecord(path: string, record: SnapshotRecord): Promise<void> {
	const temp = `${path}.${process.pid}.tmp`;
	await writeFile(temp, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
	await rename(temp, path);
}

/** O3/O4 healthy baseline: NAV 100, borrower 1000 RWA / 75,000 USDC, adapter wrapper on, L 5e17. */
export const BASELINE = {
	nav: 100n * 10n ** 18n,
	collateral: 1_000n * 10n ** 18n,
	debt: 75_000n * 10n ** 6n
} as const;

function baselineCalls(ctx: DemoContext): ReadCall[] {
	const m = ctx.manifest;
	return [
		{ key: 'nav', address: m.market, abi: miniLendAbi as Abi, functionName: 'nav' },
		{
			key: 'position',
			address: m.market,
			abi: miniLendAbi as Abi,
			functionName: 'positions',
			args: [m.borrower]
		},
		{
			key: 'wrapper',
			address: m.pa,
			abi: paAbi as Abi,
			functionName: 'allowedWrappers',
			args: [m.adapter]
		},
		{
			key: 'liquidity',
			address: m.stateView,
			abi: stateViewAbi as Abi,
			functionName: 'getLiquidity',
			args: [m.poolId]
		}
	];
}

/**
 * Names every baseline value the reverted chain does not show. A mismatch means someone sent a
 * transaction between evm_revert and here (a keeper, a second server, a manual cast send); taking
 * the snapshot now would save that transaction into every later reset.
 */
export async function baselineMismatches(ctx: DemoContext): Promise<string[] | null> {
	let reads: Awaited<ReturnType<typeof readMany>>;
	try {
		const block = await ctx.client.getBlock();
		reads = await readMany(ctx, baselineCalls(ctx), block.number);
	} catch (err) {
		console.error(`[bailiff] baseline check skipped after evm_revert: ${describeForLog(err)}`);
		return null;
	}
	const value = (key: string): unknown => {
		const read = reads[key];
		return read?.ok ? read.value : null;
	};
	const position = value('position') as readonly unknown[] | null;
	const checks: [string, unknown, unknown][] = [
		['NAV', value('nav'), BASELINE.nav],
		['borrower collateral', position?.[0] ?? null, BASELINE.collateral],
		['borrower debt', position?.[1] ?? null, BASELINE.debt],
		['adapter allowedWrapper', value('wrapper'), true],
		['pool liquidity', value('liquidity'), ctx.manifest.initialLiquidity]
	];
	return checks
		.filter(([, actual, expected]) => actual !== expected)
		.map(([name, actual]) => `${name} ${actual === null ? 'unreadable' : String(actual)}`);
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
	const mismatches = await baselineMismatches(ctx);
	if (mismatches?.length) {
		throw new HttpFailure(
			409,
			`The chain was reverted to ${record.snapshotId}, but it is not the healthy baseline (${mismatches.join('; ')}): another process sent a transaction during the reset. No new snapshot was taken. Stop other senders, then rerun the local deploy and seed (O4).`,
			CHAIN_RESET
		);
	}
	const next = await rpc<unknown>(ctx, 'evm_snapshot');
	if (typeof next !== 'string' || !SNAPSHOT_ID.test(next)) {
		throw new HttpFailure(
			500,
			'The chain is back at the baseline, but evm_snapshot returned no id. Redeploy before the next reset.',
			CHAIN_RESET
		);
	}
	try {
		await writeRecord(ctx.config.snapshotFile, { ...record, snapshotId: next as `0x${string}` });
	} catch {
		throw new HttpFailure(
			500,
			`The chain is back at the baseline and snapshot ${next} was taken, but SNAPSHOT_FILE could not be written. Set its snapshotId to ${next}.`,
			{ ...CHAIN_RESET, snapshotId: next }
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
