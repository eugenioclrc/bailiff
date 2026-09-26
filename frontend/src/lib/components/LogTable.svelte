<script lang="ts">
	import { formatUnit, shortAddress } from '$lib/format';
	import type { DecodedArg, DecodedLog } from '$lib/types';
	import { argUnit, emitterName } from '$lib/view';

	type Props = { logs: DecodedLog[]; rwaIsCurrency0: boolean };
	let { logs, rwaIsCurrency0 }: Props = $props();

	/** The canonical hook Swap is the evidence row: its emitter, pool id and sender are shown in full. */
	function argText(log: DecodedLog, arg: DecodedArg): string {
		const full = log.swap?.canonical === true;
		if (arg.type === 'address') {
			if (full) return arg.label ? `${arg.label} ${arg.value}` : arg.value;
			return arg.label ?? shortAddress(arg.value);
		}
		if (arg.type === 'bytes32') return full ? arg.value : `${arg.value.slice(0, 10)}…`;
		if (/^-?\d+$/.test(arg.value))
			return formatUnit(arg.value, argUnit(log.emitter, log.event, arg.name, rwaIsCurrency0));
		return arg.value;
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
							>{log.swap?.canonical ? log.address : shortAddress(log.address)}</code
						>
					</td>
					<td>
						{log.event ?? 'undecoded'}
						{#if log.swap}<span class="attr">{swapText(log)}</span>{/if}
					</td>
					<td class="args">
						{#each log.args as arg (arg.name)}
							<span class="arg" title={arg.value}
								><span class="key">{arg.name}</span>
								<span
									class={[
										'num',
										{
											code:
												log.swap?.canonical && (arg.type === 'address' || arg.type === 'bytes32')
										}
									]}>{argText(log, arg)}</span
								></span
							>
						{/each}
					</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>

<style>
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
