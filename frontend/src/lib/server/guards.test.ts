import { describe, expect, test } from 'bun:test';
import { HttpRequestError, TimeoutError } from 'viem';
import { ConfigError } from './config';
import {
	HttpFailure,
	assertJsonBody,
	assertLoopbackClient,
	assertSameOrigin,
	isLoopbackClient,
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

	test('same origin required', () => {
		expect(statusOf(() => assertSameOrigin('http://127.0.0.1:5173', 'http://127.0.0.1:5173'))).toBe(200);
		expect(statusOf(() => assertSameOrigin(null, 'http://127.0.0.1:5173'))).toBe(403);
		expect(statusOf(() => assertSameOrigin('http://evil.test', 'http://127.0.0.1:5173'))).toBe(403);
		expect(statusOf(() => assertSameOrigin('http://localhost:5173', 'http://127.0.0.1:5173'))).toBe(403);
	});

	test('JSON body with the right content type and size', () => {
		expect(assertJsonBody('application/json', '{"action":"crash"}')).toEqual({ action: 'crash' });
		expect(assertJsonBody('application/json; charset=utf-8', '{}')).toEqual({});
		expect(statusOf(() => assertJsonBody('text/plain', '{}'))).toBe(415);
		expect(statusOf(() => assertJsonBody(null, '{}'))).toBe(415);
		expect(statusOf(() => assertJsonBody('application/json', '{nope'))).toBe(400);
		expect(statusOf(() => assertJsonBody('application/json', JSON.stringify({ action: 'x'.repeat(400) })))).toBe(413);
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
		expect(toHttpFailure(new TimeoutError({ body: {}, url: 'http://127.0.0.1:8545' })).status).toBe(502);
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
