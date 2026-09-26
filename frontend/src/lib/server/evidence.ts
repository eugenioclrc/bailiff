/**
 * O4 evidence: each action outcome, and a header for each branch opened by a local reset, is
 * appended to EVIDENCE_FILE. Receipts and reconciliations of a discarded branch therefore survive
 * the reset and a page reload. Failed actions are recorded too: a reset that reverted the chain
 * but then failed, or a transaction whose receipt never arrived, still changed the chain.
 * The O7 adapter probe is appended too, marked as an eth_call. Only public chain data is written.
 */
import { appendFile } from 'node:fs/promises';
import type { ActionName, ActionResponse, ChainState, ProbeRecord } from '../types';
import type { DemoContext } from './context';
import { describeForLog, type HttpFailure } from './guards';

/** An action that ended as an HTTP error instead of an O5 status. */
export type FailedResponse = {
	status: 'http-error';
	httpStatus: number;
	message: string;
	/** The local revert happened before the failure: the previous branch is gone. */
	chainReset?: boolean;
	/** A transaction was sent, so it may have mined even though the action failed. */
	txHash?: string;
};

export type ActionLine = {
	kind: 'action';
	at: string;
	/** Snapshot id of the branch the action ran on (before a reset, the discarded one). */
	branch: string | null;
	action: ActionName;
	response: ActionResponse | FailedResponse;
};

/** Where a local reset left the chain. Unknown fields are null, never guessed. */
export type BranchInfo = {
	revertedTo: string | null;
	snapshotId: string | null;
	blockNumber: string | null;
	blockTimestamp: string | null;
};

export type BranchLine = BranchInfo & {
	kind: 'branch';
	at: string;
	note: 'local Anvil reset, not a transaction';
	sourceCommit: string;
	chainId: number;
	forkBlock: string;
	forkBlockHash: string;
	baseline: ChainState | null;
	baselineError?: string;
};

export type ProbeLine = ProbeRecord & {
	kind: 'probe';
	at: string;
	note: 'eth_call simulation, not a transaction';
};

type Line = ActionLine | BranchLine | ProbeLine;

export function actionLine(
	at: string,
	branch: string | null,
	action: ActionName,
	response: ActionResponse | FailedResponse
): ActionLine {
	return { kind: 'action', at, branch, action, response };
}

export function branchLine(
	ctx: Pick<DemoContext, 'manifest'>,
	at: string,
	info: BranchInfo,
	baseline: ChainState | null,
	baselineError?: string
): BranchLine {
	const m = ctx.manifest;
	return {
		kind: 'branch',
		at,
		note: 'local Anvil reset, not a transaction',
		...info,
		sourceCommit: m.sourceCommit,
		chainId: m.chainId,
		forkBlock: m.forkBlock,
		forkBlockHash: m.forkBlockHash,
		baseline,
		...(baselineError ? { baselineError } : {})
	};
}

export function probeLine(at: string, probe: ProbeRecord): ProbeLine {
	return { kind: 'probe', at, note: 'eth_call simulation, not a transaction', ...probe };
}

export function failedResponse(failure: HttpFailure): FailedResponse {
	const { chainReset, txHash } = failure.extra;
	return {
		status: 'http-error',
		httpStatus: failure.status,
		message: failure.message,
		...(chainReset === true ? { chainReset: true } : {}),
		...(typeof txHash === 'string' ? { txHash } : {})
	};
}

export async function appendEvidence(path: string, lines: readonly Line[]): Promise<void> {
	const text = lines.map((line) => JSON.stringify(line)).join('\n');
	await appendFile(path, `${text}\n`, { mode: 0o600 });
}

/** The new branch's header; a failed baseline read is recorded with its reason, not dropped. */
async function headerWithBaseline(
	ctx: DemoContext,
	at: string,
	info: BranchInfo,
	readBaseline: () => Promise<ChainState>
): Promise<BranchLine> {
	try {
		return branchLine(ctx, at, info, await readBaseline());
	} catch (err) {
		return branchLine(ctx, at, info, null, describeForLog(err));
	}
}

/**
 * Never throws: the action has already happened, so a failed write is logged and the response
 * still goes back to the page.
 */
async function write(ctx: DemoContext, action: ActionName, lines: () => Promise<Line[]>) {
	try {
		await appendEvidence(ctx.config.evidenceFile, await lines());
	} catch (err) {
		console.error(`[bailiff] evidence not written for ${action}: ${describeForLog(err)}`);
	}
}

/** Records one action and, after a reset, the new branch's baseline. */
export async function recordEvidence(
	ctx: DemoContext,
	branch: string | null,
	action: ActionName,
	response: ActionResponse,
	readBaseline: () => Promise<ChainState>
): Promise<void> {
	const at = new Date().toISOString();
	await write(ctx, action, async () => {
		const lines: Line[] = [actionLine(at, branch, action, response)];
		const reset = response.detail.reset;
		if (response.status === 'reset') {
			const info: BranchInfo = {
				revertedTo: reset?.revertedTo ?? null,
				snapshotId: response.snapshotId ?? null,
				blockNumber: reset?.blockNumber ?? null,
				blockTimestamp: reset?.blockTimestamp ?? null
			};
			lines.push(await headerWithBaseline(ctx, at, info, readBaseline));
		}
		return lines;
	});
}

/**
 * Records an action that ended as an HTTP error. When the failure says the chain was already
 * reverted (chainReset), the branch it opened gets a header too, with whatever snapshot id the
 * failure carries (null when evm_snapshot gave none).
 */
export async function recordFailure(
	ctx: DemoContext,
	branch: string | null,
	action: ActionName,
	failure: HttpFailure,
	readBaseline: () => Promise<ChainState>
): Promise<void> {
	const at = new Date().toISOString();
	await write(ctx, action, async () => {
		const lines: Line[] = [actionLine(at, branch, action, failedResponse(failure))];
		if (failure.extra.chainReset === true) {
			const snapshotId = failure.extra.snapshotId;
			const info: BranchInfo = {
				revertedTo: branch,
				snapshotId: typeof snapshotId === 'string' ? snapshotId : null,
				blockNumber: null,
				blockTimestamp: null
			};
			lines.push(await headerWithBaseline(ctx, at, info, readBaseline));
		}
		return lines;
	});
}

/**
 * Unlike an action, a failed write throws: nothing changed on chain, and the page must not show a
 * probe the log does not have.
 */
export async function recordProbe(ctx: DemoContext, probe: ProbeRecord): Promise<void> {
	await appendEvidence(ctx.config.evidenceFile, [probeLine(new Date().toISOString(), probe)]);
}
