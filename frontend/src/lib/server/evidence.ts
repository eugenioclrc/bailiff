/**
 * O4 evidence: each action outcome, and a header for each branch opened by a local reset, is
 * appended to evidence.jsonl next to SNAPSHOT_FILE. Receipts and reconciliations of a discarded
 * branch therefore survive the reset and a page reload. Only public chain data is written.
 */
import { appendFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { ActionName, ActionResponse, ChainState } from '../types';
import type { DemoContext } from './context';
import { describeForLog } from './guards';

export const EVIDENCE_FILE = 'evidence.jsonl';

export function evidencePath(snapshotFile: string): string {
	return join(dirname(snapshotFile), EVIDENCE_FILE);
}

export type ActionLine = {
	kind: 'action';
	at: string;
	/** Snapshot id of the branch the action ran on (before a reset, the discarded one). */
	branch: string | null;
	action: ActionName;
	response: ActionResponse;
};

export type BranchLine = {
	kind: 'branch';
	at: string;
	note: 'local Anvil reset, not a transaction';
	revertedTo: string | null;
	snapshotId: string | null;
	sourceCommit: string;
	chainId: number;
	forkBlock: string;
	forkBlockHash: string;
	blockNumber: string | null;
	blockTimestamp: string | null;
	baseline: ChainState | null;
	baselineError?: string;
};

export function actionLine(
	at: string,
	branch: string | null,
	action: ActionName,
	response: ActionResponse
): ActionLine {
	return { kind: 'action', at, branch, action, response };
}

export function branchLine(
	ctx: Pick<DemoContext, 'manifest'>,
	at: string,
	response: ActionResponse,
	baseline: ChainState | null,
	baselineError?: string
): BranchLine {
	const reset = response.detail.reset;
	const m = ctx.manifest;
	return {
		kind: 'branch',
		at,
		note: 'local Anvil reset, not a transaction',
		revertedTo: reset?.revertedTo ?? null,
		snapshotId: response.snapshotId ?? null,
		sourceCommit: m.sourceCommit,
		chainId: m.chainId,
		forkBlock: m.forkBlock,
		forkBlockHash: m.forkBlockHash,
		blockNumber: reset?.blockNumber ?? null,
		blockTimestamp: reset?.blockTimestamp ?? null,
		baseline,
		...(baselineError ? { baselineError } : {})
	};
}

export async function appendEvidence(
	path: string,
	lines: readonly (ActionLine | BranchLine)[]
): Promise<void> {
	const text = lines.map((line) => JSON.stringify(line)).join('\n');
	await appendFile(path, `${text}\n`, { mode: 0o600 });
}

/**
 * Records one action and, after a reset, the new branch's baseline. Never throws: the action has
 * already happened, so a failed write is logged and the response still goes back to the page.
 */
export async function recordEvidence(
	ctx: DemoContext,
	branch: string | null,
	action: ActionName,
	response: ActionResponse,
	readBaseline: () => Promise<ChainState>
): Promise<void> {
	const at = new Date().toISOString();
	try {
		const lines: (ActionLine | BranchLine)[] = [actionLine(at, branch, action, response)];
		if (response.status === 'reset') {
			try {
				lines.push(branchLine(ctx, at, response, await readBaseline()));
			} catch (err) {
				lines.push(branchLine(ctx, at, response, null, describeForLog(err)));
			}
		}
		await appendEvidence(evidencePath(ctx.config.snapshotFile), lines);
	} catch (err) {
		console.error(`[bailiff] evidence not written for ${action}: ${describeForLog(err)}`);
	}
}
