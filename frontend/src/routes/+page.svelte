<script lang="ts">
	import { onMount } from 'svelte';
	import AppHeader from '$lib/components/AppHeader.svelte';
	import BorrowerCard from '$lib/components/BorrowerCard.svelte';
	import IssuerPanel from '$lib/components/IssuerPanel.svelte';
	import KeeperPanel from '$lib/components/KeeperPanel.svelte';
	import MakerPanel from '$lib/components/MakerPanel.svelte';
	import MarketBand from '$lib/components/MarketBand.svelte';
	import Timeline from '$lib/components/Timeline.svelte';
	import { Demo } from '$lib/demo.svelte';

	/** Background refresh keeps the NAV age honest without dimming the figures. */
	const POLL_MS = 15_000;

	const demo = new Demo();
	/** Evidence view for the 3:10 scene: the role row steps aside and the timeline takes its height. */
	let evidenceFull = $state(false);

	onMount(() => {
		void demo.refresh();
		const timer = setInterval(() => {
			if (demo.pending === null && !demo.loading) void demo.refresh();
		}, POLL_MS);
		return () => clearInterval(timer);
	});
</script>

<svelte:head>
	<title>Bailiff demo console</title>
	<meta
		name="description"
		content="Local Anvil console for the Bailiff liquidation adapter: issuer, market maker and keeper actions with decoded receipts."
	/>
</svelte:head>

<div class="page" data-focus={evidenceFull ? 'timeline' : undefined}>
	<!-- One grid row for header and banner, so the board always gets the remaining height. -->
	<div class="top">
		<AppHeader {demo} />

		{#if demo.loadError}
			<div class="banner" role="alert">
				<p>Could not read chain state: {demo.loadError}</p>
				<button type="button" onclick={() => void demo.refresh()}>Try again</button>
			</div>
		{/if}
	</div>

	<!-- Only chain figures dim while a refresh is due; the timeline's receipts are already final. -->
	<main class="board">
		<div class="roles" data-stale={demo.stale} aria-busy={demo.stale && demo.loading}>
			<IssuerPanel {demo} />
			<MakerPanel {demo} />
			<KeeperPanel {demo} />
			<BorrowerCard {demo} />
		</div>
		<div data-stale={demo.stale} aria-busy={demo.stale && demo.loading}>
			<MarketBand {demo} />
		</div>
		<Timeline {demo} bind:fullHeight={evidenceFull} />
	</main>

	<p class="visually-hidden" aria-live="polite">{demo.announcement}</p>
</div>

<style>
	.page {
		box-sizing: border-box;
		display: grid;
		grid-template-rows: auto minmax(0, 1fr);
		gap: 10px;
		height: 100dvh;
		min-height: 640px;
		padding: 12px 16px;
	}

	.board {
		display: grid;
		grid-template-rows: auto auto minmax(0, 1fr);
		gap: 10px;
		min-height: 0;
	}

	.top {
		display: grid;
		gap: 8px;
	}

	.roles {
		display: grid;
		grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1.3fr) minmax(0, 1.1fr);
		gap: 10px;
	}

	/* The timeline stays below the band (O5); only the role row makes room for it. */
	.page[data-focus='timeline'] .roles {
		display: none;
	}

	.page[data-focus='timeline'] .board {
		grid-template-rows: auto minmax(0, 1fr);
	}

	.banner {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 6px 10px;
		border: 1px solid var(--color-alert);
		border-radius: 4px;
		background: color-mix(in srgb, var(--color-alert) 7%, var(--color-sheet));
		color: var(--color-alert);
		font-size: 13px;
	}

	.banner button {
		flex-shrink: 0;
		white-space: nowrap;
		padding: 3px 10px;
		border: 1px solid var(--color-alert);
		border-radius: 4px;
		background: var(--color-sheet);
		color: var(--color-alert);
		font-weight: 600;
		cursor: pointer;
	}

	@media (max-width: 1100px), (pointer: coarse) {
		.banner button {
			min-height: 44px;
		}
	}

	/* Below the demo resolution the page scrolls instead of squeezing the timeline. */
	@media (max-width: 1100px) {
		.page {
			height: auto;
		}

		.roles {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}

	@media (max-width: 640px) {
		.page {
			padding: 12px 16px;
		}

		.roles {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
