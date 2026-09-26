<script lang="ts" module>
	/** USDC lane labels: the receipt's amounts, or the lane names while no liquidation is mined. */
	export type Flow = { proceeds: string; repaid: string; bounty: string; residual: string | null };
</script>

<script lang="ts">
	/*
	 * The lanes drawn under the collateral rail's stations at the demo width: USDC coming back from
	 * PoolManager to the adapter and out to MiniLend, the keeper and the borrower wallet, or the
	 * keeper's own direct call. Drawn only, so hidden from screen readers; the rail's sentence
	 * carries the same facts. Below 1101px the rail lists them in text instead.
	 */
	type Props = {
		/** USDC lanes, labelled with the receipt's amounts, or with their names while idle. */
		flow: Flow | null;
		/** The keeper's own MiniLend call, and where it is refused. */
		direct: { stop: 'market' | 'keeper' | null } | null;
	};

	let { flow, direct }: Props = $props();
</script>

{#if flow}
	<div class="u um stage2" aria-hidden="true">
		<span class="h"></span><span class="v"></span><span class="tip up"></span>
	</div>
	<div class="u ur stage2" aria-hidden="true">
		<span class="h"></span><span class="label">{flow.repaid}</span>
	</div>
	<div class="u uj stage1" aria-hidden="true">
		<span class="h"></span><span class="v"></span>
	</div>
	<div class="u up stage1" aria-hidden="true">
		<span class="h"></span><span class="tip left"></span><span class="label">{flow.proceeds}</span>
	</div>
	<div class="u upm stage1" aria-hidden="true">
		<span class="h"></span><span class="v"></span>
	</div>
	<div class="u vj stage2" aria-hidden="true">
		<span class="v"></span>
		{#if flow.residual}<span class="h west"></span>{/if}
		<span class="h east"></span>
	</div>
	{#if flow.residual}
		<div class="u vr stage2" aria-hidden="true">
			<span class="h"></span><span class="tip left"></span><span class="label">{flow.residual}</span
			>
		</div>
	{/if}
	<div class="u vb stage2" aria-hidden="true">
		<span class="h"></span><span class="label">{flow.bounty}</span>
	</div>
	<div class="u vk stage2" aria-hidden="true">
		<span class="h"></span><span class="v"></span><span class="tip up"></span>
	</div>
{/if}

{#if direct}
	<!-- The keeper's own MiniLend call would pay the seized RWA straight to the keeper. -->
	<div class="d dm" aria-hidden="true">
		<span class="v"></span><span class="h"></span>
		{#if direct.stop === 'market'}<span class="barrier"></span>{/if}
	</div>
	<div class="d dl" aria-hidden="true"><span class="h"></span></div>
	<div class="d dk" aria-hidden="true">
		<span class="h"></span>
		{#if direct.stop === 'keeper'}<span class="barrier"></span>{/if}
	</div>
{/if}

<style>
	/*
	 * Each piece fills one grid cell of the rail's lane rows. --tie is where a lane meets the station
	 * above it; --ktie the same for the keeper, set further in by its dashed edge.
	 */
	.u,
	.d {
		position: relative;
		min-width: 0;
	}

	/* Idle: thin steel, the route's shape without amounts. */
	.u .h,
	.u .v {
		position: absolute;
		background: var(--color-steel);
	}

	.u .h {
		top: 7px;
		left: 0;
		right: 0;
		height: 1px;
	}

	.u .v {
		top: 0;
		bottom: 8px;
		left: var(--tie);
		width: 1px;
	}

	.tip {
		position: absolute;
		border: 4px solid transparent;
	}

	.tip.left {
		top: 4px;
		left: -2px;
		border-right: 7px solid var(--color-steel);
		border-left-width: 0;
	}

	.tip.up {
		top: -2px;
		left: calc(var(--tie) - 4px);
		border-bottom: 7px solid var(--color-steel);
		border-top-width: 0;
	}

	.label {
		position: absolute;
		top: 1px;
		left: 50%;
		transform: translateX(-50%);
		padding: 0 6px;
		background: var(--color-sheet);
		font-size: 11px;
		line-height: 13px;
		color: var(--color-steel);
		white-space: nowrap;
	}

	.um {
		grid-area: um;
	}

	.um .h {
		left: var(--tie);
	}

	.ur {
		grid-area: ur;
	}

	/*
	 * Right-aligned, so a long amount grows left over the plain lane toward MiniLend and never
	 * into the adapter's junction, whose line would strike through its last word.
	 */
	.ur .label {
		left: auto;
		right: 6px;
		transform: none;
	}

	.uj {
		grid-area: uj;
	}

	.uj .v {
		bottom: 0;
	}

	.up {
		grid-area: up;
	}

	.upm {
		grid-area: upm;
	}

	.upm .h {
		right: auto;
		width: var(--tie);
	}

	.vj {
		grid-area: vj;
	}

	.vj .v {
		bottom: auto;
		height: 8px;
	}

	.vj .h.west {
		right: auto;
		width: var(--tie);
	}

	.vj .h.east {
		left: var(--tie);
	}

	.vr {
		grid-area: vr;
	}

	.vr .label {
		left: 45%;
	}

	.vb {
		grid-area: vb;
	}

	.vk {
		grid-area: vk;
	}

	.vk .h {
		top: 23px;
		right: auto;
		width: var(--ktie);
	}

	.vk .v {
		left: var(--ktie);
		bottom: 8px;
	}

	.vk .tip.up {
		left: calc(var(--ktie) - 4px);
	}

	/*
	 * Mined: ink lanes with the receipt's amounts, filling toward the adapter first (stage 1), then
	 * out to MiniLend, the keeper and the wallet (stage 2), on the rail's --q progress.
	 */
	:global([data-scene='mined']) .u .h,
	:global([data-scene='mined']) .u .v {
		background: var(--color-ink);
	}

	:global([data-scene='mined']) .u .h {
		height: 2px;
	}

	:global([data-scene='mined']) .u .v {
		width: 2px;
	}

	:global([data-scene='mined']) .tip.left {
		border-right-color: var(--color-ink);
	}

	:global([data-scene='mined']) .tip.up {
		border-bottom-color: var(--color-ink);
	}

	:global([data-scene='mined']) .label {
		color: var(--color-ink);
		font-weight: 600;
	}

	:global([data-scene='mined']) .stage1 {
		opacity: clamp(0, calc(var(--q) * 2), 1);
	}

	:global([data-scene='mined']) .stage2 {
		opacity: clamp(0, calc(var(--q) * 2 - 1), 1);
	}

	/* The direct route: dashed, like every simulation, off the rail from MiniLend to the keeper. */
	.d .h,
	.d .v {
		position: absolute;
		background: repeating-linear-gradient(90deg, var(--color-steel) 0 6px, transparent 6px 10px);
		opacity: clamp(0, calc(var(--p) * 1.5), 1);
	}

	.d .v {
		background: repeating-linear-gradient(180deg, var(--color-steel) 0 6px, transparent 6px 10px);
	}

	.dm {
		grid-column: 2;
		grid-row: 4 / 6;
	}

	.dm .v {
		top: 0;
		left: var(--tie);
		width: 2px;
		height: 24px;
	}

	.dm .h {
		top: 23px;
		left: var(--tie);
		right: 0;
		height: 2px;
	}

	.dl {
		grid-column: 3 / 9;
		grid-row: 5;
	}

	.dl .h {
		top: 7px;
		left: 0;
		right: 0;
		height: 2px;
	}

	.dk {
		grid-column: 9;
		grid-row: 5;
	}

	.dk .h {
		top: 7px;
		left: 0;
		width: calc(var(--ktie) - 6px);
		height: 2px;
	}

	/* Where the direct route is refused: before the keeper's wallet, or at MiniLend's door. */
	.barrier {
		position: absolute;
		width: 4px;
		height: 20px;
		background: var(--color-alert);
	}

	.dk .barrier {
		top: -2px;
		left: calc(var(--ktie) - 6px);
	}

	.dm .barrier {
		top: 14px;
		left: calc(var(--tie) + 6px);
	}

	:global(.rail[data-play]) .barrier {
		animation: barrier-in 160ms ease-out 240ms both;
	}

	@keyframes barrier-in {
		from {
			opacity: 0;
		}
		to {
			opacity: 1;
		}
	}

	/* Below the demo width the rail stacks and states these lanes in text beside each segment. */
	@media (max-width: 1100px) {
		.u,
		.d {
			display: none;
		}
	}
</style>
