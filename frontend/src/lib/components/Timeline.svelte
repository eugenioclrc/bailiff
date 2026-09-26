<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import TimelineEntry from './TimelineEntry.svelte';

	let { demo }: { demo: Demo } = $props();

	let rwaIsCurrency0 = $derived(demo.state?.rwaIsCurrency0 ?? true);
</script>

<section class="timeline" aria-labelledby="timeline-title">
	<header>
		<h2 id="timeline-title">Timeline</h2>
		<p>Newest on top. Mined transactions, simulations and local resets are marked apart.</p>
	</header>
	<!-- The list scrolls on its own; a focusable region lets keyboard users scroll it (WCAG 2.1.1). -->
	<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
	<div class="scroll" tabindex="0" role="region" aria-label="Timeline entries">
		{#if demo.branchNotice}
			<p class="notice" role="status">{demo.branchNotice}</p>
		{/if}
		{#if demo.timeline.length === 0}
			<p class="empty">No actions on this branch yet. Start with the issuer: cut NAV to 85.</p>
		{:else}
			<ol>
				{#each demo.timeline as item, i (item.id)}
					<li><TimelineEntry {item} newest={i === 0} {rwaIsCurrency0} /></li>
				{/each}
			</ol>
		{/if}
	</div>
</section>

<style>
	.timeline {
		display: grid;
		grid-template-rows: auto minmax(0, 1fr);
		gap: 6px;
		min-height: 0;
	}

	header {
		display: flex;
		align-items: baseline;
		gap: 12px;
	}

	h2 {
		font: 400 20px/1 var(--font-display);
		padding-top: 2px;
	}

	header p {
		font-size: 12px;
		color: var(--color-ink-2);
	}

	.scroll {
		min-height: 120px;
		overflow: auto;
		border-radius: 6px;
	}

	ol {
		display: grid;
		gap: 8px;
	}

	.notice {
		margin-bottom: 8px;
		padding: 6px 10px;
		border-left: 4px solid var(--color-reset);
		background: color-mix(in srgb, var(--color-reset) 8%, var(--color-sheet));
		font-size: 12px;
	}

	.empty {
		padding: 18px 14px;
		border: 1px dashed var(--color-rule);
		border-radius: 6px;
		color: var(--color-ink-2);
		background: var(--color-sheet);
	}
</style>
