<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { formatUnit } from '$lib/format';
	import {
		STATIONS,
		railScene,
		railSentence,
		residualSplit,
		type RailScene,
		type Station
	} from '$lib/rail';
	import type { HolderKey } from '$lib/types';
	import { holderOf, showRead, type Shown } from '$lib/view';
	import RailLanes, { type Flow } from './RailLanes.svelte';
	import RailStation from './RailStation.svelte';

	let { demo }: { demo: Demo } = $props();
	const uid = $props.id();

	let s = $derived(demo.state);

	/*
	 * Right after an action the rail waits for the re-read, so the seized RWA crosses it together
	 * with the new balances instead of over figures that predate the liquidation.
	 */
	let holding = $derived(demo.stale && demo.loading && demo.loadError === null);
	let scene: RailScene = $derived(holding ? { kind: 'idle' } : railScene(demo.timeline[0]));
	let sceneKey = $derived(scene.kind === 'idle' ? 0 : scene.id);
	/** Motion only for what this page just did; a reloaded entry shows its final state at once. */
	let play = $derived(scene.kind !== 'idle' && scene.id === demo.lastRunId);
	let sentence = $derived(railSentence(scene));

	/** How far a route got: 3 segments for a whole route, fewer when a station refuses it. */
	let reached = $derived.by(() => {
		if (scene.kind === 'mined' || scene.kind === 'clear') return 3;
		if (scene.kind !== 'stopped' || scene.route !== 'adapter' || !scene.stop) return 0;
		return scene.stop === 'keeper' ? 0 : STATIONS.indexOf(scene.stop);
	});
	let stop = $derived(scene.kind === 'stopped' ? scene.stop : null);
	let direct = $derived(scene.kind === 'stopped' && scene.route === 'direct');
	/**
	 * The one raised element: the adapter that ran the liquidation, or the station that refused.
	 * Never the keeper: on the direct route the RWA token refuses to pay it, the keeper refuses nothing.
	 */
	let active = $derived<Station | null>(
		scene.kind === 'mined'
			? 'adapter'
			: scene.kind === 'stopped' && scene.stop !== 'keeper'
				? scene.stop
				: null
	);

	const NAMES: Record<Station | 'keeper', string> = {
		market: 'MiniLend market',
		adapter: 'Liquidation adapter',
		pa: 'Pool wrapper (PA)',
		poolManager: 'PoolManager + hook',
		keeper: 'Keeper, off the rail'
	};
	const ROLES: Partial<Record<Station | 'keeper', string>> = {
		adapter: 'transit inside one tx',
		pa: 'raw RWA behind the pool token',
		keeper: 'never takes custody'
	};
	/** These must hold zero RWA outside a transaction; a leftover wei is flagged, never rounded away. */
	const MUST_BE_EMPTY: ReadonlySet<HolderKey> = new Set(['adapter', 'keeper', 'poolManager']);

	function rwaOf(key: HolderKey) {
		const read = holderOf(s, key)?.rwa;
		const holdsRwa = MUST_BE_EMPTY.has(key) && read?.ok === true && read.value !== '0';
		return { ...showRead(read, 'rwa'), holdsRwa };
	}

	const NOT_READ: Shown = { text: 'not read yet', tone: 'missing' };
	let nav = $derived(showRead(s?.market.nav, 'wad'));
	let floor = $derived<Shown>(
		s?.navStatus.floor ? { text: formatUnit(s.navStatus.floor, 'wad'), tone: 'value' } : NOT_READ
	);
	let spot = $derived<Shown>(
		s?.pool.spot ? { text: formatUnit(s.pool.spot, 'wad'), tone: 'value' } : NOT_READ
	);
	let floorPercent = $derived(s ? `${s.navFloorBps / 100}%` : '99%');
	let floorNote = $derived.by(() => {
		if (!s) return '';
		if (s.adapterNavFloorBps.ok !== true)
			return `NAV floor ${floorPercent}: the deployed adapter does not check it yet; repayment and minBounty checks still apply.`;
		if (s.pool.spotAboveFloor === null) return 'Pool spot unavailable; floor status unknown.';
		return s.pool.spotAboveFloor
			? 'Spot is above the NAV floor, so the adapter may sell.'
			: 'Spot is at or below the NAV floor: the adapter refuses to sell.';
	});
	let totals = $derived([
		{ label: 'debt', shown: showRead(s?.market.totalDebt, 'usdc') },
		{ label: 'written off, all borrowers', shown: showRead(s?.market.totalBadDebt, 'usdc') },
		{ label: 'residual claims', shown: showRead(s?.market.totalResidualClaims, 'usdc') }
	]);
	let noState = $derived(
		demo.loadError
			? 'No chain state: the read failed, see the message above.'
			: 'Reading chain state…'
	);

	const usdc = (value: string) => formatUnit(value, 'usdc');
	let seized = $derived(scene.kind === 'mined' ? formatUnit(scene.seized, 'rwa') : null);
	/** Labels above the three RWA segments; the last carries the pool token the PA mints. */
	let rwaLabels = $derived(
		seized
			? [`${seized} RWA`, `${seized} RWA`, `${seized} pool token`]
			: ['seized RWA', 'seized RWA', 'as pool token']
	);
	/*
	 * Idle lanes name the route without claiming where the residual lands: the deployed snapshot
	 * pays the borrower wallet, the spec has MiniLend apply it. A mined receipt says which it was.
	 */
	let flow: Flow = $derived(
		scene.kind === 'mined'
			? {
					proceeds: `${usdc(scene.proceeds)} USDC proceeds`,
					repaid: `${usdc(scene.repaid)} debt repaid`,
					bounty: `${usdc(scene.bounty)} bounty to the keeper`,
					residual: residualSplit(scene).join('; ') || null
				}
			: {
					proceeds: 'USDC proceeds',
					repaid: 'debt repaid',
					bounty: 'bounty to the keeper',
					residual: 'residual for the borrower'
				}
	);
	/** Only a mined receipt or the idle route shows the USDC lanes; a refused route moved none. */
	let showUsdc = $derived(scene.kind === 'idle' || scene.kind === 'mined');
	/** Vertical layouts list USDC beside each segment: repaid, then proceeds past the PA. */
	let usdcBeside = $derived([flow.repaid, `${flow.proceeds} from PoolManager`]);

	/**
	 * Slot widths in figures: the widest balance each station holds in the demo, plus its unit. The
	 * market's also covers its "NAV 100.00 floor 99% 99.00" line, which is wider than its balance.
	 */
	const SLOTS: Record<Station | 'keeper', number> = {
		market: 13,
		adapter: 7.8,
		pa: 12.6,
		poolManager: 9.4,
		keeper: 7.8
	};
</script>

{#snippet figure(label: string, shown: Shown)}
	<span class="fig"
		>{label}
		<span class={[shown.tone, { num: shown.tone === 'value' }]}>{shown.text}</span></span
	>
{/snippet}

{#snippet contextOf(key: Station | 'keeper')}
	{#if rwaOf(key).holdsRwa}
		<span class="flag">holds RWA now: check the receipt</span>
	{:else if key === 'market'}
		{@render figure('NAV', nav)}
		{@render figure(`floor ${floorPercent}`, floor)}
	{:else if key === 'poolManager'}
		{@render figure('spot', spot)}
	{:else}
		{ROLES[key]}
	{/if}
{/snippet}

<section class="frame" aria-labelledby="{uid}-title">
	{#if !s}
		<h2 id="{uid}-title" class="title">Where the seized RWA goes</h2>
		<!-- Same words as the panels' status line; announced once, from there. -->
		<p class="waiting">{noState}</p>
	{:else}
		{#key sceneKey}
			<div
				class="rail"
				data-scene={scene.kind}
				data-play={play ? '' : undefined}
				style:--n={Math.max(reached, 1)}
			>
				<h2 id="{uid}-title" class="title">Where the seized RWA goes</h2>
				{#if showUsdc}
					<p class="legend l-usdc" aria-hidden="true">USDC back</p>
					<p class="legend l-split" aria-hidden="true">Paid out</p>
				{/if}

				{#each STATIONS as key, i (key)}
					<RailStation
						area={key}
						name={NAMES[key]}
						balance={rwaOf(key)}
						unit={key === 'poolManager' ? 'raw RWA' : 'RWA'}
						slot={SLOTS[key]}
						active={active === key}
						refuses={stop === key}
						barrier={stop === key && !direct ? (key === 'market' ? 'exit' : 'entry') : null}
					>
						{#snippet context()}{@render contextOf(key)}{/snippet}
					</RailStation>
					{#if i < 3}
						<div
							class={['seg', { lit: i < reached, dashed: scene.kind !== 'mined' }]}
							style:grid-area="s{i + 1}"
							style:--i={i + 1}
							aria-hidden="true"
						>
							<span class="line"><span class="fill"></span></span>
							{#if scene.kind === 'mined' || scene.kind === 'idle'}
								<span class="label rwa-label">{rwaLabels[i]}</span>
							{/if}
							{#if showUsdc && i < 2}
								<span class="label usdc-label">{usdcBeside[i]}</span>
							{/if}
						</div>
					{/if}
				{/each}

				<RailStation
					area="keeper"
					name={NAMES.keeper}
					balance={rwaOf('keeper')}
					unit="RWA"
					slot={SLOTS.keeper}
					stackedBarrier={direct && stop === 'keeper'}
					offRail
				>
					{#snippet context()}{@render contextOf('keeper')}{/snippet}
				</RailStation>

				<RailLanes
					flow={showUsdc ? flow : null}
					direct={direct ? { stop: stop === 'market' || stop === 'keeper' ? stop : null } : null}
				/>
				{#if showUsdc}
					<p class="split">
						Paid out by the adapter: {flow.bounty}{flow.residual ? `; ${flow.residual}` : ''}.
					</p>
				{/if}

				{#if scene.kind === 'stopped' || scene.kind === 'clear'}
					<p class={['verdict', { bad: scene.kind === 'stopped' }]}>{sentence}</p>
				{:else}
					<p class="visually-hidden">{sentence}</p>
				{/if}

				<p class="foot">
					<span>{floorNote}</span>
					<span
						>MiniLend totals:
						{#each totals as total, i (total.label)}
							{i > 0 ? '; ' : ''}{total.label}
							<span class={[total.shown.tone, { num: total.shown.tone === 'value' }]}
								>{total.shown.text}</span
							>
						{/each}</span
					>
				</p>
			</div>
		{/key}
	{/if}
</section>

<style>
	/*
	 * The rail is the page's focal point and its identity motif (DESIGN.md): the seized RWA crosses
	 * MiniLend, the adapter, the pool wrapper and PoolManager, never the keeper. At the demo size it
	 * is one strip: stations on a row, the RWA lane between them, the USDC coming back underneath.
	 */
	.frame {
		min-width: 0;
		background: var(--color-sheet);
		border: 1px solid var(--color-rule);
		border-radius: 4px;
	}

	.frame > .title {
		padding: 8px 12px 4px;
	}

	.waiting {
		padding: 0 12px 8px;
		color: var(--color-ink-2);
		font-style: italic;
	}

	.rail {
		--tie: 18px;
		--ktie: 30px;
		position: relative;
		display: grid;
		grid-template-columns:
			150px max-content minmax(56px, 1fr) max-content minmax(56px, 1fr)
			max-content minmax(56px, 1fr) max-content max-content;
		grid-template-rows: 14px 26px 16px minmax(16px, auto) 16px auto;
		grid-template-areas:
			'head market s1 adapter s2 pa s3 poolManager keeper'
			'head market s1 adapter s2 pa s3 poolManager keeper'
			'head market s1 adapter s2 pa s3 poolManager keeper'
			'l-usdc um ur uj up up up upm vk'
			'l-split vr vr vj vb vb vb vb vk'
			'foot foot foot foot foot foot foot foot foot';
		padding: 5px 12px 4px;
	}

	.title {
		grid-area: head;
		align-self: start;
		padding-right: 10px;
		font: 600 17px/1.15 var(--font-display);
	}

	.legend {
		align-self: center;
		font-size: 11px;
		color: var(--color-ink-2);
	}

	.l-usdc {
		grid-area: l-usdc;
	}

	.l-split {
		grid-area: l-split;
	}

	/* NAV, floor and spot sit on their stations: the figures, not their labels, carry the ink. */
	.fig .num {
		color: var(--color-ink);
		font-size: 13px;
	}

	.fig .missing {
		font-style: italic;
	}

	.fig .failed,
	.flag {
		color: var(--color-alert);
	}

	:global([data-stale='true']) .fig .num {
		color: var(--color-ink-2);
	}

	/* RWA segments: a steel lane between stations, lit ochre when the seized RWA crossed it. */
	.seg {
		position: relative;
		min-width: 0;
	}

	.seg .line {
		position: absolute;
		top: 26px;
		left: 4px;
		right: 10px;
		height: 2px;
		background: color-mix(in srgb, var(--color-steel) 75%, transparent);
	}

	.seg .line::after {
		content: '';
		position: absolute;
		top: -4px;
		right: -8px;
		border: 5px solid transparent;
		border-left: 8px solid color-mix(in srgb, var(--color-steel) 75%, transparent);
	}

	.seg .fill {
		position: absolute;
		inset: -1px 0;
		transform-origin: left;
		transform: scaleX(0);
	}

	/* One progress value runs the whole route: segment i fills during its share of it. */
	.seg.lit .fill {
		transform: scaleX(clamp(0, calc(var(--p) * var(--n) - var(--i) + 1), 1));
	}

	.seg.lit:not(.dashed) .fill {
		background: var(--color-accent);
	}

	.seg.lit:not(.dashed) .line::after {
		border-left-color: var(--color-accent);
		opacity: clamp(0, calc(var(--p) * var(--n) - var(--i) + 1), 1);
	}

	/* A simulation is dashed steel, never ochre: nothing crossed the rail. */
	.seg.lit.dashed .fill {
		background: repeating-linear-gradient(90deg, var(--color-steel) 0 6px, transparent 6px 10px);
	}

	.label {
		font-size: 11px;
		line-height: 13px;
		color: var(--color-steel);
		white-space: nowrap;
	}

	.rwa-label {
		position: absolute;
		left: 4px;
		right: 10px;
		bottom: calc(100% - 24px);
		text-align: center;
		white-space: normal;
	}

	.seg.lit:not(.dashed) .rwa-label {
		color: var(--color-accent);
		font-weight: 600;
		opacity: clamp(0, calc(var(--p) * var(--n) - var(--i) + 1), 1);
	}

	.usdc-label,
	.split {
		display: none;
	}

	.verdict {
		grid-column: 2 / 10;
		grid-row: 4;
		align-self: center;
		padding: 0 6px;
		font-size: 12px;
		color: var(--color-ink);
	}

	/* Between the direct route's corners, which run down the market and keeper columns. */
	[data-scene='stopped'] .verdict {
		grid-column: 3 / 9;
	}

	.verdict.bad {
		color: var(--color-alert);
		font-weight: 600;
	}

	.foot {
		grid-area: foot;
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		gap: 0 24px;
		margin-top: 2px;
		padding-top: 2px;
		border-top: 1px dotted var(--color-rule);
		font-size: 11px;
		color: var(--color-ink-2);
	}

	.foot .num {
		color: var(--color-ink);
	}

	.foot .missing {
		padding: 0 4px;
		border: 1px solid var(--color-reset);
		border-radius: 3px;
	}

	.foot .failed {
		color: var(--color-alert);
	}

	/*
	 * Shows the seized RWA crossing the rail and USDC returning; the only motion on the page
	 * (MOTION 2). One ease-out sweep per route, never looped; with reduced motion the global rule
	 * drops the animation and --p and --q keep their final value of 1, so the path shows lit at once.
	 */
	.rail[data-play] {
		animation:
			rwa-sweep calc(var(--n) * 240ms) cubic-bezier(0.2, 0.7, 0.3, 1) both,
			usdc-return 500ms ease-out calc(var(--n) * 240ms) both;
	}

	@keyframes rwa-sweep {
		from {
			--p: 0;
		}
		to {
			--p: 1;
		}
	}

	@keyframes usdc-return {
		from {
			--q: 0;
		}
		to {
			--q: 1;
		}
	}

	/* Below the demo width the rail turns vertical, and lanes become text beside each segment. */
	@media (max-width: 1100px) {
		.rail {
			--tie: 9px;
			grid-template-columns: minmax(0, 1fr);
			grid-template-rows: none;
			grid-template-areas:
				'head'
				'market'
				's1'
				'adapter'
				's2'
				'pa'
				's3'
				'poolManager'
				'keeper'
				'split'
				'verdict'
				'foot';
			padding: 8px 12px;
		}

		.title {
			padding-bottom: 6px;
		}

		.legend {
			display: none;
		}

		.seg {
			display: flex;
			flex-wrap: wrap;
			align-items: center;
			gap: 2px 18px;
			min-height: 30px;
			padding-left: 24px;
		}

		.seg .line {
			top: 0;
			bottom: 6px;
			left: calc(var(--tie) - 1px);
			right: auto;
			width: 2px;
			height: auto;
		}

		.seg .line::after {
			top: auto;
			right: auto;
			bottom: -9px;
			left: -4px;
			border: 5px solid transparent;
			border-top: 8px solid color-mix(in srgb, var(--color-steel) 75%, transparent);
		}

		.seg.lit:not(.dashed) .line::after {
			border-left-color: transparent;
			border-top-color: var(--color-accent);
		}

		.seg .fill {
			inset: 0 -1px;
			transform-origin: top;
			transform: scaleY(0);
		}

		.seg.lit .fill {
			transform: scaleY(clamp(0, calc(var(--p) * var(--n) - var(--i) + 1), 1));
		}

		.seg.lit.dashed .fill {
			background: repeating-linear-gradient(180deg, var(--color-steel) 0 6px, transparent 6px 10px);
		}

		.rwa-label {
			position: static;
			text-align: left;
		}

		.rwa-label::before {
			content: '↓ ';
		}

		.usdc-label {
			display: inline;
		}

		.usdc-label::before {
			content: '↑ ';
		}

		[data-scene='mined'] .usdc-label {
			color: var(--color-ink);
			font-weight: 600;
		}

		.split {
			display: block;
			grid-area: split;
			padding: 4px 6px 0 24px;
			font-size: 12px;
			color: var(--color-ink-2);
		}

		[data-scene='mined'] .split {
			color: var(--color-ink);
			font-weight: 600;
		}

		.verdict,
		[data-scene='stopped'] .verdict {
			grid-area: verdict;
			padding: 6px 6px 0 24px;
		}

		.foot {
			margin-top: 8px;
		}
	}
</style>
