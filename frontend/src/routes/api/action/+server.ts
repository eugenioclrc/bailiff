import { parseActionBody } from '$lib/actions';
import { runAction } from '$lib/server/actions';
import { loadContext, type DemoContext } from '$lib/server/context';
import { recordEvidence, recordFailure } from '$lib/server/evidence';
import {
	HttpFailure,
	assertJsonBody,
	assertJsonContentType,
	assertLoopbackClient,
	assertLoopbackHost,
	assertNotCrossSite,
	assertSameOrigin,
	readCappedBody,
	toHttpFailure
} from '$lib/server/guards';
import { acquireFileLock, currentHolder, lockPathOf, tryAcquire } from '$lib/server/lock';
import { currentBranch } from '$lib/server/reset';
import { fail, ok } from '$lib/server/respond';
import { readState } from '$lib/server/state';
import type { ActionName, ActionResponse } from '$lib/types';
import type { RequestHandler } from './$types';

/**
 * Runs the action and appends it to the evidence log, failures included: a reset that already
 * reverted the chain, or a send whose receipt never arrived, changed the chain even though the
 * route answers with an HTTP error. The error is rethrown so fail() still builds the response.
 */
async function runAndRecord(ctx: DemoContext, action: ActionName): Promise<ActionResponse> {
	const branch = await currentBranch(ctx);
	const readBaseline = () => readState(ctx);
	let response: ActionResponse;
	try {
		response = await runAction(ctx, action);
	} catch (err) {
		await recordFailure(ctx, branch, action, toHttpFailure(err), readBaseline);
		throw err;
	}
	await recordEvidence(ctx, branch, action, response, readBaseline);
	return response;
}

/** POST {action}: the closed O5 body. Addresses, amounts and calldata come from the manifest, never the body. */
export const POST: RequestHandler = async ({ request, url, getClientAddress }) => {
	try {
		assertLoopbackClient(getClientAddress());
		assertLoopbackHost(url.hostname);
		assertSameOrigin(request.headers.get('origin'), url.origin);
		assertNotCrossSite(request.headers.get('sec-fetch-site'));
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
			// Other processes signing on the same Anvil (a second server, the integration test).
			const releaseFile = await acquireFileLock(lockPathOf(ctx.config.snapshotFile), parsed.action);
			try {
				return ok(await runAndRecord(ctx, parsed.action));
			} finally {
				await releaseFile();
			}
		} finally {
			release();
		}
	} catch (err) {
		return fail(err, 'POST /api/action');
	}
};
