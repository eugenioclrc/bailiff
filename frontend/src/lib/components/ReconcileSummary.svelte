<script lang="ts">
	import { formatUnit } from '$lib/format';
	import type { Check, Reconciliation } from '$lib/types';

	let { reconciliation }: { reconciliation: Reconciliation } = $props();

	let liq = $derived(reconciliation.liquidation);
	let applicable = $derived(reconciliation.checks.filter((c) => c.ok !== null));
	let failing = $derived(applicable.filter((c) => c.ok === false));
	let notApplicable = $derived(reconciliation.checks.length - applicable.length);

	let routeText = $derived.by(() => {
		const residual = liq ? formatUnit(liq.residual, 'usdc') : '0.00';
		switch (reconciliation.residualRoute) {
			case 'direct-to-borrower':
				return `Residual ${residual} USDC went straight to the borrower wallet: the deployed LiquidationAdapter transfers it directly. The spec sends it to MiniLend.settleLiquidationResidual, which repays remaining debt first, then written-off debt, and books any excess as a claim withdrawable by the borrower (ResidualApplied).`;
			case 'residual-applied': {
				const a = reconciliation.residualApplied;
				return a
					? `Residual ${residual} USDC applied by MiniLend: ${formatUnit(a.debtRepaid, 'usdc')} to debt, ${formatUnit(a.badDebtRecovered, 'usdc')} to written-off debt, ${formatUnit(a.borrowerCredit, 'usdc')} withdrawable by borrower.`
					: '';
			}
			case 'none':
				return 'No residual: the proceeds covered repayment and bounty exactly.';
			default:
				return `Residual ${residual} USDC has no matching transfer or ResidualApplied event.`;
		}
	});

	function value(check: Check, v: string | null): string {
		return v === null ? 'n/a' : formatUnit(v, check.unit);
	}
</script>

<div class="recon">
	{#if liq}
		<dl class="ledger">
			<div>
				<dt>Debt</dt>
				<dd class="num">
					{formatUnit(reconciliation.debt.before, 'usdc')} → {formatUnit(
						reconciliation.debt.after,
						'usdc'
					)}
				</dd>
			</div>
			<div>
				<dt>Repaid, nominal</dt>
				<dd class="num">{formatUnit(liq.repaid, 'usdc')}</dd>
			</div>
			<div>
				<dt>Residual</dt>
				<dd class="num">{formatUnit(liq.residual, 'usdc')}</dd>
			</div>
			<div>
				<dt>Bounty to keeper</dt>
				<dd class="num">{formatUnit(liq.bounty, 'usdc')}</dd>
			</div>
			<div>
				<dt>Proceeds</dt>
				<dd class="num">{formatUnit(liq.proceeds, 'usdc')}</dd>
			</div>
			<div>
				<dt>Seized RWA</dt>
				<dd class="num">{formatUnit(liq.seized, 'rwa')}</dd>
			</div>
		</dl>
		<p class="route">{routeText}</p>
	{/if}
	<details open={failing.length > 0}>
		<summary class={{ bad: failing.length > 0 }}>
			{applicable.length - failing.length} of {applicable.length} applicable checks agree{notApplicable
				? `; ${notApplicable} not applicable`
				: ''}
		</summary>
		<ul class="checks">
			{#each reconciliation.checks as check (check.id)}
				<li class={check.ok === null ? 'na' : check.ok ? 'ok' : 'bad'}>
					<span class="mark" aria-hidden="true"
						>{check.ok === null ? 'n/a' : check.ok ? '✓' : '✗'}</span
					>
					<span class="visually-hidden"
						>{check.ok === null ? 'Not applicable' : check.ok ? 'Agrees' : 'Disagrees'}:</span
					>
					{check.label}
					{#if check.ok === false}
						<span class="num"
							>expected {value(check, check.expected)}, found {value(check, check.actual)}</span
						>
					{:else if check.ok === null && check.note}
						<span class="why">({check.note})</span>
					{/if}
				</li>
			{/each}
		</ul>
	</details>
</div>

<style>
	.recon {
		display: grid;
		gap: 4px;
	}

	.ledger {
		display: flex;
		flex-wrap: wrap;
		gap: 2px 20px;
	}

	.ledger dt {
		font-size: 11.5px;
		color: var(--color-ink-2);
	}

	.ledger dd {
		font-size: 17px;
	}

	.route {
		font-size: 12px;
	}

	summary {
		cursor: pointer;
		font-size: 12px;
		font-weight: 600;
		color: var(--color-ok);
	}

	summary.bad {
		color: var(--color-alert);
	}

	.checks {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(min(290px, 100%), 1fr));
		gap: 1px 16px;
		padding: 4px 0 2px;
		font-size: 11.5px;
	}

	/* "n/a" is wider than a check glyph: a minimum keeps the labels aligned without clipping it. */
	.mark {
		display: inline-block;
		min-width: 1em;
		margin-right: 0.2em;
		font-weight: 600;
	}

	.ok .mark {
		color: var(--color-ok);
	}

	.bad {
		color: var(--color-alert);
	}

	.na,
	.why {
		color: var(--color-ink-2);
	}

	@media (max-width: 1100px), (pointer: coarse) {
		summary {
			padding-block: 14px;
		}
	}
</style>
