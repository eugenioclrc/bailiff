import { describe, expect, spyOn, test } from 'bun:test';
import { tryAcquire } from '$lib/server/lock';
import { POST as PROBE } from '../probe/+server';
import { GET } from '../state/+server';
import { POST } from './+server';

const ORIGIN = 'http://127.0.0.1:5173';

type Init = {
	origin?: string | null;
	contentType?: string;
	body?: string;
	client?: string;
	host?: string;
	/** Sent as Content-Length; defaults to the body's byte length, null leaves it out. */
	contentLength?: string | null;
	site?: string;
};

function event({
	origin = ORIGIN,
	contentType = 'application/json',
	body = '{"action":"crash"}',
	client = '127.0.0.1',
	host = '127.0.0.1:5173',
	contentLength = String(new TextEncoder().encode(body).length),
	site
}: Init) {
	const url = new URL(`http://${host}/api/action`);
	const headers = new Headers({ 'content-type': contentType });
	if (origin) headers.set('origin', origin);
	if (contentLength !== null) headers.set('content-length', contentLength);
	if (site) headers.set('sec-fetch-site', site);
	const request = new Request(url, { method: 'POST', headers, body });
	return { request, url, getClientAddress: () => client } as unknown as Parameters<typeof POST>[0];
}

async function post(init: Init) {
	const res = await POST(event(init));
	return { status: res.status, body: (await res.json()) as { message: string } };
}

describe('POST /api/action guards', () => {
	test('no Origin or a foreign Origin is 403', async () => {
		expect((await post({ origin: null })).status).toBe(403);
		expect((await post({ origin: 'http://localhost:3000' })).status).toBe(403);
	});

	test('a non-loopback client or Host is 403', async () => {
		expect((await post({ client: '192.168.1.20' })).status).toBe(403);
		expect(
			(await post({ host: 'rebind.example:5173', origin: 'http://rebind.example:5173' })).status
		).toBe(403);
	});

	test('text/plain is 415', async () => {
		expect((await post({ contentType: 'text/plain' })).status).toBe(415);
	});

	test('an extra key, an unknown action or malformed JSON is 400', async () => {
		expect((await post({ body: '{"action":"crash","to":"0x1"}' })).status).toBe(400);
		expect((await post({ body: '{"action":"mint"}' })).status).toBe(400);
		expect((await post({ body: '{"action":' })).status).toBe(400);
	});

	test('an oversized body is 413', async () => {
		expect((await post({ body: JSON.stringify({ action: 'x'.repeat(300) }) })).status).toBe(413);
	});

	test('a body without Content-Length (chunked) is a JSON 411', async () => {
		const res = await post({ contentLength: null });
		expect(res.status).toBe(411);
		expect(res.body.message).toBe('Content-Length is required.');
	});

	test('a cross-site or same-site browser request is 403', async () => {
		expect((await post({ site: 'cross-site' })).status).toBe(403);
		expect((await post({ site: 'same-site' })).status).toBe(403);
	});

	test('a held lock is 409 before any RPC work', async () => {
		const release = tryAcquire('liquidateFull')!;
		try {
			const res = await post({});
			expect(res.status).toBe(409);
			expect(res.body.message).toContain('liquidateFull');
		} finally {
			release();
		}
	});

	test('error bodies are JSON with a message and no-store', async () => {
		const res = await POST(event({ origin: null }));
		expect(res.headers.get('cache-control')).toBe('no-store');
		expect(Object.keys(await res.json())).toEqual(['message']);
	});
});

describe('GET /api/state guards', () => {
	test('a cross-site no-cors GET without Origin is 403 before any RPC work', async () => {
		const url = new URL('http://127.0.0.1:5173/api/state');
		const request = new Request(url, { headers: { 'sec-fetch-site': 'cross-site' } });
		const res = await GET({ request, url, getClientAddress: () => '127.0.0.1' } as never);
		expect(res.status).toBe(403);
		expect(((await res.json()) as { message: string }).message).toContain('Cross-site');
	});

	test('a foreign Origin or client is 403', async () => {
		const url = new URL('http://127.0.0.1:5173/api/state');
		const foreign = new Request(url, { headers: { origin: 'http://localhost:3000' } });
		const res = await GET({ request: foreign, url, getClientAddress: () => '127.0.0.1' } as never);
		expect(res.status).toBe(403);
		const remote = await GET({
			request: new Request(url),
			url,
			getClientAddress: () => '10.0.0.2'
		} as never);
		expect(remote.status).toBe(403);
	});
});

describe('POST /api/probe', () => {
	async function probe(init: Init) {
		const res = await PROBE(event({ body: '{}', ...init }) as never);
		return { status: res.status, body: (await res.json()) as { message: string } };
	}

	test('keeps the /api/action guards: origin, site, client, Host and content type', async () => {
		expect((await probe({ origin: null })).status).toBe(403);
		expect((await probe({ origin: 'http://localhost:3000' })).status).toBe(403);
		expect((await probe({ site: 'cross-site' })).status).toBe(403);
		expect((await probe({ client: '192.168.1.20' })).status).toBe(403);
		expect(
			(await probe({ host: 'rebind.example:5173', origin: 'http://rebind.example:5173' })).status
		).toBe(403);
		expect((await probe({ contentType: 'text/plain' })).status).toBe(415);
		expect((await probe({ contentLength: null })).status).toBe(411);
	});

	test('a body other than {} is 400, so no action or argument rides along', async () => {
		expect((await probe({ body: '{"action":"crash"}' })).status).toBe(400);
		expect((await probe({ body: '[]' })).status).toBe(400);
	});

	test('a held action lock is 409 before any RPC work', async () => {
		const release = tryAcquire('revoke')!;
		try {
			const res = await probe({});
			expect(res.status).toBe(409);
			expect(res.body.message).toContain('revoke');
		} finally {
			release();
		}
	});

	test('under the unit test env it stops at DEMO_MODE before any request leaves', async () => {
		const fetchSpy = spyOn(globalThis, 'fetch').mockImplementation(() =>
			Promise.reject(new TypeError('unit tests must not reach the network'))
		);
		const log = spyOn(console, 'error').mockImplementation(() => {});
		try {
			const res = await probe({});
			expect(res.status).toBe(503);
			expect(res.body.message).toContain('DEMO_MODE');
			expect(fetchSpy).toHaveBeenCalledTimes(0);
			const next = tryAcquire('crash');
			expect(next).not.toBeNull();
			next?.();
		} finally {
			fetchSpy.mockRestore();
			log.mockRestore();
		}
	});

	test('the O5 action body stays closed: "probe" is not an action', async () => {
		expect((await post({ body: '{"action":"probe"}' })).status).toBe(400);
	});
});
