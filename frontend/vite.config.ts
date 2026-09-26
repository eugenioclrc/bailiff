import tailwindcss from '@tailwindcss/vite';
import adapter from '@sveltejs/adapter-auto';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// O5: loopback only. Vite's default CORS would reflect any localhost origin onto the API.
const LOOPBACK = { host: '127.0.0.1', strictPort: true, cors: false } as const;

export default defineConfig({
	server: { ...LOOPBACK, port: 5173 },
	preview: { ...LOOPBACK, port: 4173 },
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// adapter-auto only supports some environments, see https://svelte.dev/docs/kit/adapter-auto for a list.
			// If your environment is not supported, or you settled on a specific environment, switch out the adapter.
			// See https://svelte.dev/docs/kit/adapters for more information about adapters.
			adapter: adapter(),

			// Unit tests run under `bun test`, which strips their types; svelte-check has no bun:test types.
			typescript: {
				config: (config) => ({
					...config,
					exclude: [...(config.exclude ?? []), '../src/**/*.test.ts']
				})
			}
		})
	]
});
