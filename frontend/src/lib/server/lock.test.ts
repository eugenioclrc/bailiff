import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { existsSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { acquireFileLock, currentHolder, lockPathOf, tryAcquire } from './lock';

describe('action lock', () => {
	test('a second acquire fails while held, and release is idempotent', () => {
		const release = tryAcquire('crash');
		expect(release).not.toBeNull();
		expect(currentHolder()).toBe('crash');
		expect(tryAcquire('reset')).toBeNull();
		release!();
		release!();
		expect(currentHolder()).toBeNull();
		const again = tryAcquire('reset');
		expect(again).not.toBeNull();
		again!();
	});

	test('a stale release does not free a newer holder', () => {
		const first = tryAcquire('crash')!;
		first();
		const second = tryAcquire('revoke')!;
		first();
		expect(currentHolder()).toBe('revoke');
		second();
	});
});

describe('cross-process file lock', () => {
	let dir: string;
	let path: string;
	const OTHER_PID = 424242;
	beforeEach(() => {
		dir = mkdtempSync(join(tmpdir(), 'bailiff-lock-'));
		path = lockPathOf(join(dir, 'anvil-snapshot.json'));
	});
	afterEach(() => rmSync(dir, { recursive: true, force: true }));

	test('lives next to SNAPSHOT_FILE, holds this pid, and is removed on release', async () => {
		expect(path).toBe(join(dir, 'anvil-snapshot.json.lock'));
		const release = await acquireFileLock(path, 'reset');
		expect(JSON.parse(readFileSync(path, 'utf8'))).toEqual({ pid: process.pid, action: 'reset' });
		await release();
		await release();
		expect(existsSync(path)).toBe(false);
	});

	test('a live holder in another process is a 409 naming its pid and action', async () => {
		writeFileSync(path, JSON.stringify({ pid: OTHER_PID, action: 'liquidateFull' }));
		await expect(acquireFileLock(path, 'reset', () => true)).rejects.toMatchObject({
			status: 409,
			message: expect.stringContaining(`pid ${OTHER_PID}`)
		});
		expect(JSON.parse(readFileSync(path, 'utf8')).pid).toBe(OTHER_PID);
	});

	test('a lock left by a dead process is taken over', async () => {
		writeFileSync(path, JSON.stringify({ pid: OTHER_PID, action: 'crash' }));
		const release = await acquireFileLock(path, 'reset', () => false);
		expect(JSON.parse(readFileSync(path, 'utf8')).pid).toBe(process.pid);
		await release();
	});

	test('a lock without a pid is busy while fresh and abandoned once old', async () => {
		writeFileSync(path, '');
		await expect(acquireFileLock(path, 'reset', () => true)).rejects.toMatchObject({ status: 409 });
		const old = new Date(Date.now() - 60_000);
		utimesSync(path, old, old);
		const release = await acquireFileLock(path, 'reset', () => true);
		await release();
	});

	test('a directory it cannot write to is a configuration error, not a busy lock', async () => {
		const missing = lockPathOf(join(dir, 'missing', 'anvil-snapshot.json'));
		await expect(acquireFileLock(missing, 'reset')).rejects.toThrow('cannot be created');
	});
});
