<script lang="ts">
	import { ACTION_LABELS, CONTROL_LABELS } from '$lib/actions';
	import type { TimelineItem } from '$lib/demo.svelte';
	import { formatUnit, shortAddress } from '$lib/format';
	import type { ActionItem } from '$lib/timeline';
	import { probeStatusLabel, statusLabel } from '$lib/view';
	import LogTable from './LogTable.svelte';
	import ReconcileSummary from './ReconcileSummary.svelte';
	import RevertChain from './RevertChain.svelte';

	type Props = { item: TimelineItem; newest: boolean; rwaIsCurrency0: boolean };
	let { item, newest, rwaIsCurrency0 }: Props = $props();

	const ROLE_NAMES = { issuer: 'issuer', mm: 'market maker', keeper: 'keeper' } as const;

	function kindOf(entry: ActionItem): 'reset' | 'simulation' | 'failed' | 'mined' {
		const { response } = entry;
		if (response.status === 'reset') return 'reset';
		if (response.status === 'simulation-reverted') return 'simulation';
		return response.error ? 'failed' : 'mined';
	}

	let kind = $derived(item.kind === 'probe' ? 'simulation' : kindOf(item));
	let title = $derived(item.kind === 'probe' ? CONTROL_LABELS.probe : ACTION_LABELS[item.action]);
	let tag = $derived(
		item.kind === 'probe' ? probeStatusLabel(item.quote) : statusLabel(item.response)
	);
	let simulationFrom = $derived(
		item.kind === 'probe' ? item.from : item.response.detail.simulations.at(-1)?.from
	);
</script>

<article class={['entry', kind]} aria-label="{title}: {tag}">
	<header>
		<span class="tag">{tag}</span>
		<h3>{title}</h3>
		{#if kind === 'simulation'}
			<span class="who"
				>eth_call from {simulationFrom ? shortAddress(simulationFrom) : 'the signer'}; nothing was
				sent</span
			>
		{:else if item.kind === 'action' && item.response.detail.signer}
			<span class="who"
				>signed by {ROLE_NAMES[item.response.detail.signer.role]}
				<code>{shortAddress(item.response.detail.signer.address)}</code></span
			>
		{/if}
		<time>{item.at}</time>
	</header>

	{#if item.kind === 'probe'}
		<p class="call"><code>{item.call}</code></p>
		{#if item.quote.ok}
			<p class="body">
				Would repay and pay the keeper a bounty of
				<span class="num">{formatUnit(item.quote.bounty, 'usdc')}</span> USDC, simulated on the
				block after <span class="num">{item.block}</span>. Recorded on this page only; no
				transaction.
			</p>
		{:else if item.quote.revert}
			<RevertChain revert={item.quote.revert} />
		{:else}
			<p class="body failed-note">{item.quote.error.name}: {item.quote.error.message}</p>
		{/if}
	{:else}
		{@const response = item.response}
		{@const detail = response.detail}
		<p class="call"><code>{detail.call}</code></p>

		{#if response.status === 'reset' && detail.reset}
			<p class="body">
				Anvil <code>evm_revert({detail.reset.revertedTo})</code> returned true, then
				<code>evm_snapshot</code>
				saved
				<code>{response.snapshotId}</code> for the next reset. Chain back at block
				<span class="num">{detail.reset.blockNumber}</span>. The discarded branch moved to earlier
				branches below.
			</p>
		{/if}

		{#if response.txHash}
			<p class="tx">
				Local Anvil tx <code class="hash">{response.txHash}</code>
				{#if detail.receipt}
					in block <span class="num">{detail.receipt.blockNumber}</span>, gas used
					<span class="num">{formatUnit(detail.receipt.gasUsed, 'raw')}</span>
				{/if}
			</p>
		{/if}

		{#if detail.quote}
			<p class="body">
				Quoted bounty <span class="num">{formatUnit(detail.quote.bounty, 'usdc')}</span> USDC;
				{#if response.status === 'mined'}
					sent with minBounty
					<span class="num">{formatUnit(detail.quote.minBounty, 'usdc')}</span> USDC (97%), re-simulated
					with those exact arguments.
				{:else}
					prepared minBounty
					<span class="num">{formatUnit(detail.quote.minBounty, 'usdc')}</span> USDC (97%); nothing was
					sent.
				{/if}
			</p>
		{/if}

		{#if response.error && response.status === 'mined'}
			<p class="body failed-note">{response.error.message}</p>
		{/if}

		{#if detail.revert}
			<RevertChain revert={detail.revert} />
		{/if}

		{#if detail.reconciliation}
			<ReconcileSummary reconciliation={detail.reconciliation} />
		{/if}
		{#if detail.reconciliationError}
			<p class="body failed-note">{detail.reconciliationError}</p>
		{/if}

		{#if detail.receipt}
			<details open={newest}>
				<summary>Receipt logs, {detail.receipt.logs.length}, in logIndex order</summary>
				<LogTable logs={detail.receipt.logs} {rwaIsCurrency0} />
			</details>
		{/if}
	{/if}
</article>

<style>
	.entry {
		display: grid;
		gap: 5px;
		padding: 8px 10px 8px 12px;
		background: var(--color-sheet);
		border: 1px solid var(--color-rule);
		border-left: 4px solid var(--color-steel);
		border-radius: 4px;
	}

	.simulation {
		border-left-style: dashed;
		border-left-color: var(--color-sim);
		background: color-mix(in srgb, var(--color-sim) 4%, var(--color-sheet));
	}

	.reset {
		border-left-color: var(--color-reset);
		background: color-mix(in srgb, var(--color-reset) 6%, var(--color-sheet));
	}

	.failed {
		border-left-color: var(--color-alert);
	}

	header {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 4px 10px;
	}

	.tag {
		padding: 1px 7px;
		border-radius: 3px;
		font-size: 11.5px;
		font-weight: 600;
		color: var(--color-steel-ink);
		background: var(--color-steel);
	}

	.simulation .tag {
		background: transparent;
		color: var(--color-sim);
		border: 1px dashed var(--color-sim);
	}

	.reset .tag {
		background: var(--color-reset);
	}

	.failed .tag {
		background: var(--color-alert);
	}

	h3 {
		font: 400 19px/1 var(--font-display);
		padding-top: 2px;
	}

	.who {
		font-size: 12px;
		color: var(--color-ink-2);
	}

	time {
		margin-left: auto;
		font-size: 12px;
		color: var(--color-ink-2);
		font-variant-numeric: tabular-nums;
	}

	.call,
	.body,
	.tx {
		font-size: 12px;
	}

	.call {
		color: var(--color-ink-2);
	}

	.hash {
		font-size: 11.5px;
	}

	.failed-note {
		color: var(--color-alert);
	}

	summary {
		cursor: pointer;
		font-size: 12px;
		font-weight: 600;
		color: var(--color-steel);
	}
</style>
