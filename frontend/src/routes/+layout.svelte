<script lang="ts">
	// Self-hosted, so the console renders the same offline and on the recording machine.
	import '@fontsource/ibm-plex-sans/400.css';
	import '@fontsource/ibm-plex-sans/400-italic.css';
	import '@fontsource/ibm-plex-sans/500.css';
	import '@fontsource/ibm-plex-sans/600.css';
	import '@fontsource/ibm-plex-mono/400.css';
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>
{@render children()}
