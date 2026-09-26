/**
 * The part of `bun:test` these tests use, so `bun run check` (svelte-check) type-checks the test
 * files too, without a new dependency. Matchers are loosely typed; the point is that fixtures and
 * helpers such as fakeContext, ActionResponse and ChainState keep matching the code they stand in for.
 */
declare module 'bun:test' {
	type Hook = () => unknown;

	interface Matchers<R = void> {
		not: Matchers<R>;
		resolves: Matchers<Promise<void>>;
		rejects: Matchers<Promise<void>>;
		toBe(expected: unknown): R;
		toEqual(expected: unknown): R;
		toMatchObject(expected: unknown): R;
		toContain(expected: unknown): R;
		toMatch(expected: string | RegExp): R;
		toBeNull(): R;
		toBeUndefined(): R;
		toBeDefined(): R;
		toHaveLength(length: number): R;
		toBeInstanceOf(constructor: abstract new (...args: never[]) => unknown): R;
		toThrow(expected?: string | RegExp | Error | (new (...args: never[]) => Error)): R;
		toBeLessThan(value: number | bigint): R;
		toBeLessThanOrEqual(value: number | bigint): R;
		toBeGreaterThan(value: number | bigint): R;
		toHaveBeenCalledTimes(times: number): R;
	}

	interface Expect {
		(actual: unknown): Matchers;
		stringContaining(text: string): unknown;
	}

	interface Describe {
		(name: string, fn: () => void): void;
		skipIf(condition: boolean): (name: string, fn: () => void) => void;
	}

	interface Mock {
		mockImplementation(fn: (...args: never[]) => unknown): Mock;
		mockRestore(): void;
	}

	export const expect: Expect;
	export const describe: Describe;
	export function test(name: string, fn: Hook, timeout?: number): void;
	export function beforeEach(fn: Hook): void;
	export function afterEach(fn: Hook): void;
	export function spyOn<T extends object>(object: T, method: keyof T): Mock;
}
