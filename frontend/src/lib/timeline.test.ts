import { describe, expect, test } from 'bun:test';
import {
	MAX_ARCHIVED_BRANCHES,
	PROBE_CALL,
	archiveBranch,
	nextId,
	parseSession,
	probeItem,
	restoreSession,
	type ActionItem,
	type ArchivedBranch
} from './timeline';
import type { ProbeRecord } from './types';

const item = (id: number): ActionItem => ({
	kind: 'action',
	id,
	at: '18:00:00',
	action: 'crash',
	response: {
		status: 'mined',
		txHash: '0x1',
		detail: { action: 'crash', signer: null, call: '', simulations: [] }
	}
});
const branch = (id: string, ...ids: number[]): ArchivedBranch => ({
	branch: id,
	closedAt: '18:00:00',
	reason: 'r',
	items: ids.map(item)
});

describe('archiveBranch', () => {
	test('puts the closed branch first and skips empty branches', () => {
		const archive = archiveBranch([branch('0x1', 1)], branch('0x2', 2));
		expect(archive.map((b) => b.branch)).toEqual(['0x2', '0x1']);
		expect(archiveBranch(archive, branch('0x3'))).toEqual(archive);
	});

	test('keeps a bounded number of branches', () => {
		let archive: ArchivedBranch[] = [];
		for (let i = 0; i < MAX_ARCHIVED_BRANCHES + 3; i += 1) {
			archive = archiveBranch(archive, branch(`0x${i}`, i));
		}
		expect(archive).toHaveLength(MAX_ARCHIVED_BRANCHES);
		expect(archive[0].branch).toBe(`0x${MAX_ARCHIVED_BRANCHES + 2}`);
	});
});

describe('PROBE_CALL', () => {
	test('reads like the call line of the liquidate actions', () => {
		expect(PROBE_CALL).toBe('adapter.liquidate(borrower, maxUint256, minBounty 0.00 USDC)');
	});
});

describe('probeItem', () => {
	test('records the server probe from the keeper, with no hash', () => {
		const record: ProbeRecord = {
			branch: '0xe',
			block: '11782750',
			from: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
			call: PROBE_CALL,
			quote: { repayAssets: '1', ok: true, bounty: '4500000000' }
		};
		const probe = probeItem(record, 7, '18:01:00');
		expect(probe).toEqual({
			kind: 'probe',
			id: 7,
			at: '18:01:00',
			block: '11782750',
			from: record.from,
			call: PROBE_CALL,
			quote: record.quote
		});
		expect('txHash' in probe).toBe(false);
	});
});

describe('session copy', () => {
	test('round-trips and drops malformed entries', () => {
		const session = { branch: '0xe', timeline: [item(3)], archive: [branch('0xd', 1, 2)] };
		expect(parseSession(JSON.stringify(session))).toEqual(session);
		expect(parseSession('{"branch":"0xe","timeline":[{"id":"x"}],"archive":[{}]}')).toEqual({
			branch: '0xe',
			timeline: [],
			archive: []
		});
		expect(parseSession('not json')).toBeNull();
		expect(parseSession(null)).toBeNull();
	});

	test('the same branch restores as it was; another branch archives the stored timeline', () => {
		const stored = { branch: '0xe', timeline: [item(3)], archive: [branch('0xd', 1)] };
		expect(restoreSession(stored, '0xe', 'now')).toBe(stored);
		const moved = restoreSession(stored, '0xf', 'now');
		expect(moved.timeline).toEqual([]);
		expect(moved.branch).toBe('0xf');
		expect(moved.archive.map((b) => b.branch)).toEqual(['0xe', '0xd']);
		expect(moved.archive[0].reason).toContain('closed');
	});

	test('ids continue after every restored item', () => {
		expect(nextId({ timeline: [item(3)], archive: [branch('0xd', 9)] })).toBe(10);
		expect(nextId({ timeline: [], archive: [] })).toBe(1);
	});
});
