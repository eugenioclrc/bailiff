<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import TimelineEntry from './TimelineEntry.svelte';

	let { demo }: { demo: Demo } = $props();

	let rwaIsCurrency0 = $derived(demo.state?.rwaIsCurrency0 ?? true);

	/** New entries land on top: re-runs when the newest id changes and brings it into view. */
	function scrollToNewest(node: HTMLElement) {
		void demo.timeline[0]?.id;
		node.scrollTo({ top: 0 });
	}
</script>

<section class="timeline" aria-labelledby="timeline-title">
	<header>
		<h2 id="timeline-title">Timeline</h2>
		<p>Newest first. Mined transactions, simulations and local resets are marked apart.</p>
		{#if demo.state}
			<p class="ids">
				Manifest pool id <code>{demo.state.poolId}</code>, hook
				<code>{demo.state.addresses.hook}</code>
			</p>
		{/if}
	</header>
	<!-- The list scrolls on its own; a focusable region lets keyboard users scroll it (WCAG 2.1.1). -->
	<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
	<div
		class="scroll"
		tabindex="0"
		role="region"
		aria-label="Timeline entries"
		{@attach scrollToNewest}
	>
		{#if demo.branchNotice}
			<p class="notice" role="status">{demo.branchNotice}</p>
		{/if}
		{#if demo.timeline.length === 0}
			<p class="empty">
				No actions recorded in this tab since the last reset. Actions sent from another tab are in
				the evidence log. Start with the issuer: cut NAV to 85.
			</p>
		{:else}
			<ol>
				{#each demo.timeline as item, i (item.id)}
					<li><TimelineEntry {item} newest={i === 0} {rwaIsCurrency0} /></li>
				{/each}
			</ol>
		{/if}

		{#if demo.archive.length}
			<details class="archive">
				<summary>Earlier branches, discarded by local reset ({demo.archive.length})</summary>
				{#each demo.archive as branch (branch.items[0].id)}
					<section class="branch" aria-label="Discarded branch from snapshot {branch.branch}">
						<p class="branch-head">
							<span class="tag">Discarded branch, local Anvil</span>
							from snapshot <code>{branch.branch ?? 'unknown'}</code>, closed at {branch.closedAt}:
							{branch.reason}
						</p>
						<ol>
							{#each branch.items as item (item.id)}
								<li><TimelineEntry {item} newest={false} {rwaIsCurrency0} /></li>
							{/each}
						</ol>
					</section>
				{/each}
			</details>
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
		flex-wrap: wrap;
		align-items: baseline;
		gap: 2px 12px;
	}

	h2 {
		font: 400 20px/1 var(--font-display);
		padding-top: 2px;
	}

	header p {
		font-size: 12px;
		color: var(--color-ink-2);
	}

	.ids code {
		color: var(--color-ink);
	}

	/*
	 * position: relative makes this the containing block of the visually-hidden spans inside, so
	 * they are clipped here instead of stretching the page. contain stops wheel scroll chaining,
	 * and overflow-anchor: none lets a new top entry push older ones down rather than hide itself.
	 */
	.scroll {
		position: relative;
		min-height: 120px;
		overflow: auto;
		overscroll-behavior: contain;
		overflow-anchor: none;
		border-radius: 6px;
	}

	ol {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
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

	.archive {
		margin-top: 10px;
	}

	.archive > summary {
		cursor: pointer;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--color-reset);
	}

	.branch {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
		gap: 6px;
		margin-top: 8px;
		padding-left: 10px;
		border-left: 2px dashed var(--color-reset);
	}

	.branch-head {
		font-size: 12px;
		color: var(--color-ink-2);
	}

	.tag {
		margin-right: 6px;
		padding: 1px 7px;
		border-radius: 3px;
		background: var(--color-reset);
		color: var(--color-steel-ink);
		font-weight: 600;
	}

	@media (max-width: 1100px), (pointer: coarse) {
		.archive > summary {
			padding-block: 14px;
		}
	}
</style>
