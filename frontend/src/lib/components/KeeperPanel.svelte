<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { formatUnit } from '$lib/format';
	import type { Quote } from '$lib/types';
	import { holderOf, showFlags, showRead, type Shown } from '$lib/view';
	import ActionButton from './ActionButton.svelte';
	import Figure from './Figure.svelte';
	import Panel from './Panel.svelte';

	let { demo }: { demo: Demo } = $props();
	const uid = $props.id();

	let s = $derived(demo.state);
	let keeper = $derived(holderOf(s, 'keeper'));
	let blockedReason = $derived(s && !s.liquidation.enabled ? s.liquidation.reason : null);
	let blockedBy = $derived(blockedReason ? `${uid}-blocked` : null);
	let holdsNoRwa = $derived(keeper?.rwa.ok === true && keeper.rwa.value === '0');

	function showQuote(quote: Quote | undefined): Shown {
		if (!quote) return { text: 'read failed', tone: 'failed' };
		return quote.ok
			? { text: `bounty ${formatUnit(quote.bounty, 'usdc')}`, tone: 'value' }
			: { text: `would revert: ${quote.error.name}`, tone: 'value' };
	}

	/** Decoded reasons of quotes that revert for anything but a healthy position, shown on demand. */
	let quoteWhy = $derived.by(() => {
		if (!s) return [];
		const quotes: [string, Quote][] = [
			['Full close', s.quotes.full],
			['10,000 USDC', s.quotes.chunk]
		];
		return quotes.flatMap(([label, q]) =>
			!q.ok && q.error.name !== 'Healthy' ? [{ label, message: q.error.message }] : []
		);
	});

	/** A healthy position is expected to refuse liquidation; anything else is worth a red flag. */
	function quoteState(quote: Quote | undefined): 'good' | 'plain' | 'bad' {
		if (!quote) return 'plain';
		if (quote.ok) return 'good';
		return quote.error.name === 'Healthy' ? 'plain' : 'bad';
	}
</script>

<Panel
	title="Keeper"
	address={s?.addresses.keeper}
	blurb="Anyone can run it: no KYC flags, no USDC, no RWA."
	loaded={s !== null}
>
	<Figure label="USDC balance" shown={showRead(keeper?.usdc, 'usdc')} unit="USDC" />
	<Figure
		label="RWA balance"
		shown={showRead(keeper?.rwa, 'rwa')}
		unit="RWA"
		state={holdsNoRwa ? 'good' : 'bad'}
	/>
	<Figure label="Checker flags" shown={showFlags(keeper?.flags)} />
	<Figure
		label="Quote, full close"
		shown={showQuote(s?.quotes.full)}
		unit={s?.quotes.full.ok ? 'USDC' : undefined}
		state={quoteState(s?.quotes.full)}
		detail={s && !s.quotes.full.ok ? s.quotes.full.error.message : undefined}
	/>
	<Figure
		label="Quote, 10,000 USDC"
		shown={showQuote(s?.quotes.chunk)}
		unit={s?.quotes.chunk.ok ? 'USDC' : undefined}
		state={quoteState(s?.quotes.chunk)}
		detail={s && !s.quotes.chunk.ok ? s.quotes.chunk.error.message : undefined}
	/>

	{#snippet actions()}
		{#if quoteWhy.length}
			<details class="why">
				<summary>Why the quotes revert</summary>
				<ul>
					{#each quoteWhy as why (why.label)}
						<li><strong>{why.label}:</strong> {why.message}</li>
					{/each}
				</ul>
			</details>
		{/if}
		{#if blockedReason}
			<p class="blocked" id="{uid}-blocked">{blockedReason}</p>
		{/if}
		<!-- Both are eth_calls from the keeper and never send; the probe records the adapter route for O7. -->
		<div class="pair">
			<ActionButton {demo} action="horizon" tone="quiet" {blockedBy} />
			<ActionButton {demo} action="probe" tone="quiet" />
		</div>
		<div class="pair">
			<ActionButton {demo} action="liquidateFull" {blockedBy} />
			<ActionButton {demo} action="liquidateChunk" {blockedBy} />
		</div>
	{/snippet}
</Panel>

<style>
	.pair {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 6px;
	}

	.blocked {
		font-size: 12px;
		line-height: 1.3;
		color: var(--color-caution);
	}

	.why {
		font-size: 12px;
		line-height: 1.3;
	}

	.why summary {
		cursor: pointer;
		font-weight: 600;
		color: var(--color-alert);
	}

	.why ul {
		display: grid;
		gap: 2px;
		padding-top: 2px;
		overflow-wrap: anywhere;
	}
</style>
