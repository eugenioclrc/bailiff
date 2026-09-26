import { parseActionBody } from '$lib/actions';
import { runAction } from '$lib/server/actions';
import { loadContext } from '$lib/server/context';
import { recordEvidence } from '$lib/server/evidence';
import {
	HttpFailure,
	assertJsonBody,
	assertJsonContentType,
	assertLoopbackClient,
	assertLoopbackHost,
	assertSameOrigin,
	readCappedBody
} from '$lib/server/guards';
import { currentHolder, tryAcquire } from '$lib/server/lock';
import { currentBranch } from '$lib/server/reset';
import { fail, ok } from '$lib/server/respond';
import { readState } from '$lib/server/state';
import type { RequestHandler } from './$types';

/** POST {action}: the closed O5 body. Addresses, amounts and calldata come from the manifest, never the body. */
export const POST: RequestHandler = async ({ request, url, getClientAddress }) => {
	try {
		assertLoopbackClient(getClientAddress());
		assertLoopbackHost(url.hostname);
		assertSameOrigin(request.headers.get('origin'), url.origin);
		const contentType = request.headers.get('content-type');
		assertJsonContentType(contentType);
		const parsed = parseActionBody(assertJsonBody(contentType, await readCappedBody(request)));
		if (!parsed.ok) throw new HttpFailure(400, parsed.message);

		// Taken before any RPC work, so a second click while an action runs answers at once.
		const release = tryAcquire(parsed.action);
		if (!release)
			throw new HttpFailure(409, `Another action (${currentHolder()}) is still running.`);
		try {
			const ctx = await loadContext();
			const branch = await currentBranch(ctx);
			const response = await runAction(ctx, parsed.action);
			await recordEvidence(ctx, branch, parsed.action, response, () => readState(ctx));
			return ok(response);
		} finally {
			release();
		}
	} catch (err) {
		return fail(err, 'POST /api/action');
	}
};
