<script lang="ts">
	import { ACTION_LABELS, ACTION_PENDING } from '$lib/actions';
	import type { Demo } from '$lib/demo.svelte';
	import type { ActionName } from '$lib/types';

	type Props = {
		demo: Demo;
		action: ActionName;
		/** Id of an element, rendered once by the panel, that explains why this action is blocked. */
		blockedBy?: string | null;
		tone?: 'primary' | 'quiet' | 'warn';
	};

	let { demo, action, blockedBy = null, tone = 'primary' }: Props = $props();
	const uid = $props.id();

	let isPending = $derived(demo.pending === action);
	let waiting = $derived(demo.state === null);
	let unavailable = $derived(demo.pending !== null || waiting || blockedBy !== null);
	let failure = $derived(demo.actionError?.action === action ? demo.actionError.message : null);
	let describedBy = $derived(
		[blockedBy, failure ? `${uid}-note` : null].filter(Boolean).join(' ') || undefined
	);

	function press() {
		if (unavailable) return;
		void demo.run(action);
	}
</script>

<div class="slot">
	<!-- aria-disabled keeps the button focusable, so keyboard users can still reach the reason. -->
	<button
		type="button"
		class={['action', tone, { pending: isPending }]}
		aria-disabled={unavailable}
		aria-busy={isPending}
		aria-describedby={describedBy}
		onclick={press}
	>
		{isPending ? ACTION_PENDING[action] : ACTION_LABELS[action]}
	</button>
	{#if failure}
		<p class="note" id="{uid}-note" role="alert">{failure}</p>
	{/if}
</div>

<style>
	.slot {
		display: grid;
		gap: 3px;
		min-width: 0;
	}

	.action {
		width: 100%;
		min-height: 29px;
		padding: 5px 8px;
		border: 1px solid var(--color-steel);
		border-radius: 4px;
		background: var(--color-steel);
		color: var(--color-steel-ink);
		font: 600 12.5px/1.2 var(--font-body);
		text-align: left;
		cursor: pointer;
	}

	.action:hover:not([aria-disabled='true']) {
		background: var(--color-steel-deep);
	}

	.quiet {
		background: var(--color-sheet);
		color: var(--color-steel);
	}

	.quiet:hover:not([aria-disabled='true']) {
		background: color-mix(in srgb, var(--color-steel) 10%, var(--color-sheet));
	}

	.warn {
		border-color: var(--color-alert);
		background: var(--color-sheet);
		color: var(--color-alert);
	}

	.warn:hover:not([aria-disabled='true']) {
		background: color-mix(in srgb, var(--color-alert) 8%, var(--color-sheet));
	}

	.action[aria-disabled='true'] {
		cursor: not-allowed;
		opacity: 0.45;
	}

	.action.pending {
		opacity: 1;
		cursor: progress;
		background-image: repeating-linear-gradient(
			90deg,
			transparent 0 10px,
			color-mix(in srgb, currentColor 14%, transparent) 10px 20px
		);
	}

	.note {
		font-size: 12px;
		line-height: 1.3;
		color: var(--color-alert);
	}
</style>
