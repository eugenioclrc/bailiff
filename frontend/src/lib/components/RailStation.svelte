<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { Shown } from '$lib/view';

	type Props = {
		/** Grid area of the collateral rail this station sits in. */
		area: string;
		name: string;
		/** RWA balance; holdsRwa flags a leftover where none may stay, never rounded away. */
		balance: Shown & { holdsRwa: boolean };
		unit: string;
		/** Width of the balance slot in figures: the widest balance this station holds in the demo. */
		slot: number;
		/** The one raised station: the adapter that liquidated, or the station that refused. */
		active?: boolean;
		refuses?: boolean;
		/** Where a refused route hits it: its entry, or the market's exit. */
		barrier?: 'entry' | 'exit' | null;
		/** Stacked layouts only: the direct route stops at this station's edge (the keeper). */
		stackedBarrier?: boolean;
		/** The keeper: off the rail, set apart by a dashed edge. */
		offRail?: boolean;
		context: Snippet;
	};

	let {
		area,
		name,
		balance,
		unit,
		slot,
		active = false,
		refuses = false,
		barrier = null,
		stackedBarrier = false,
		offRail = false,
		context
	}: Props = $props();
</script>

<div
	class={['station', { active, refuses, 'off-rail': offRail }]}
	style:grid-area={area}
	style:--slot="{slot}ch"
>
	<span class="name">{name}</span>
	<span class="holding"
		><span
			class={['amount', balance.tone, { num: balance.tone === 'value', bad: balance.holdsRwa }]}
			>{balance.text}</span
		>{#if balance.tone === 'value'}<span class="unit">{unit}</span>{/if}</span
	>
	<span class="context">{@render context()}</span>
	{#if barrier}
		<span class={['barrier', barrier]} aria-hidden="true"></span>
	{/if}
	{#if stackedBarrier}
		<span class="barrier stacked-only" aria-hidden="true"></span>
	{/if}
</div>

<style>
	/* Name, balance, context on three rows every station shares, so the balances line up. */
	.station {
		position: relative;
		display: grid;
		grid-template-rows: 14px 26px 16px;
		padding: 0 6px;
		border: 1px solid transparent;
		border-radius: 4px;
	}

	.off-rail {
		margin-left: 14px;
		padding-left: 14px;
		border-left: 1px dashed var(--color-rule);
		border-radius: 0;
	}

	/* The only shadow on the page: the station that acted or refused (DESIGN.md). */
	.active {
		border-color: var(--color-steel);
		box-shadow: 0 1px 4px rgb(28 27 24 / 0.2);
	}

	.refuses {
		border-color: var(--color-alert);
	}

	.name {
		font-size: 12px;
		line-height: 14px;
		color: var(--color-ink-2);
		white-space: nowrap;
	}

	/*
	 * A fixed slot, in figures of the balance's own size, wide enough for the largest balance this
	 * station holds in the demo (50,935.2941): the rail never shifts when a balance grows.
	 */
	.holding {
		align-self: center;
		min-width: var(--slot);
		font-size: 22px;
		line-height: 26px;
		white-space: nowrap;
	}

	.amount.missing,
	.amount.failed {
		font-size: 12px;
		line-height: 16px;
	}

	.amount.missing {
		padding: 0 5px;
		border: 1px solid var(--color-reset);
		border-radius: 3px;
		color: var(--color-ink-2);
	}

	.amount.failed {
		color: var(--color-alert);
	}

	/* A leftover wei where none may stay: a solid chip, readable at a glance on the recording. */
	.amount.bad {
		padding: 0 5px;
		border-radius: 3px;
		background: var(--color-alert);
		color: #fff;
	}

	/* Balances that predate the last action: grey ink as well as the page-wide hatch. */
	:global([data-stale='true']) .amount.num:not(.bad) {
		color: var(--color-ink-2);
	}

	.unit {
		margin-left: 4px;
		font-size: 11px;
		color: var(--color-ink-2);
	}

	.context {
		display: flex;
		gap: 10px;
		font-size: 11.5px;
		line-height: 16px;
		color: var(--color-ink-2);
		white-space: nowrap;
	}

	/* A red bar where the route is refused: at the station's entry, or the market's exit. */
	.barrier {
		position: absolute;
		top: 16px;
		left: -3px;
		width: 4px;
		height: 22px;
		background: var(--color-alert);
	}

	.barrier.exit {
		left: auto;
		right: -3px;
	}

	.barrier.stacked-only {
		display: none;
	}

	/* The rail's one motion: the bar lands once the route has run up to it. */
	:global(.rail[data-play]) .barrier {
		animation: barrier-in 160ms ease-out calc(var(--n) * 240ms) both;
	}

	@keyframes barrier-in {
		from {
			opacity: 0;
		}
		to {
			opacity: 1;
		}
	}

	/* 641 to 1100px: one station per row, name, balance and context spread across the width. */
	@media (max-width: 1100px) {
		.station {
			grid-template-rows: none;
			grid-template-columns: 180px 11em minmax(0, 1fr);
			align-items: baseline;
			column-gap: 12px;
			padding: 2px 6px 2px 24px;
		}

		/* A station marker on the vertical lane. */
		.station::before {
			content: '';
			position: absolute;
			top: calc(50% - 4px);
			left: calc(var(--tie) - 4px);
			width: 8px;
			height: 8px;
			border-radius: 2px;
			background: var(--color-steel);
		}

		.off-rail {
			margin: 8px 0 0;
			padding-left: 24px;
			border-left: 0;
			border-top: 1px dashed var(--color-rule);
		}

		.off-rail::before {
			background: transparent;
			border: 1px dashed var(--color-steel);
		}

		.context {
			flex-wrap: wrap;
			white-space: normal;
		}

		.barrier,
		.barrier.exit,
		.barrier.stacked-only {
			display: block;
			top: -2px;
			left: 18px;
			right: auto;
			width: 22px;
			height: 4px;
		}
	}

	/* Phones: name and balance on one line, the context under them. */
	@media (max-width: 640px) {
		.station {
			grid-template-columns: minmax(0, 1fr) auto;
			grid-template-areas:
				'name holding'
				'context context';
		}

		.name {
			grid-area: name;
			white-space: normal;
		}

		.holding {
			grid-area: holding;
			min-width: 0;
			font-size: 20px;
			line-height: 24px;
		}

		.context {
			grid-area: context;
		}
	}
</style>
