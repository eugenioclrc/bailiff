<script lang="ts">
	import { formatUnit, shortAddress } from '$lib/format';
	import type { DecodedArg, DecodedLog } from '$lib/types';
	import { argUnit, emitterName } from '$lib/view';

	type Props = { logs: DecodedLog[]; rwaIsCurrency0: boolean };
	let { logs, rwaIsCurrency0 }: Props = $props();

	/** Full values without a mouse: the title tooltips below only help pointer users. */
	let showFull = $state(false);

	/** The canonical hook Swap is the evidence row: its emitter, pool id and sender are always full. */
	function isFull(log: DecodedLog): boolean {
		return showFull || log.swap?.canonical === true;
	}

	/** A role name stays in the body face; only the hex beside it is set in mono (DESIGN.md). */
	type ArgShown = { label?: string; hex?: string; text?: string };

	function argShown(log: DecodedLog, arg: DecodedArg): ArgShown {
		const full = isFull(log);
		if (arg.type === 'address') {
			if (full) return { label: arg.label, hex: arg.value };
			return arg.label ? { label: arg.label } : { hex: shortAddress(arg.value) };
		}
		if (arg.type === 'bytes32') return { hex: full ? arg.value : `${arg.value.slice(0, 10)}…` };
		if (/^-?\d+$/.test(arg.value))
			return {
				text: formatUnit(arg.value, argUnit(log.emitter, log.event, arg.name, rwaIsCurrency0))
			};
		return { text: arg.value };
	}

	function swapText(log: DecodedLog): string {
		const swap = log.swap;
		if (!swap) return '';
		if (swap.canonical)
			return 'Canonical hook Swap: hook emitter, this pool id, adapter as sender.';
		const parts = [
			swap.emitter === 'poolManager'
				? 'PoolManager copy (same signature, other emitter)'
				: swap.emitter === 'hook'
					? 'Hook Swap'
					: 'Not emitted by the hook or PoolManager',
			swap.poolIdMatches ? 'this pool id' : 'another pool id',
			swap.senderIsAdapter ? 'adapter as sender' : 'another sender'
		];
		return `${parts.join(', ')}.`;
	}
</script>

<button
	type="button"
	class="values-toggle"
	aria-pressed={showFull}
	onclick={() => (showFull = !showFull)}>Show full values</button
>
<div class="wrap">
	<table>
		<thead>
			<tr>
				<th scope="col">logIndex</th>
				<th scope="col">Emitter</th>
				<th scope="col">Event</th>
				<th scope="col">Arguments</th>
			</tr>
		</thead>
		<tbody>
			{#each logs as log (log.logIndex)}
				<tr class={{ canonical: log.swap?.canonical }}>
					<td class="num idx">{log.logIndex}</td>
					<td>
						{emitterName(log.emitter)}
						<code class="addr" title={log.address}
							>{isFull(log) ? log.address : shortAddress(log.address)}</code
						>
					</td>
					<td>
						{log.event ?? 'undecoded'}
						{#if log.swap}<span class="attr">{swapText(log)}</span>{/if}
					</td>
					<td class="args">
						{#each log.args as arg (arg.name)}
							{@const shown = argShown(log, arg)}
							<span class="arg" title={arg.value}
								><span class="key">{arg.name}</span>
								{#if shown.label}{shown.label}{/if}
								{#if shown.hex}<code>{shown.hex}</code>{/if}
								{#if shown.text !== undefined}<span class="num">{shown.text}</span>{/if}</span
							>
						{/each}
					</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>

<style>
	.values-toggle {
		margin: 4px 0 2px;
		padding: 2px 8px;
		border: 1px solid var(--color-steel);
		border-radius: 4px;
		background: var(--color-sheet);
		color: var(--color-ink);
		font: 600 12px/1.2 var(--font-body);
		cursor: pointer;
	}

	.values-toggle[aria-pressed='true'] {
		border-color: var(--color-ink);
		background: var(--color-ink);
		color: var(--color-sheet);
	}

	@media (max-width: 1100px), (pointer: coarse) {
		.values-toggle {
			min-height: 44px;
		}
	}

	/* Wide receipts scroll inside the entry instead of widening the page on small screens. */
	.wrap {
		overflow-x: auto;
	}

	table {
		width: 100%;
		min-width: 560px;
		border-collapse: collapse;
		font-size: 12px;
	}

	th {
		text-align: left;
		font-weight: 600;
		color: var(--color-ink-2);
		border-bottom: 1px solid var(--color-rule);
		padding: 3px 6px;
	}

	td {
		vertical-align: top;
		padding: 3px 6px;
		border-bottom: 1px dotted var(--color-rule);
	}

	.idx {
		width: 4.5em;
		text-align: right;
	}

	.addr {
		display: block;
		color: var(--color-ink-2);
		font-size: 10.5px;
	}

	.attr {
		display: block;
		font-size: 11px;
		color: var(--color-ink-2);
	}

	.canonical {
		background: color-mix(in srgb, var(--color-ok) 9%, transparent);
	}

	.canonical .attr {
		color: var(--color-ok);
		font-weight: 600;
	}

	.args {
		display: flex;
		flex-wrap: wrap;
		gap: 2px 12px;
	}

	.key {
		color: var(--color-ink-2);
	}
</style>
