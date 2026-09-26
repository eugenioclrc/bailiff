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
	<!-- No whitespace between amount and unit: the pair never splits when the value wraps. -->
	<dd class={['value', shown.tone, state]} title={detail}>
		<span class={{ num: shown.tone === 'value' }}>{shown.text}</span
		>{#if unit && shown.tone === 'value'}<span class="unit">{unit}</span>{/if}
		{#if note}<span class="note">{note}</span>{/if}
	</dd>
</div>

<style>
	/*
	 * The label never shrinks below its longest word, so a wide value can no longer run under it
	 * ("CheckeHOLDER" at 1101px); the value wraps between words instead, and only when it must.
	 */
	.row {
		display: grid;
		grid-template-columns: minmax(min-content, 1fr) auto;
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
	}

	.unit,
	.note {
		margin-left: 4px;
		color: var(--color-ink-2);
		font-size: 11.5px;
	}

	/* A real status, not a value: a neutral outlined badge in the local-reset grey, never the accent. */
	.missing {
		font-size: 12px;
	}

	.missing span {
		display: inline-block;
		line-height: 1.15;
		padding: 0 5px;
		border: 1px solid var(--color-reset);
		border-radius: 3px;
		color: var(--color-ink-2);
		font-size: 11.5px;
		white-space: nowrap;
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
