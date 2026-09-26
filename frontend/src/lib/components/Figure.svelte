<script lang="ts">
	import type { Shown } from '$lib/view';

	type Props = {
		label: string;
		shown: Shown;
		unit?: string;
		/** Extra context after the value, e.g. an age or a verdict. */
		note?: string;
		state?: 'plain' | 'good' | 'bad';
		/** Full text for a value that is shortened on screen. */
		detail?: string;
	};

	let { label, shown, unit, note, state = 'plain', detail }: Props = $props();
</script>

<div class="row">
	<dt>{label}</dt>
	<dd class={['value', shown.tone, state]} title={detail}>
		<span class={{ num: shown.tone === 'value' }}>{shown.text}</span>
		{#if unit && shown.tone === 'value'}<span class="unit">{unit}</span>{/if}
		{#if note}<span class="note">{note}</span>{/if}
	</dd>
</div>

<style>
	.row {
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		align-items: baseline;
		gap: 8px;
		padding: 1px 0;
		border-bottom: 1px dotted color-mix(in srgb, var(--color-rule) 80%, transparent);
	}

	dt {
		color: var(--color-ink-2);
		font-size: 12px;
	}

	dd {
		text-align: right;
		font-size: 13.5px;
		white-space: nowrap;
	}

	.unit,
	.note {
		margin-left: 4px;
		color: var(--color-ink-2);
		font-size: 11.5px;
	}

	.missing {
		color: var(--color-caution);
		font-style: italic;
		font-size: 12px;
	}

	.failed {
		color: var(--color-alert);
		font-size: 12px;
	}

	.good .num {
		color: var(--color-ok);
	}

	.bad .num {
		color: var(--color-alert);
	}
</style>
