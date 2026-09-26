import { loadContext } from '$lib/server/context';
import { assertLoopbackClient } from '$lib/server/guards';
import { fail, ok } from '$lib/server/respond';
import { readState } from '$lib/server/state';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ getClientAddress }) => {
	try {
		assertLoopbackClient(getClientAddress());
		const ctx = await loadContext();
		return ok(await readState(ctx));
	} catch (err) {
		return fail(err, 'GET /api/state');
	}
};
