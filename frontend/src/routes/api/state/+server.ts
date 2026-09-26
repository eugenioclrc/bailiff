import { loadContext } from '$lib/server/context';
import {
	assertLoopbackClient,
	assertLoopbackHost,
	assertNotCrossOrigin,
	assertNotCrossSite
} from '$lib/server/guards';
import { fail, ok } from '$lib/server/respond';
import { readState } from '$lib/server/state';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ request, getClientAddress, url }) => {
	try {
		assertLoopbackClient(getClientAddress());
		assertLoopbackHost(url.hostname);
		assertNotCrossOrigin(request.headers.get('origin'), url.origin);
		assertNotCrossSite(request.headers.get('sec-fetch-site'));
		const ctx = await loadContext();
		return ok(await readState(ctx));
	} catch (err) {
		return fail(err, 'GET /api/state');
	}
};
