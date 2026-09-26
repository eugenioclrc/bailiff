/**
 * Client state for the demo page: the last chain state read, the control in flight, the timeline
 * of this branch and the branches a local reset discarded. A copy is kept in sessionStorage so a
 * dev-server reload does not lose the branch record; the server's evidence.jsonl is the durable one.
 */
import type { ControlName } from './actions';
import {
	archiveBranch,
	nextId,
	parseSession,
	probeItem,
	restoreSession,
	type ArchivedBranch,
	type Session,
	type TimelineItem
} from './timeline';
import type { ActionName, ActionResponse, ChainState, ProbeRecord } from './types';
import { probeSummary, summarize } from './view';

export type { TimelineItem } from './timeline';

const SESSION_KEY = 'bailiff.timeline';

type ErrorBody = { message?: unknown; chainReset?: unknown; txHash?: unknown };

const TX_HASH = /^0x[0-9a-fA-F]{64}$/;

async function readJson(res: Response): Promise<unknown> {
	try {
		return await res.json();
	} catch {
		return null;
	}
}

function messageOf(body: unknown, status: number): string {
	const message = (body as ErrorBody | null)?.message;
	return typeof message === 'string' ? message : `The local server answered HTTP ${status}.`;
}

const clock = () => new Date().toLocaleTimeString('en-GB');

/** Browser storage is a per-viewer convenience: it may be missing or refuse writes (private mode). */
function loadSession(): Session | null {
	try {
		return parseSession(globalThis.sessionStorage?.getItem(SESSION_KEY) ?? null);
	} catch {
		return null;
	}
}

function saveSession(session: Session): void {
	try {
		globalThis.sessionStorage?.setItem(SESSION_KEY, JSON.stringify(session));
	} catch {
		// Quota or privacy mode: the page keeps working and evidence.jsonl still has the record.
	}
}

export class Demo {
	state = $state.raw<ChainState | null>(null);
	/** True while the numbers on screen predate an action that changed the chain. */
	stale = $state(false);
	loading = $state(false);
	loadError = $state<string | null>(null);
	pending = $state<ControlName | null>(null);
	actionError = $state<{ action: ControlName; message: string; txHash?: string } | null>(null);
	timeline = $state.raw<TimelineItem[]>([]);
	/** Branches discarded by a local reset, newest first. */
	archive = $state.raw<ArchivedBranch[]>([]);
	announcement = $state('');
	/** Set when the chain was reset outside this page and the old timeline was archived. */
	branchNotice = $state<string | null>(null);
	/**
	 * Id of the newest entry this page produced by pressing a control. Entries restored from the
	 * session copy never get it, so the rail replays motion only for what just happened here.
	 */
	lastRunId = $state<number | null>(null);

	#nextId = 1;
	#latestRead = 0;
	#restored = false;
	/** Snapshot id of the branch the timeline belongs to. */
	#branch: string | null = null;

	#persist(): void {
		saveSession({ branch: this.#branch, timeline: this.timeline, archive: this.archive });
	}

	/** Moves the active timeline to the archive and starts an empty one. */
	#closeBranch(reason: string): void {
		this.archive = archiveBranch(this.archive, {
			branch: this.#branch,
			closedAt: clock(),
			reason,
			items: this.timeline
		});
		this.timeline = [];
	}

	#restore(branch: string | null): void {
		this.#restored = true;
		const stored = loadSession();
		if (!stored) return;
		const session = restoreSession(stored, branch, clock());
		this.timeline = session.timeline;
		this.archive = session.archive;
		this.#nextId = nextId(session);
		if (stored.branch !== branch && stored.timeline.length > 0) {
			this.branchNotice =
				'The chain was reset while this page was closed; the previous timeline is under earlier branches.';
		}
	}

	#adoptBranch(next: ChainState): void {
		if (!this.#restored) {
			this.#restore(next.branch);
		} else if (this.#branch !== null && next.branch !== null && next.branch !== this.#branch) {
			this.#closeBranch('reset outside this page');
			// The time is when the poll saw the new branch, not when the reset ran (up to one poll earlier).
			this.branchNotice = `Noticed at ${clock()} that the chain was reset outside this page; the previous timeline moved to earlier branches.`;
			this.announcement = this.branchNotice;
		}
		this.#branch = next.branch ?? this.#branch;
		this.#persist();
	}

	async refresh(): Promise<void> {
		const ticket = ++this.#latestRead;
		this.loading = true;
		try {
			const res = await fetch('/api/state', {
				headers: { accept: 'application/json' },
				cache: 'no-store'
			});
			const body = await readJson(res);
			if (ticket !== this.#latestRead) return;
			if (!res.ok) {
				this.loadError = messageOf(body, res.status);
				return;
			}
			const next = body as ChainState;
			this.#adoptBranch(next);
			this.state = next;
			this.stale = false;
			this.loadError = null;
		} catch {
			if (ticket === this.#latestRead)
				this.loadError =
					'The local server did not answer. Is the dev server (bun run dev) running?';
		} finally {
			if (ticket === this.#latestRead) this.loading = false;
		}
	}

	#onActionFailure(action: ActionName, body: unknown, status: number): void {
		const error = body as ErrorBody | null;
		const txHash =
			typeof error?.txHash === 'string' && TX_HASH.test(error.txHash) ? error.txHash : undefined;
		const base = messageOf(body, status);
		// A sent transaction whose receipt never arrived: the hash must stay on screen.
		const message = txHash && !base.includes(txHash) ? `${base} Transaction ${txHash}.` : base;
		this.actionError = { action, message, ...(txHash ? { txHash } : {}) };
		this.announcement = message;
		// It may have mined: the numbers on screen are no longer known to be current.
		if (txHash) this.stale = true;
		// The revert happened even though the snapshot bookkeeping failed: the old branch is gone.
		if (action === 'reset' && error?.chainReset === true) {
			this.#closeBranch('local reset; snapshot bookkeeping failed');
			this.#branch = null;
			this.branchNotice = message;
			this.#persist();
		}
	}

	#onActionResult(action: ActionName, response: ActionResponse): void {
		const item: TimelineItem = {
			kind: 'action',
			id: this.#nextId++,
			at: clock(),
			action,
			response
		};
		if (response.status === 'reset') {
			this.#closeBranch('local reset to the healthy snapshot');
			this.#branch = response.snapshotId ?? null;
			this.branchNotice = null;
		}
		this.timeline = [item, ...this.timeline];
		this.lastRunId = item.id;
		this.stale = response.status !== 'simulation-reverted';
		this.announcement = summarize(action, response);
		this.#persist();
	}

	async run(action: ActionName): Promise<void> {
		if (this.pending !== null) return;
		this.pending = action;
		this.actionError = null;
		this.announcement = '';
		try {
			const res = await fetch('/api/action', {
				method: 'POST',
				headers: { 'content-type': 'application/json', accept: 'application/json' },
				body: JSON.stringify({ action })
			});
			const body = await readJson(res);
			if (res.ok) this.#onActionResult(action, body as ActionResponse);
			else this.#onActionFailure(action, body, res.status);
		} catch {
			this.actionError = { action, message: 'The request did not reach the local server.' };
			this.announcement = this.actionError.message;
		} finally {
			this.pending = null;
			await this.refresh();
		}
	}

	#onProbeFailure(message: string): void {
		this.actionError = { action: 'probe', message };
		this.announcement = message;
	}

	/**
	 * O7 revocation scene: the server runs the keeper's adapter eth_call (the quote row's call) and
	 * appends it to the evidence log, then it becomes a timeline entry. Nothing is signed or sent.
	 */
	async recordQuote(): Promise<void> {
		if (this.pending !== null) return;
		this.pending = 'probe';
		this.actionError = null;
		this.announcement = '';
		try {
			const res = await fetch('/api/probe', {
				method: 'POST',
				headers: { 'content-type': 'application/json', accept: 'application/json' },
				body: '{}'
			});
			const body = await readJson(res);
			if (!res.ok) {
				this.#onProbeFailure(messageOf(body, res.status));
				return;
			}
			// Adopts a reset made elsewhere first, so the entry lands on the branch it ran on.
			await this.refresh();
			const item = probeItem(body as ProbeRecord, this.#nextId++, clock());
			this.timeline = [item, ...this.timeline];
			this.lastRunId = item.id;
			this.announcement = probeSummary(item.quote);
			this.#persist();
		} catch {
			this.#onProbeFailure('The request did not reach the local server.');
		} finally {
			this.pending = null;
		}
	}
}
