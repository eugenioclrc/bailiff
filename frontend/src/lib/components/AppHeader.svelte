<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { formatDuration } from '$lib/format';
	import ActionButton from './ActionButton.svelte';

	let { demo }: { demo: Demo } = $props();

	let s = $derived(demo.state);
	let sync = $derived.by(() => {
		if (!s) return demo.loadError ? 'No chain state yet' : 'Reading chain state…';
		if (demo.stale) return 'Updating after the last action…';
		if (demo.loadError) return `Last good read at block ${s.block.number}`;
		const age = s.navStatus.ageSeconds
			? `, NAV set ${formatDuration(BigInt(s.navStatus.ageSeconds))} ago`
			: '';
		return `Live at block ${s.block.number}${age}`;
	});
</script>

<header class="top">
	<div class="brand">
		<h1>Bailiff — executes liquidation without keeping the inventory</h1>
		<p class="env">
			<span class="chip">{s?.env.label ?? 'Anvil fork'}</span>
			{#if s}
				<span>chain {s.env.chainId}</span>
				<span>contracts at commit <code>{s.env.sourceCommit.slice(0, 7)}</code></span>
			{/if}
		</p>
	</div>
	<div class="controls">
		<p class={['sync', { warn: demo.stale || demo.loadError }]} role="status">{sync}</p>
		<button
			type="button"
			class="refresh"
			aria-disabled={demo.loading || demo.pending !== null}
			onclick={() => {
				if (!demo.loading && demo.pending === null) void demo.refresh();
			}}
		>
			Refresh
		</button>
		<ActionButton {demo} action="reset" tone="quiet" />
	</div>
</header>

<style>
	.top {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
	}

	h1 {
		font: 400 27px/1 var(--font-display);
		letter-spacing: 0.005em;
		padding-top: 3px;
	}

	.env {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 4px 12px;
		margin-top: 4px;
		font-size: 12px;
		color: var(--color-ink-2);
	}

	.chip {
		padding: 1px 8px;
		border-radius: 3px;
		background: var(--color-ink);
		color: var(--color-sheet);
		font-weight: 600;
	}

	.controls {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-shrink: 0;
	}

	.sync {
		max-width: 260px;
		font-size: 12px;
		color: var(--color-ink-2);
		text-align: right;
	}

	.sync.warn {
		color: var(--color-caution);
	}

	.refresh {
		min-height: 30px;
		padding: 5px 10px;
		border: 1px solid var(--color-rule);
		border-radius: 4px;
		background: var(--color-sheet);
		color: var(--color-ink);
		font: 600 13px/1.2 var(--font-body);
		cursor: pointer;
	}

	@media (max-width: 900px) {
		.top {
			flex-direction: column;
			align-items: flex-start;
		}

		.controls {
			flex-wrap: wrap;
		}

		.sync {
			text-align: left;
		}
	}

	.refresh[aria-disabled='true'] {
		opacity: 0.45;
		cursor: not-allowed;
	}
</style>
