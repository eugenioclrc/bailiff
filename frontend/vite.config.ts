import tailwindcss from '@tailwindcss/vite';
import adapter from '@sveltejs/adapter-auto';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// O5: loopback only. Vite's default CORS reflects any localhost origin onto the API, and
// SvelteKit merges its own `cors` object over `cors: false`, so the origin is switched off instead.
const LOOPBACK = { host: '127.0.0.1', strictPort: true, cors: { origin: false } };

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
			adapter: adapter()
		})
	]
});
