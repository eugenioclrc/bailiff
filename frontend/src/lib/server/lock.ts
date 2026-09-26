import { open, readFile, rm, stat } from 'node:fs/promises';
import { ConfigError } from './config';
import { HttpFailure, describeForLog } from './guards';

/**
 * One action at a time: the demo signs with fixed keys, so concurrent sends would race on nonces
 * and a reset could land in the middle of a liquidation.
 */
let holder: string | null = null;

export function tryAcquire(label: string): (() => void) | null {
	if (holder !== null) return null;
	holder = label;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		holder = null;
	};
}

export function currentHolder(): string | null {
	return holder;
}

/**
 * Cross-process lock: a second dev server, the opt-in integration test or any script that takes
 * the same file cannot send between a reset's evm_revert and evm_snapshot. The file sits next to
 * SNAPSHOT_FILE, exists only while an action runs, and holds the owner's pid so a lock left by a
 * crashed process is taken over instead of blocking the demo.
 */

/** A lock file nobody wrote a pid into within this time is treated as abandoned. */
const UNREADABLE_STALE_MS = 10_000;
const LABEL = /^[A-Za-z0-9]{1,32}$/;

type LockOwner = { pid: number; action: string };

export function lockPathOf(snapshotFile: string): string {
	return `${snapshotFile}.lock`;
}

export function isProcessAlive(pid: number): boolean {
	// This process only reaches here with its in-process lock free: its own pid is a leftover.
	if (pid === process.pid) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (err) {
		return (err as NodeJS.ErrnoException).code === 'EPERM';
	}
}

async function readOwner(path: string): Promise<LockOwner | null> {
	try {
		const owner = JSON.parse(await readFile(path, 'utf8')) as Partial<LockOwner>;
		if (!Number.isInteger(owner.pid) || (owner.pid as number) <= 0) return null;
		const action =
			typeof owner.action === 'string' && LABEL.test(owner.action) ? owner.action : '?';
		return { pid: owner.pid as number, action };
	} catch {
		return null;
	}
}

async function isAbandoned(path: string, alive: (pid: number) => boolean): Promise<boolean> {
	const owner = await readOwner(path);
	if (owner) {
		if (!alive(owner.pid)) return true;
		throw new HttpFailure(
			409,
			`Another process (pid ${owner.pid}) is running ${owner.action} on this Anvil. Wait for it, or stop it.`
		);
	}
	// No pid yet: either another process is writing it right now, or it died mid-write.
	const age = await stat(path).then(
		(s) => Date.now() - s.mtimeMs,
		() => Infinity
	);
	if (age > UNREADABLE_STALE_MS) return true;
	throw new HttpFailure(409, 'Another process is starting an action on this Anvil. Retry.');
}

export async function acquireFileLock(
	path: string,
	label: string,
	alive: (pid: number) => boolean = isProcessAlive
): Promise<() => Promise<void>> {
	for (let attempt = 0; attempt < 2; attempt += 1) {
		let handle: Awaited<ReturnType<typeof open>>;
		try {
			handle = await open(path, 'wx', 0o600);
		} catch (err) {
			if ((err as NodeJS.ErrnoException).code !== 'EEXIST') {
				throw new ConfigError('the action lock next to SNAPSHOT_FILE cannot be created.');
			}
			if (await isAbandoned(path, alive)) await rm(path, { force: true });
			continue;
		}
		try {
			await handle.writeFile(JSON.stringify({ pid: process.pid, action: label }));
		} finally {
			await handle.close();
		}
		let released = false;
		return async () => {
			if (released) return;
			released = true;
			await rm(path, { force: true }).catch((err) =>
				console.error(`[bailiff] action lock not removed: ${describeForLog(err)}`)
			);
		};
	}
	throw new HttpFailure(409, 'Another process took the action lock first. Retry.');
}
