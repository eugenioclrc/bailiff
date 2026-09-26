/**
 * bun test preload:
 * - SvelteKit's virtual `$env/dynamic/private`, backed by process.env, so server modules and
 *   route handlers import without Vite;
 * - `.svelte.ts` modules compiled with the Svelte compiler (runes to plain JS), so page state
 *   classes such as Demo run under `bun test` too.
 */
import { plugin } from 'bun';
import { compileModule } from 'svelte/compiler';

const typescript = new Bun.Transpiler({ loader: 'ts' });

plugin({
	name: 'sveltekit-test-shims',
	setup(build) {
		build.module('$env/dynamic/private', () => ({
			exports: { env: process.env },
			loader: 'object'
		}));
		build.onLoad({ filter: /\.svelte\.ts$/ }, async ({ path }) => {
			const js = typescript.transformSync(await Bun.file(path).text());
			const { js: output } = compileModule(js, { filename: path, generate: 'client', dev: false });
			return { contents: output.code, loader: 'js' };
		});
	}
});
