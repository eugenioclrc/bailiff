<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { formatFlags } from '$lib/format';
	import {
		healthStatus,
		holderOf,
		showBool,
		showFlags,
		showHealth,
		showRead,
		type HealthStatus,
		type Shown
	} from '$lib/view';
	import Figure from './Figure.svelte';
	import Panel from './Panel.svelte';

	let { demo }: { demo: Demo } = $props();

	let s = $derived(demo.state);
	let borrower = $derived(holderOf(s, 'borrower'));
	let hf = $derived(showHealth(s?.market.healthFactor));
	let navStale = $derived(s?.navStatus.fresh === false);
	/** healthFactor() still answers on a stale NAV; the verdict must not contradict the disabled buttons. */
	let status: HealthStatus | 'stale' = $derived(
		navStale ? 'stale' : healthStatus(s?.market.healthFactor)
	);
	const STATUS_TEXT = {
		healthy: 'Healthy: HF at or above 1',
		liquidatable: 'Liquidatable: HF below 1',
		'no-debt': 'No debt left',
		unknown: 'Health factor unavailable',
		stale: 'NAV is stale: MiniLend would revert StaleNav'
	} as const;

	let token = $derived.by((): Shown => {
		const flags = borrower?.flags;
		if (!flags?.ok) return showFlags(flags);
		const frozen = borrower?.frozen;
		const frozenText = frozen?.ok ? (frozen.value ? 'frozen' : 'not frozen') : 'frozen unknown';
		return { text: `${formatFlags(flags.value)}; ${frozenText}`, tone: 'value' };
	});
	let isFrozen = $derived(borrower?.frozen.ok === true && borrower.frozen.value);
	let blocked = $derived(
		s?.market.liquidationBlocked.ok === true && s.market.liquidationBlocked.value
	);
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
	<Figure label="Wallet USDC" shown={showRead(borrower?.usdc, 'usdc')} unit="USDC" />
	<Figure
		label="Withdrawable by borrower"
		shown={showRead(s?.market.claimableResidual, 'usdc')}
		unit="USDC"
	/>
	<Figure label="Written-off debt" shown={showRead(s?.market.badDebtOf, 'usdc')} unit="USDC" />
	<Figure label="RWA checker flags" shown={token} state={isFrozen ? 'bad' : 'plain'} />
	<Figure
		label="Liquidation block"
		shown={showBool(s?.market.liquidationBlocked, 'blocked', 'none')}
		state={blocked ? 'bad' : 'plain'}
	/>
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
		line-height: 1.2;
	}

	[data-status='healthy'] .status,
	[data-status='healthy'] .big {
		color: var(--color-ok);
	}

	[data-status='liquidatable'] .status,
	[data-status='liquidatable'] .big {
		color: var(--color-alert);
	}

	[data-status='stale'] .status,
	[data-status='stale'] .big {
		color: var(--color-caution);
	}
</style>
