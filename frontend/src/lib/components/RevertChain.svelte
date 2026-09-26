<script lang="ts">
	import { shortAddress } from '$lib/format';
	import type { DecodedArg, DecodedRevert, ErrorLayer } from '$lib/types';
	import { errorArgText } from '$lib/units';

	let { revert }: { revert: DecodedRevert } = $props();

	/** Only a WrappedError names the reverting contract; a top-level error may have bubbled up. */
	function where(layer: ErrorLayer, index: number): string {
		if (!layer.target) return '';
		const name = `${layer.target.label ?? 'contract'} ${shortAddress(layer.target.address)}`;
		return revert.layers[index - 1]?.kind === 'wrapped'
			? `, raised by ${name}`
			: `, returned by the call to ${name}`;
	}

	function callName(call: string | undefined): string {
		if (!call) return 'a call';
		const fn = call.includes('.') ? call.slice(call.indexOf('.') + 1) : call;
		return fn.includes('(') ? `${fn.slice(0, fn.indexOf('('))}()` : fn;
	}

	/** Amounts in token units (proceeds=67,916.35 USDC); the raw integers stay in the tooltip. */
	function argText(arg: DecodedArg): string {
		return `${arg.name}=${arg.label ?? errorArgText(arg.name, arg.value) ?? arg.value}`;
	}

	function rawArgs(layer: ErrorLayer): string | undefined {
		return layer.args.length ? layer.args.map((a) => `${a.name}=${a.value}`).join(', ') : undefined;
	}

	function describe(layer: ErrorLayer, index: number): string {
		switch (layer.kind) {
			case 'wrapped':
				return layer.truncated
					? `WrappedError nested too deep: ${callName(layer.call)} failed; the inner reason was kept raw, not decoded`
					: `WrappedError: ${callName(layer.call)} failed, context ${layer.context ?? 'none'}`;
			case 'empty':
				return `Reverted without error data${where(layer, index)}`;
			case 'unknown':
				return `Unknown error selector ${layer.selector}${where(layer, index)}; raw data kept`;
			default: {
				const args = layer.args.map(argText).join(', ');
				const declared = layer.declaredBy.length
					? ` (declared by ${layer.declaredBy.join(', ')})`
					: '';
				return `${layer.name}(${args})${where(layer, index)}${declared}`;
			}
		}
	}
</script>

<div class="revert">
	<p class="cause"><strong>{revert.name}</strong></p>
	<ol class="layers" aria-label="Decoded revert, outermost to innermost">
		{#each revert.layers as layer, i (i)}
			<li style:--depth={i} title={rawArgs(layer)}>{describe(layer, i)}</li>
		{/each}
	</ol>
</div>

<style>
	.revert {
		display: grid;
		gap: 2px;
		padding: 6px 8px;
		border-left: 3px solid var(--color-alert);
		background: color-mix(in srgb, var(--color-alert) 6%, var(--color-sheet));
	}

	.cause {
		color: var(--color-alert);
		font: 400 18px/1 var(--font-display);
		padding-top: 2px;
	}

	.layers li {
		padding-left: calc(var(--depth) * 14px);
		font-size: 12px;
		overflow-wrap: anywhere;
	}

	.layers li + li::before {
		content: '↳ ';
		color: var(--color-ink-2);
	}
</style>
