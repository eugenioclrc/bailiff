<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
</script>

<svelte:head>
	<title>{page.status}: Bailiff demo console</title>
</svelte:head>

<main>
	<h1>{page.status}: {page.error?.message}</h1>
	<p>This console has one page.</p>
	<a href={resolve('/')}>Back to the Bailiff console</a>
</main>

<style>
	main {
		display: grid;
		justify-items: start;
		gap: 8px;
		padding: 12px 16px;
	}

	h1 {
		font: 600 22px/1.2 var(--font-display);
	}

	a {
		color: var(--color-ink);
		font-weight: 600;
		text-decoration: underline;
		text-underline-offset: 2px;
	}

	/* A 44px tap target on touch and narrow screens. */
	@media (max-width: 1100px), (pointer: coarse) {
		a {
			display: inline-flex;
			align-items: center;
			min-height: 44px;
		}
	}
</style>
