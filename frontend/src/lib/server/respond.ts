import { json } from '@sveltejs/kit';
import { describeForLog, toHttpFailure } from './guards';

const NO_STORE = { 'cache-control': 'no-store' };

export function ok(body: unknown): Response {
	return json(body, { headers: NO_STORE });
}

/** Transport, config and guard failures become HTTP errors with a safe message; details go to the log. */
export function fail(err: unknown, route: string): Response {
	const failure = toHttpFailure(err);
	if (failure.status >= 500) console.error(`[bailiff] ${route}: ${describeForLog(err)}`);
	return json(
		{ ...failure.extra, message: failure.message },
		{ status: failure.status, headers: NO_STORE }
	);
}
