/**
 * bun test preload: SvelteKit's virtual `$env/dynamic/private` module, backed by process.env,
 * so server modules and route handlers import under `bun test` without Vite.
 */
import { plugin } from 'bun';

plugin({
	name: 'sveltekit-env',
	setup(build) {
		build.module('$env/dynamic/private', () => ({
			exports: { env: process.env },
			loader: 'object'
		}));
	}
});
