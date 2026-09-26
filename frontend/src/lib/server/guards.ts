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
		message: string,
		/** Extra JSON fields for the error body, e.g. `{ chainReset: true }`. Never secrets. */
		readonly extra: Readonly<Record<string, string | number | boolean>> = {}
	) {
		super(message);
	}
}

const LOOPBACK_CLIENTS = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);
export const MAX_BODY_BYTES = 256;

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

/** GET: a browser sends Origin on cross-origin fetches; a foreign one is refused. None is fine (curl, same-origin GET). */
export function assertNotCrossOrigin(originHeader: string | null, serverOrigin: string): void {
	if (originHeader && originHeader !== serverOrigin) {
		throw new HttpFailure(403, 'Cross-origin requests are refused.');
	}
}

/**
 * Sec-Fetch-Site: browsers send it on every request, and leave Origin off cross-site no-cors GETs
 * (img, script). A cross-site or same-site page is refused; same-origin, none and no header
 * (curl) stay allowed.
 */
export function assertNotCrossSite(site: string | null): void {
	if (site === 'cross-site' || site === 'same-site') {
		throw new HttpFailure(403, 'Cross-site requests are refused.');
	}
}

const tooLarge = () => new HttpFailure(413, 'Request body is too large.');

/**
 * Reads at most MAX_BODY_BYTES of the body. Content-Length is required (browser fetch always
 * sends it for a string body): a chunked body would have to be cancelled mid-stream, and the node
 * bridge then drops the socket before a JSON 413 can be sent. A declared length over the cap is
 * refused before reading; a stream that still grows past it is cancelled as a backstop.
 */
export async function readCappedBody(request: Request): Promise<string> {
	const header = request.headers.get('content-length');
	if (header === null) throw new HttpFailure(411, 'Content-Length is required.');
	const declared = Number(header);
	if (!Number.isInteger(declared) || declared < 0) {
		throw new HttpFailure(400, 'Content-Length is malformed.');
	}
	if (declared > MAX_BODY_BYTES) throw tooLarge();
	if (!request.body) return '';
	const reader = request.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		total += value.byteLength;
		if (total > MAX_BODY_BYTES) {
			await reader.cancel();
			throw tooLarge();
		}
		chunks.push(value);
	}
	const bytes = new Uint8Array(total);
	chunks.reduce((offset, chunk) => {
		bytes.set(chunk, offset);
		return offset + chunk.byteLength;
	}, 0);
	return new TextDecoder().decode(bytes);
}

export function assertJsonContentType(contentType: string | null): void {
	if (!contentType || contentType.split(';')[0].trim().toLowerCase() !== 'application/json') {
		throw new HttpFailure(415, 'Content-Type must be application/json.');
	}
}

export function assertJsonBody(contentType: string | null, body: string): unknown {
	assertJsonContentType(contentType);
	if (new TextEncoder().encode(body).length > MAX_BODY_BYTES) throw tooLarge();
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
