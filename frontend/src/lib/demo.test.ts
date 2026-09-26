import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { Demo } from './demo.svelte';
import type { ActionResponse, ChainState } from './types';

type Reply = { status: number; body: unknown } | Error;
let stateReplies: Reply[];
let actionReplies: Reply[];
let posted: unknown[];
let store: Map<string, string>;
const realFetch = globalThis.fetch;

function chainState(branch: string, full: ChainState['quotes']['full'] = okQuote): ChainState {
	return {
		branch,
		block: { number: '11782750', timestamp: '1' },
		addresses: { keeper: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' },
		quotes: { full, chunk: full }
	} as unknown as ChainState;
}
const okQuote = { repayAssets: '1', ok: true as const, bounty: '4500000000' };
const mined = (action: ActionResponse['detail']['action']): ActionResponse => ({
	status: 'mined',
	txHash: `0x${'ab'.repeat(32)}`,
	detail: { action, signer: null, call: '', simulations: [] }
});
const reset = (snapshotId: string): ActionResponse => ({
	status: 'reset',
	snapshotId,
	detail: { action: 'reset', signer: null, call: '', simulations: [] }
});

function reply(queue: Reply[], fallback: Reply): Response {
	const next = queue.length ? queue.shift()! : fallback;
	if (next instanceof Error) throw next;
	return new Response(JSON.stringify(next.body), { status: next.status });
}

beforeEach(() => {
	stateReplies = [];
	actionReplies = [];
	posted = [];
	store = new Map();
	globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
		const url = String(input);
		if (url === '/api/state') return reply(stateReplies, { status: 200, body: chainState('0xe') });
		posted.push(JSON.parse(String(init?.body)));
		return reply(actionReplies, { status: 500, body: { message: 'unscripted' } });
	}) as typeof fetch;
	(globalThis as { sessionStorage?: unknown }).sessionStorage = {
		getItem: (k: string) => store.get(k) ?? null,
		setItem: (k: string, v: string) => void store.set(k, v)
	};
});

afterEach(() => {
	globalThis.fetch = realFetch;
	delete (globalThis as { sessionStorage?: unknown }).sessionStorage;
});

describe('Demo', () => {
	test('a failed first read shows an error and no numbers', async () => {
		stateReplies.push({ status: 502, body: { message: 'The local Anvil RPC did not answer.' } });
		const demo = new Demo();
		await demo.refresh();
		expect(demo.state).toBeNull();
		expect(demo.loadError).toContain('Anvil');
		expect(demo.loading).toBe(false);
	});

	test('a mined action goes on top and the figures refresh after it', async () => {
		const demo = new Demo();
		await demo.refresh();
		actionReplies.push({ status: 200, body: mined('crash') });
		await demo.run('crash');
		expect(posted).toEqual([{ action: 'crash' }]);
		expect(demo.timeline.map((i) => i.kind)).toEqual(['action']);
		expect(demo.stale).toBe(false);
		expect(demo.pending).toBeNull();
		expect(demo.announcement).toContain('mined on local Anvil');
	});

	test('a reset starts a fresh timeline and archives the discarded branch', async () => {
		const demo = new Demo();
		await demo.refresh();
		actionReplies.push({ status: 200, body: mined('crash') }, { status: 200, body: reset('0xf') });
		stateReplies.push(
			{ status: 200, body: chainState('0xe') },
			{ status: 200, body: chainState('0xf') }
		);
		await demo.run('crash');
		await demo.run('reset');
		expect(demo.timeline).toHaveLength(1);
		expect(demo.timeline[0].kind === 'action' && demo.timeline[0].response.status).toBe('reset');
		expect(demo.archive).toHaveLength(1);
		expect(demo.archive[0].branch).toBe('0xe');
		expect(demo.archive[0].items).toHaveLength(1);
		expect(demo.branchNotice).toBeNull();
	});

	test('a reset done elsewhere archives the timeline and says so', async () => {
		const demo = new Demo();
		await demo.refresh();
		actionReplies.push({ status: 200, body: mined('crash') });
		await demo.run('crash');
		stateReplies.push({ status: 200, body: chainState('0x10') });
		await demo.refresh();
		expect(demo.timeline).toEqual([]);
		expect(demo.archive[0].items).toHaveLength(1);
		expect(demo.branchNotice).toContain('outside this page');
	});

	test('a reset that reverted but failed its bookkeeping still clears the old branch', async () => {
		const demo = new Demo();
		await demo.refresh();
		actionReplies.push(
			{ status: 200, body: mined('crash') },
			{ status: 500, body: { chainReset: true, message: 'SNAPSHOT_FILE could not be written.' } }
		);
		await demo.run('crash');
		await demo.run('reset');
		expect(demo.timeline).toEqual([]);
		expect(demo.archive).toHaveLength(1);
		expect(demo.actionError).toEqual({
			action: 'reset',
			message: 'SNAPSHOT_FILE could not be written.'
		});
		expect(demo.branchNotice).toContain('SNAPSHOT_FILE');
	});

	test('an HTTP error on another action leaves the timeline alone', async () => {
		const demo = new Demo();
		await demo.refresh();
		actionReplies.push({
			status: 409,
			body: { message: 'Another action (crash) is still running.' }
		});
		await demo.run('revoke');
		expect(demo.timeline).toEqual([]);
		expect(demo.actionError?.action).toBe('revoke');
	});

	test('a lost receipt keeps the sent hash in the action error', async () => {
		const demo = new Demo();
		await demo.refresh();
		const hash = `0x${'cd'.repeat(32)}`;
		actionReplies.push({ status: 502, body: { message: 'No receipt arrived.', txHash: hash } });
		await demo.run('liquidateFull');
		expect(demo.actionError).toMatchObject({ action: 'liquidateFull', txHash: hash });
		expect(demo.actionError?.message).toBe(`No receipt arrived. Transaction ${hash}.`);
		expect(demo.timeline).toEqual([]);
	});

	test('an unreachable server is an action error, not a timeline entry', async () => {
		const demo = new Demo();
		await demo.refresh();
		actionReplies.push(new TypeError('fetch failed'));
		await demo.run('crash');
		expect(demo.actionError?.message).toContain('did not reach');
		expect(demo.timeline).toEqual([]);
	});

	test('recording the adapter route reads fresh state and posts nothing', async () => {
		const demo = new Demo();
		await demo.refresh();
		const revoked = {
			repayAssets: '1',
			ok: false as const,
			error: { name: 'Unauthorized', message: 'Unauthorized()' }
		};
		stateReplies.push({ status: 200, body: chainState('0xe', revoked) });
		await demo.recordQuote();
		expect(posted).toEqual([]);
		const [probe] = demo.timeline;
		expect(probe.kind).toBe('probe');
		expect(probe.kind === 'probe' && probe.quote).toEqual(revoked);
		expect(demo.announcement).toContain('would revert with Unauthorized');
		expect(demo.pending).toBeNull();
	});

	test('a reload restores the timeline of the same branch from the session copy', async () => {
		const first = new Demo();
		await first.refresh();
		actionReplies.push({ status: 200, body: mined('crash') });
		await first.run('crash');
		const reloaded = new Demo();
		await reloaded.refresh();
		expect(reloaded.timeline).toHaveLength(1);
		stateReplies.push({ status: 200, body: chainState('0x11') });
		const afterReset = new Demo();
		await afterReset.refresh();
		expect(afterReset.timeline).toEqual([]);
		expect(afterReset.archive[0].items).toHaveLength(1);
	});

	test('a second control while one is pending is ignored', async () => {
		const demo = new Demo();
		await demo.refresh();
		actionReplies.push({ status: 200, body: mined('crash') });
		const first = demo.run('crash');
		await demo.run('revoke');
		await demo.recordQuote();
		await first;
		expect(posted).toEqual([{ action: 'crash' }]);
	});
});
