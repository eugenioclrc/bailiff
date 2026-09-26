<script lang="ts">
	import type { Snippet } from 'svelte';
	import { shortAddress } from '$lib/format';

	type Props = {
		title: string;
		address?: string;
		blurb: string;
		loaded: boolean;
		/** The last read failed: say so instead of claiming a read is still running. */
		failed: boolean;
		children: Snippet;
		actions?: Snippet;
	};

	let { title, address, blurb, loaded, failed, children, actions }: Props = $props();
	const uid = $props.id();
</script>

<section class="panel" aria-labelledby="{uid}-title">
	<header>
		<h2 id="{uid}-title">{title}</h2>
		{#if address}
			<!-- A disclosure, not a tooltip: the full address opens with keyboard and touch too. -->
			<details class="addr">
				<summary class="code">{shortAddress(address)}</summary>
				<code>{address}</code>
			</details>
		{/if}
	</header>
	<p class="blurb">{blurb}</p>
	{#if loaded}
		<dl class="figures">{@render children()}</dl>
	{:else}
		<p class="loading" role="status">
			{failed ? 'No chain state: the read failed, see the message above.' : 'Reading chain state…'}
		</p>
	{/if}
	{#if actions}
		<div class="actions">{@render actions()}</div>
	{/if}
</section>

<style>
	.panel {
		display: flex;
		flex-direction: column;
		gap: 5px;
		min-width: 0;
		padding: 9px 12px 10px;
		background: var(--color-sheet);
		border: 1px solid var(--color-rule);
		border-radius: 4px;
	}

	header {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		justify-content: space-between;
		gap: 0 8px;
	}

	h2 {
		font: 600 22px/1 var(--font-display);
		letter-spacing: 0.01em;
		padding-top: 2px;
	}

	.addr {
		min-width: 0;
		margin-left: auto;
		color: var(--color-ink-2);
		font-size: 11px;
		text-align: right;
	}

	.addr summary {
		cursor: pointer;
	}

	.addr code {
		display: block;
		color: var(--color-ink);
	}

	@media (max-width: 1100px), (pointer: coarse) {
		.addr summary {
			padding-block: 15px;
		}
	}

	.blurb {
		color: var(--color-ink-2);
		font-size: 12px;
		line-height: 1.3;
	}

	.figures {
		display: grid;
		gap: 2px;
	}

	.loading {
		color: var(--color-ink-2);
		font-style: italic;
	}

	.actions {
		display: grid;
		gap: 6px;
		margin-top: auto;
		padding-top: 4px;
	}
</style>
