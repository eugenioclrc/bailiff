<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { healthStatus, holderOf, showHealth, showRead } from '$lib/view';
	import Figure from './Figure.svelte';
	import Panel from './Panel.svelte';

	let { demo }: { demo: Demo } = $props();

	let s = $derived(demo.state);
	let hf = $derived(showHealth(s?.market.healthFactor));
	let status = $derived(healthStatus(s?.market.healthFactor));
	const STATUS_TEXT = {
		healthy: 'Healthy: HF at or above 1',
		liquidatable: 'Liquidatable: HF below 1',
		'no-debt': 'No debt left',
		unknown: 'Health factor unavailable'
	} as const;
</script>

<Panel
	title="Borrower"
	address={s?.addresses.borrower}
	blurb="Posted RWA collateral. No key on this server."
	loaded={s !== null}
>
	<div class="health" data-status={status}>
		<dt>Health factor</dt>
		<dd>
			<span class={{ num: hf.tone === 'value', big: true }}>{hf.text}</span>
			<span class="status">{STATUS_TEXT[status]}</span>
		</dd>
	</div>
	<Figure label="Collateral in market" shown={showRead(s?.market.collateral, 'rwa')} unit="RWA" />
	<Figure label="Debt" shown={showRead(s?.market.debt, 'usdc')} unit="USDC" />
	<Figure label="Wallet USDC" shown={showRead(holderOf(s, 'borrower')?.usdc, 'usdc')} unit="USDC" />
	<Figure
		label="Withdrawable by borrower"
		shown={showRead(s?.market.claimableResidual, 'usdc')}
		unit="USDC"
	/>
	<Figure label="Written-off debt" shown={showRead(s?.market.badDebtOf, 'usdc')} unit="USDC" />
</Panel>

<style>
	.health {
		display: grid;
		gap: 2px;
		padding-bottom: 4px;
		border-bottom: 1px solid var(--color-rule);
	}

	dt {
		color: var(--color-ink-2);
		font-size: 12.5px;
	}

	dd {
		display: flex;
		align-items: baseline;
		gap: 10px;
	}

	.big {
		font-size: 30px;
		line-height: 1;
	}

	.status {
		font-size: 12.5px;
		font-weight: 600;
	}

	[data-status='healthy'] .status,
	[data-status='healthy'] .big {
		color: var(--color-ok);
	}

	[data-status='liquidatable'] .status,
	[data-status='liquidatable'] .big {
		color: var(--color-alert);
	}
</style>
