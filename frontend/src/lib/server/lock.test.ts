import { describe, expect, test } from 'bun:test';
import { currentHolder, tryAcquire } from './lock';

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
