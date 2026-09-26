/**
 * Client state for the demo page: the last chain state read, the action in flight and the
 * timeline of this branch. A reset starts a new branch, so it replaces the timeline.
 */
import { summarize } from './view';
import type { ActionName, ActionResponse, ChainState } from './types';

export type TimelineItem = {
	id: number;
	at: string;
	action: ActionName;
	response: ActionResponse;
};

type ErrorBody = { message?: unknown };

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

export class Demo {
	state = $state.raw<ChainState | null>(null);
	/** True while the numbers on screen predate an action that changed the chain. */
	stale = $state(false);
	loading = $state(false);
	loadError = $state<string | null>(null);
	pending = $state<ActionName | null>(null);
	actionError = $state<{ action: ActionName; message: string } | null>(null);
	timeline = $state.raw<TimelineItem[]>([]);
	announcement = $state('');
	/** Set when the chain was reset outside this page and the old timeline was dropped. */
	branchNotice = $state<string | null>(null);

	#nextId = 1;
	#latestRead = 0;
	/** Snapshot id of the branch the timeline belongs to. */
	#branch: string | null = null;

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
			if (this.#branch !== null && next.branch !== null && next.branch !== this.#branch) {
				this.timeline = [];
				this.branchNotice = `The chain was reset outside this page at ${new Date().toLocaleTimeString('en-GB')}; the previous timeline was cleared.`;
				this.announcement = this.branchNotice;
			}
			this.#branch = next.branch ?? this.#branch;
			this.state = next;
			this.stale = false;
			this.loadError = null;
		} catch {
			if (ticket === this.#latestRead)
				this.loadError = 'The local server did not answer. Is `bun run dev` running?';
		} finally {
			if (ticket === this.#latestRead) this.loading = false;
		}
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
			if (!res.ok) {
				this.actionError = { action, message: messageOf(body, res.status) };
				this.announcement = this.actionError.message;
				return;
			}
			const response = body as ActionResponse;
			const item: TimelineItem = {
				id: this.#nextId++,
				at: new Date().toLocaleTimeString('en-GB'),
				action,
				response
			};
			if (response.status === 'reset') {
				this.#branch = response.snapshotId ?? null;
				this.branchNotice = null;
			}
			this.timeline = response.status === 'reset' ? [item] : [item, ...this.timeline];
			this.stale = response.status !== 'simulation-reverted';
			this.announcement = summarize(action, response);
		} catch {
			this.actionError = { action, message: 'The request did not reach the local server.' };
			this.announcement = this.actionError.message;
		} finally {
			this.pending = null;
			await this.refresh();
		}
	}
}
