/**
 * Request guards and HTTP failure mapping for the local demo API. Pure, so it runs under `bun test`.
 */
import { BaseError, HttpRequestError, SocketClosedError, TimeoutError } from 'viem';
import { ConfigError } from './config';

/** A failure that is not an on-chain outcome: it becomes an HTTP error status, never an action status. */
export class HttpFailure extends Error {
	override name = 'HttpFailure';
	constructor(
		readonly status: number,
		message: string
	) {
		super(message);
	}
}

const LOOPBACK_CLIENTS = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);
const MAX_BODY_BYTES = 256;

export function isLoopbackClient(address: string): boolean {
	return LOOPBACK_CLIENTS.has(address);
}

export function assertLoopbackClient(address: string): void {
	if (!isLoopbackClient(address))
		throw new HttpFailure(403, 'The demo API only answers loopback clients.');
}

const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]']);

/**
 * The request's Host must be loopback too. Without this, a DNS-rebinding page could send a
 * same-origin request (Origin and Host both its own name) from the presenter's own browser.
 */
export function assertLoopbackHost(hostname: string): void {
	if (!LOOPBACK_HOSTS.has(hostname)) {
		throw new HttpFailure(403, 'The demo API only answers requests addressed to a loopback host.');
	}
}

/** Same-origin POST: the Origin header must be present and equal the server's own origin. */
export function assertSameOrigin(originHeader: string | null, serverOrigin: string): void {
	if (!originHeader || originHeader !== serverOrigin) {
		throw new HttpFailure(403, 'Cross-origin or origin-less requests are refused.');
	}
}

export function assertJsonBody(contentType: string | null, body: string): unknown {
	if (!contentType || contentType.split(';')[0].trim().toLowerCase() !== 'application/json') {
		throw new HttpFailure(415, 'Content-Type must be application/json.');
	}
	if (new TextEncoder().encode(body).length > MAX_BODY_BYTES) {
		throw new HttpFailure(413, 'Request body is too large.');
	}
	try {
		return JSON.parse(body);
	} catch {
		throw new HttpFailure(400, 'Request body is not valid JSON.');
	}
}

function isTransportError(err: unknown): boolean {
	if (err instanceof BaseError) {
		return Boolean(
			err.walk(
				(e) =>
					e instanceof HttpRequestError ||
					e instanceof TimeoutError ||
					e instanceof SocketClosedError
			)
		);
	}
	return err instanceof TypeError && /fetch/i.test(err.message);
}

/** Maps any thrown value to an HTTP failure with a message that is safe to show. */
export function toHttpFailure(err: unknown): HttpFailure {
	if (err instanceof HttpFailure) return err;
	if (err instanceof ConfigError) return new HttpFailure(503, `Demo configuration: ${err.message}`);
	if (isTransportError(err)) {
		return new HttpFailure(
			502,
			'The local Anvil RPC did not answer. Check that Anvil is running on ANVIL_RPC.'
		);
	}
	return new HttpFailure(500, 'Unexpected server error; details are in the server log.');
}

/** Server-side log line: error class and viem short message only, never request bodies. */
export function describeForLog(err: unknown): string {
	if (err instanceof BaseError) return `${err.name}: ${err.shortMessage}`;
	if (err instanceof Error) return `${err.name}: ${err.message}`;
	return String(err);
}
