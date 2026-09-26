/**
 * Timeline records and the branch archive. A local reset opens a new branch: the active timeline
 * restarts, and the discarded branch moves to the archive instead of being dropped (O4 evidence).
 * Pure, so the page state class stays thin and this logic runs under `bun test`.
 */
import type { ActionName, ActionResponse, ProbeRecord, Quote } from './types';

/** Same wording as the liquidate actions' call line; the entry header names the keeper. */
export const PROBE_CALL = 'adapter.liquidate(borrower, maxUint256, minBounty 0.00 USDC)';
/** Oldest archived branches are dropped past this, so the session copy stays small. */
export const MAX_ARCHIVED_BRANCHES = 12;

export type ActionItem = {
	kind: 'action';
	id: number;
	at: string;
	action: ActionName;
	response: ActionResponse;
};

/** A keeper-side eth_call of the adapter route, recorded on the page. Never a transaction. */
export type ProbeItem = {
	kind: 'probe';
	id: number;
	at: string;
	block: string;
	from: string;
	call: string;
	quote: Quote;
};

export type TimelineItem = ActionItem | ProbeItem;

export type ArchivedBranch = {
	/** Snapshot id the branch started from; null when it was never known. */
	branch: string | null;
	closedAt: string;
	reason: string;
	items: TimelineItem[];
};

export type Session = {
	branch: string | null;
	timeline: TimelineItem[];
	archive: ArchivedBranch[];
};

/** Moves `items` to the front of the archive; an empty branch leaves the archive as it was. */
export function archiveBranch(
	archive: readonly ArchivedBranch[],
	closed: ArchivedBranch
): ArchivedBranch[] {
	if (closed.items.length === 0) return [...archive];
	return [closed, ...archive].slice(0, MAX_ARCHIVED_BRANCHES);
}

export function probeItem(record: ProbeRecord, id: number, at: string): ProbeItem {
	const { block, from, call, quote } = record;
	return { kind: 'probe', id, at, block, from, call, quote };
}

export function nextId(session: Pick<Session, 'timeline' | 'archive'>): number {
	const ids = [...session.timeline, ...session.archive.flatMap((b) => b.items)].map((i) => i.id);
	return ids.length ? Math.max(...ids) + 1 : 1;
}

function isItem(value: unknown): value is TimelineItem {
	const item = value as Partial<TimelineItem> | null;
	return (
		typeof item?.id === 'number' &&
		typeof item.at === 'string' &&
		(item.kind === 'action' || item.kind === 'probe')
	);
}

/** Validates a session copy read back from browser storage; anything malformed is ignored. */
export function parseSession(raw: string | null): Session | null {
	if (!raw) return null;
	try {
		const value = JSON.parse(raw) as Partial<Session>;
		const branch = typeof value.branch === 'string' ? value.branch : null;
		const timeline = Array.isArray(value.timeline) ? value.timeline.filter(isItem) : [];
		const archive = Array.isArray(value.archive)
			? value.archive.filter(
					(b): b is ArchivedBranch =>
						typeof b?.closedAt === 'string' && Array.isArray(b.items) && b.items.every(isItem)
				)
			: [];
		return { branch, timeline, archive };
	} catch {
		return null;
	}
}

/**
 * The session to show for the branch the chain is on now. Same branch: restore as it was.
 * Another branch: the stored timeline was discarded by a reset while the page was away.
 */
export function restoreSession(stored: Session, branch: string | null, at: string): Session {
	if (stored.branch === branch) return stored;
	return {
		branch,
		timeline: [],
		archive: archiveBranch(stored.archive, {
			branch: stored.branch,
			closedAt: at,
			reason: 'reset while this page was closed',
			items: stored.timeline
		})
	};
}
