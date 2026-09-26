<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { formatUnit } from '$lib/format';
	import type { HolderKey } from '$lib/types';
	import { holderOf, showRead, type Shown } from '$lib/view';

	let { demo }: { demo: Demo } = $props();

	let s = $derived(demo.state);
	let nav = $derived(showRead(s?.market.nav, 'wad'));
	const NOT_READ: Shown = { text: 'not read yet', tone: 'missing' };
	let floor = $derived<Shown>(
		s?.navStatus.floor ? { text: formatUnit(s.navStatus.floor, 'wad'), tone: 'value' } : NOT_READ
	);
	let spot = $derived<Shown>(
		s?.pool.spot ? { text: formatUnit(s.pool.spot, 'wad'), tone: 'value' } : NOT_READ
	);
	let noState = $derived(
		demo.loadError
			? 'No chain state: the read failed, see the message above.'
			: 'Reading chain state…'
	);
	let floorPercent = $derived(s ? `${s.navFloorBps / 100}%` : '99%');
	let floorEnforced = $derived(s?.adapterNavFloorBps.ok === true);

	let floorNote = $derived.by(() => {
		if (!s) return '';
		if (!floorEnforced)
			return 'The deployed adapter does not enforce this floor yet; it sells at any spot.';
		if (s.pool.spotAboveFloor === null) return 'Pool spot unavailable; floor status unknown.';
		return s.pool.spotAboveFloor
			? 'Spot is above the floor, so the adapter may sell.'
			: 'Spot is at or below the floor: the adapter refuses to sell.';
	});

	type Stop = { key: HolderKey; name: string; role: string };
	/** These must hold zero RWA outside a transaction; a leftover wei is flagged, never rounded away. */
	const MUST_BE_EMPTY: ReadonlySet<HolderKey> = new Set(['adapter', 'keeper', 'poolManager']);
	const PATH: Stop[] = [
		{ key: 'market', name: 'MiniLend market', role: 'holds the collateral' },
		{ key: 'adapter', name: 'Liquidation adapter', role: 'transit inside one tx' },
		{ key: 'pa', name: 'Pool wrapper (PA)', role: 'backs the pool token' }
	];
	const OUTSIDE: Stop[] = [
		{ key: 'keeper', name: 'Keeper', role: 'never takes custody' },
		{ key: 'poolManager', name: 'PoolManager', role: 'raw RWA, never held' }
	];

	let totals = $derived([
		{ label: 'Market debt', shown: showRead(s?.market.totalDebt, 'usdc') },
		{ label: 'written off', shown: showRead(s?.market.totalBadDebt, 'usdc') },
		{ label: 'residual claims', shown: showRead(s?.market.totalResidualClaims, 'usdc') }
	]);

	function rwaOf(key: HolderKey) {
		const read = holderOf(s, key)?.rwa;
		const holdsRwa = MUST_BE_EMPTY.has(key) && read?.ok === true && read.value !== '0';
		return { ...showRead(read, 'rwa'), holdsRwa };
	}
</script>

<section class="band" aria-label="Prices and RWA custody">
	<div class="prices">
		<h2>Prices, USDC per RWA</h2>
		{#if s}
			<dl>
				<div>
					<dt>NAV</dt>
					<dd class={[nav.tone, { num: nav.tone === 'value' }]}>{nav.text}</dd>
				</div>
				<div>
					<dt>NAV floor, {floorPercent}</dt>
					<dd class={[floor.tone, { num: floor.tone === 'value' }]}>{floor.text}</dd>
				</div>
				<div>
					<dt>Pool spot</dt>
					<dd class={[spot.tone, { num: spot.tone === 'value' }]}>{spot.text}</dd>
				</div>
			</dl>
			<p class="note">{floorNote}</p>
			<p class="totals">
				{#each totals as total, i (total.label)}
					{i > 0 ? '; ' : ''}{total.label}
					<span class={[total.shown.tone, { num: total.shown.tone === 'value' }]}
						>{total.shown.text}</span
					>
				{/each}
			</p>
		{:else}
			<p class="note" role="status">{noState}</p>
		{/if}
	</div>

	<div class="custody">
		<h2>Who holds the RWA</h2>
		{#if s}
			<ol class="path" aria-label="Liquidation path of seized RWA">
				{#each PATH as stop (stop.key)}
					{@const shown = rwaOf(stop.key)}
					<li>
						<span class="name">{stop.name}</span>
						<span class={{ amount: true, num: shown.tone === 'value', bad: shown.holdsRwa }}
							>{shown.text}</span
						>
						<span class="role"
							>{shown.holdsRwa ? 'holds RWA now: check the receipt' : stop.role}</span
						>
					</li>
				{/each}
			</ol>
			<ul class="outside">
				{#each OUTSIDE as stop (stop.key)}
					{@const shown = rwaOf(stop.key)}
					<li>
						<span class="name">{stop.name}</span>
						<span class={{ amount: true, num: shown.tone === 'value', bad: shown.holdsRwa }}
							>{shown.text}</span
						>
						<span class="role"
							>{shown.holdsRwa ? 'holds RWA now: check the receipt' : stop.role}</span
						>
					</li>
				{/each}
			</ul>
		{:else}
			<!-- Same words as the status line in the prices half; announced once, from there. -->
			<p class="waiting">{noState}</p>
		{/if}
	</div>
</section>

<style>
	.band {
		display: grid;
		grid-template-columns: minmax(0, 0.9fr) minmax(0, 1.6fr);
		border-radius: 6px;
		overflow: hidden;
		border: 1px solid var(--color-steel-deep);
	}

	h2 {
		font: 600 16px/1 var(--font-display);
		letter-spacing: 0.02em;
		padding-top: 2px;
	}

	.prices {
		display: grid;
		gap: 3px;
		padding: 7px 12px;
		background: var(--color-sheet);
	}

	.prices dl {
		display: grid;
		grid-template-columns: repeat(3, auto);
		justify-content: start;
		column-gap: 22px;
	}

	.prices dt {
		color: var(--color-ink-2);
		font-size: 12px;
	}

	.prices dd {
		font-size: 22px;
		line-height: 1.05;
	}

	.prices dd.missing,
	.prices dd.failed {
		font-size: 13px;
		font-style: italic;
	}

	.prices dd.missing {
		color: var(--color-caution);
	}

	.prices dd.failed {
		color: var(--color-alert);
	}

	.note {
		color: var(--color-ink-2);
		font-size: 12px;
	}

	.totals {
		font-size: 11.5px;
		color: var(--color-ink-2);
	}

	.totals .value {
		color: var(--color-ink);
	}

	.totals .missing {
		color: var(--color-caution);
		font-style: italic;
	}

	.totals .failed {
		color: var(--color-alert);
	}

	.custody {
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		grid-template-rows: auto 1fr;
		column-gap: 18px;
		row-gap: 3px;
		padding: 7px 12px;
		background: var(--color-steel);
		color: var(--color-steel-ink);
	}

	.custody h2 {
		grid-column: 1 / -1;
	}

	.path,
	.outside {
		display: flex;
		align-items: stretch;
	}

	.path li,
	.outside li {
		display: grid;
		align-content: start;
		gap: 1px;
		min-width: 0;
	}

	/* The arrows are the point: seized RWA only ever moves along this path. */
	.path li + li {
		margin-left: 34px;
		position: relative;
	}

	.path li + li::before {
		content: '';
		position: absolute;
		left: -28px;
		top: 21px;
		width: 18px;
		height: 2px;
		background: currentColor;
	}

	.path li + li::after {
		content: '';
		position: absolute;
		left: -13px;
		top: 17px;
		border: 5px solid transparent;
		border-left: 7px solid currentColor;
	}

	.outside {
		gap: 16px;
		padding-left: 16px;
		border-left: 1px solid color-mix(in srgb, var(--color-steel-ink) 35%, transparent);
	}

	.name {
		font-size: 12px;
		opacity: 0.85;
	}

	.amount {
		font-size: 20px;
		line-height: 1.05;
	}

	/* Red text would vanish on the steel band, so a violation gets a solid chip instead. */
	.amount.bad {
		justify-self: start;
		padding: 0 5px;
		border-radius: 3px;
		background: var(--color-alert);
		color: #fff;
	}

	.role {
		font-size: 11px;
		opacity: 0.75;
	}

	.waiting {
		grid-column: 1 / -1;
		font-size: 12px;
	}

	@media (max-width: 1100px) {
		.band {
			grid-template-columns: minmax(0, 1fr);
		}
	}

	@media (max-width: 640px) {
		.custody {
			grid-template-columns: minmax(0, 1fr);
		}

		.path {
			flex-direction: column;
			gap: 6px;
		}

		/* Vertical path: the connector points down instead of right. */
		.path li + li {
			margin-left: 0;
			padding-left: 22px;
		}

		.path li + li::before {
			left: 6px;
			top: -6px;
			width: 2px;
			height: 14px;
		}

		.path li + li::after {
			left: 2px;
			top: 7px;
			border: 5px solid transparent;
			border-top: 7px solid currentColor;
		}

		.outside {
			padding-left: 0;
			border-left: 0;
		}

		.prices dl {
			column-gap: 14px;
		}
	}
</style>
