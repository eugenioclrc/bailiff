import { parseActionBody } from '$lib/actions';
import { runAction } from '$lib/server/actions';
import { loadContext } from '$lib/server/context';
import {
	HttpFailure,
	assertJsonBody,
	assertLoopbackClient,
	assertLoopbackHost,
	assertSameOrigin
} from '$lib/server/guards';
import { currentHolder, tryAcquire } from '$lib/server/lock';
import { fail, ok } from '$lib/server/respond';
import type { RequestHandler } from './$types';

/** POST {action}: the closed O5 body. Addresses, amounts and calldata come from the manifest, never the body. */
export const POST: RequestHandler = async ({ request, url, getClientAddress }) => {
	try {
		assertLoopbackClient(getClientAddress());
		assertLoopbackHost(url.hostname);
		assertSameOrigin(request.headers.get('origin'), url.origin);
		const body = assertJsonBody(request.headers.get('content-type'), await request.text());
		const parsed = parseActionBody(body);
		if (!parsed.ok) throw new HttpFailure(400, parsed.message);

		const ctx = await loadContext();
		const release = tryAcquire(parsed.action);
		if (!release)
			throw new HttpFailure(409, `Another action (${currentHolder()}) is still running.`);
		try {
			return ok(await runAction(ctx, parsed.action));
		} finally {
			release();
		}
	} catch (err) {
		return fail(err, 'POST /api/action');
	}
};
