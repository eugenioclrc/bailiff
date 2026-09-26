import { isProbeBody } from '$lib/actions';
import { loadContext } from '$lib/server/context';
import { recordProbe } from '$lib/server/evidence';
import {
	HttpFailure,
	assertJsonBody,
	assertJsonContentType,
	assertLoopbackClient,
	assertLoopbackHost,
	assertNotCrossSite,
	assertSameOrigin,
	readCappedBody
} from '$lib/server/guards';
import { acquireFileLock, currentHolder, lockPathOf, tryAcquire } from '$lib/server/lock';
import { fail, ok } from '$lib/server/respond';
import { readProbe } from '$lib/server/state';
import type { RequestHandler } from './$types';

/**
 * POST {}: the keeper's adapter eth_call for the O7 control pair, appended to EVIDENCE_FILE.
 * Same guards and locks as /api/action, so it lands in order between actions; it never signs.
 */
export const POST: RequestHandler = async ({ request, url, getClientAddress }) => {
	try {
		assertLoopbackClient(getClientAddress());
		assertLoopbackHost(url.hostname);
		assertSameOrigin(request.headers.get('origin'), url.origin);
		assertNotCrossSite(request.headers.get('sec-fetch-site'));
		const contentType = request.headers.get('content-type');
		assertJsonContentType(contentType);
		if (!isProbeBody(assertJsonBody(contentType, await readCappedBody(request)))) {
			throw new HttpFailure(400, 'Body must be an empty JSON object: {}.');
		}

		const release = tryAcquire('probe');
		if (!release)
			throw new HttpFailure(409, `Another action (${currentHolder()}) is still running.`);
		try {
			const ctx = await loadContext();
			const releaseFile = await acquireFileLock(lockPathOf(ctx.config.snapshotFile), 'probe');
			try {
				const probe = await readProbe(ctx);
				await recordProbe(ctx, probe);
				return ok(probe);
			} finally {
				await releaseFile();
			}
		} finally {
			release();
		}
	} catch (err) {
		return fail(err, 'POST /api/probe');
	}
};
