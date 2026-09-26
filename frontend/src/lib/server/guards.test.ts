import { describe, expect, test } from 'bun:test';
import { HttpRequestError, TimeoutError } from 'viem';
import { ConfigError } from './config';
import {
	HttpFailure,
	MAX_BODY_BYTES,
	assertJsonBody,
	assertLoopbackClient,
	assertLoopbackHost,
	assertNotCrossOrigin,
	assertNotCrossSite,
	assertSameOrigin,
	isLoopbackClient,
	readCappedBody,
	toHttpFailure
} from './guards';

function statusOf(fn: () => unknown): number {
	try {
		fn();
	} catch (err) {
		if (err instanceof HttpFailure) return err.status;
		throw err;
	}
	return 200;
}

describe('guards', () => {
	test('loopback clients only', () => {
		expect(isLoopbackClient('127.0.0.1')).toBe(true);
		expect(isLoopbackClient('::1')).toBe(true);
		expect(isLoopbackClient('::ffff:127.0.0.1')).toBe(true);
		expect(statusOf(() => assertLoopbackClient('192.168.1.20'))).toBe(403);
	});

	test('loopback Host only, against DNS rebinding', () => {
		for (const host of ['127.0.0.1', 'localhost', '[::1]']) {
			expect(statusOf(() => assertLoopbackHost(host))).toBe(200);
		}
		for (const host of ['evil.test', '127.0.0.1.nip.io', '0.0.0.0']) {
			expect(statusOf(() => assertLoopbackHost(host))).toBe(403);
		}
	});

	test('same origin required', () => {
		expect(statusOf(() => assertSameOrigin('http://127.0.0.1:5173', 'http://127.0.0.1:5173'))).toBe(
			200
		);
		expect(statusOf(() => assertSameOrigin(null, 'http://127.0.0.1:5173'))).toBe(403);
		expect(statusOf(() => assertSameOrigin('http://evil.test', 'http://127.0.0.1:5173'))).toBe(403);
		expect(statusOf(() => assertSameOrigin('http://localhost:5173', 'http://127.0.0.1:5173'))).toBe(
			403
		);
	});

	test('JSON body with the right content type and size', () => {
		expect(assertJsonBody('application/json', '{"action":"crash"}')).toEqual({ action: 'crash' });
		expect(assertJsonBody('application/json; charset=utf-8', '{}')).toEqual({});
		expect(statusOf(() => assertJsonBody('text/plain', '{}'))).toBe(415);
		expect(statusOf(() => assertJsonBody(null, '{}'))).toBe(415);
		expect(statusOf(() => assertJsonBody('application/json', '{nope'))).toBe(400);
		expect(
			statusOf(() =>
				assertJsonBody('application/json', JSON.stringify({ action: 'x'.repeat(400) }))
			)
		).toBe(413);
	});
});

describe('toHttpFailure', () => {
	test('config problems are 503', () => {
		expect(toHttpFailure(new ConfigError('DEMO_MODE must be "local"')).status).toBe(503);
	});

	test('transport problems are 502 and do not echo the URL', () => {
		const err = new HttpRequestError({ url: 'http://127.0.0.1:8545', body: { secret: 'x' } });
		const failure = toHttpFailure(err);
		expect(failure.status).toBe(502);
		expect(failure.message).not.toContain('secret');
		expect(toHttpFailure(new TimeoutError({ body: {}, url: 'http://127.0.0.1:8545' })).status).toBe(
			502
		);
	});

	test('anything else is a generic 500', () => {
		const failure = toHttpFailure(new Error('boom with details'));
		expect(failure.status).toBe(500);
		expect(failure.message).not.toContain('boom');
	});

	test('an HttpFailure passes through', () => {
		expect(toHttpFailure(new HttpFailure(409, 'busy')).status).toBe(409);
	});
});

describe('assertNotCrossOrigin', () => {
	test('no Origin or the same origin passes, a foreign origin is 403', () => {
		expect(statusOf(() => assertNotCrossOrigin(null, 'http://127.0.0.1:5173'))).toBe(200);
		expect(
			statusOf(() => assertNotCrossOrigin('http://127.0.0.1:5173', 'http://127.0.0.1:5173'))
		).toBe(200);
		expect(
			statusOf(() => assertNotCrossOrigin('http://localhost:3000', 'http://127.0.0.1:5173'))
		).toBe(403);
	});
});

describe('assertNotCrossSite', () => {
	test('same-origin, none and a missing header pass; cross-site and same-site are 403', () => {
		for (const site of [null, 'same-origin', 'none']) {
			expect(statusOf(() => assertNotCrossSite(site))).toBe(200);
		}
		for (const site of ['cross-site', 'same-site']) {
			expect(statusOf(() => assertNotCrossSite(site))).toBe(403);
		}
	});
});

describe('readCappedBody', () => {
	const url = 'http://127.0.0.1:5173/api/action';

	const post = (body: string, headers: Record<string, string> = {}) =>
		new Request(url, { method: 'POST', body, headers });

	test('reads a small body', async () => {
		const body = '{"action":"crash"}';
		expect(await readCappedBody(post(body, { 'content-length': String(body.length) }))).toBe(body);
	});

	test('a body without Content-Length is 411, before anything is read', async () => {
		const request = post('{"action":"crash"}');
		await expect(readCappedBody(request)).rejects.toMatchObject({
			status: 411,
			message: 'Content-Length is required.'
		});
		expect(request.bodyUsed).toBe(false);
	});

	test('a malformed Content-Length is 400', async () => {
		for (const length of ['abc', '-1', '1.5']) {
			await expect(readCappedBody(post('{}', { 'content-length': length }))).rejects.toMatchObject({
				status: 400
			});
		}
	});

	test('a declared length over the cap is refused before reading', async () => {
		const stream = new ReadableStream<Uint8Array>({ pull() {} });
		const request = new Request(url, {
			method: 'POST',
			body: stream,
			headers: { 'content-length': String(MAX_BODY_BYTES + 1) },
			duplex: 'half'
		} as RequestInit);
		await expect(readCappedBody(request)).rejects.toMatchObject({ status: 413 });
		expect(request.bodyUsed).toBe(false);
	});

	test('a stream that grows past its declared length and the cap is cancelled', async () => {
		let chunksServed = 0;
		let cancelled = false;
		const stream = new ReadableStream<Uint8Array>({
			pull(controller) {
				chunksServed += 1;
				controller.enqueue(new Uint8Array(100));
			},
			cancel() {
				cancelled = true;
			}
		});
		const request = new Request(url, {
			method: 'POST',
			body: stream,
			headers: { 'content-length': '18' },
			duplex: 'half'
		} as RequestInit);
		await expect(readCappedBody(request)).rejects.toMatchObject({ status: 413 });
		expect(cancelled).toBe(true);
		expect(chunksServed).toBeLessThan(10);
	});
});

describe('HttpFailure extras', () => {
	test('carry extra JSON fields and default to none', () => {
		expect(new HttpFailure(500, 'x', { chainReset: true }).extra).toEqual({ chainReset: true });
		expect(new HttpFailure(400, 'x').extra).toEqual({});
	});
});
