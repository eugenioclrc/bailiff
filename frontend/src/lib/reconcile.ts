/**
 * Reconciles one liquidation receipt: the adapter's own event, the market event, the canonical
 * hook Swap, the token transfers and the state before/after must all tell the same story.
 * A single event on its own proves nothing, so every figure is cross-checked.
 */
import type { Check, DecodedLog, Reconciliation, ResidualRoute, Unit } from './types';

export type BalanceSnapshot = {
	debt: bigint;
	collateral: bigint;
	keeperUsdc: bigint;
	keeperRwa: bigint;
	borrowerUsdc: bigint;
	adapterRwa: bigint;
	adapterUsdc: bigint;
	pmRwa: bigint;
	/** null while MiniLend has no claimableResidual getter. */
	claimableResidual: bigint | null;
};

export type ReconcileContext = {
	market: string;
	adapter: string;
	rwa: string;
	usdc: string;
	pa: string;
	keeper: string;
	borrower: string;
	rwaIsCurrency0: boolean;
};

const same = (a: string | undefined, b: string) => a?.toLowerCase() === b.toLowerCase();

function arg(log: DecodedLog | undefined, name: string): bigint | null {
	const value = log?.args.find((a) => a.name === name)?.value;
	return value !== undefined && /^-?\d+$/.test(value) ? BigInt(value) : null;
}

function findEvent(logs: DecodedLog[], emitter: string, event: string): DecodedLog | undefined {
	return logs.find((l) => l.event === event && same(l.address, emitter));
}

function transferAmount(
	logs: DecodedLog[],
	token: string,
	from: string,
	to: string
): bigint | null {
	const hits = logs.filter(
		(l) =>
			l.event === 'Transfer' &&
			same(l.address, token) &&
			same(l.args.find((a) => a.name === 'from')?.value, from) &&
			same(l.args.find((a) => a.name === 'to')?.value, to)
	);
	return hits.length ? hits.reduce((sum, l) => sum + (arg(l, 'value') ?? 0n), 0n) : null;
}

function check(
	id: string,
	label: string,
	unit: Unit,
	expected: bigint | null,
	actual: bigint | null,
	note?: string
): Check {
	const ok = expected === null || actual === null ? false : expected === actual;
	return {
		id,
		label,
		unit,
		expected: expected?.toString() ?? null,
		actual: actual?.toString() ?? null,
		ok,
		...(note ? { note } : {})
	};
}

const notApplicable = (id: string, label: string, note: string): Check => ({
	id,
	label,
	unit: 'usdc',
	expected: null,
	actual: null,
	ok: null,
	note
});

function swapLegs(log: DecodedLog | undefined, rwaIsCurrency0: boolean) {
	const a0 = arg(log, 'amount0');
	const a1 = arg(log, 'amount1');
	if (a0 === null || a1 === null) return { sold: null, received: null };
	const [rwaDelta, usdcDelta] = rwaIsCurrency0 ? [a0, a1] : [a1, a0];
	return { sold: -rwaDelta, received: usdcDelta };
}

function residualChecks(
	logs: DecodedLog[],
	residual: bigint,
	before: BalanceSnapshot,
	after: BalanceSnapshot,
	ctx: ReconcileContext
): {
	route: ResidualRoute;
	applied: Reconciliation['residualApplied'];
	debtRepaid: bigint;
	checks: Check[];
} {
	const applied = findEvent(logs, ctx.market, 'ResidualApplied');
	const direct = transferAmount(logs, ctx.usdc, ctx.adapter, ctx.borrower);
	if (applied) {
		const debtRepaid = arg(applied, 'debtRepaid') ?? 0n;
		const recovered = arg(applied, 'badDebtRecovered') ?? 0n;
		const credit = arg(applied, 'borrowerCredit') ?? 0n;
		const claimDelta =
			before.claimableResidual !== null && after.claimableResidual !== null
				? after.claimableResidual - before.claimableResidual
				: null;
		return {
			route: 'residual-applied',
			applied: {
				debtRepaid: debtRepaid.toString(),
				badDebtRecovered: recovered.toString(),
				borrowerCredit: credit.toString()
			},
			debtRepaid,
			checks: [
				check(
					'residual-split',
					'ResidualApplied splits the residual',
					'usdc',
					residual,
					debtRepaid + recovered + credit
				),
				claimDelta === null
					? notApplicable(
							'claimable-delta',
							'Withdrawable by borrower grew by the credit',
							'claimableResidual is not readable'
						)
					: check(
							'claimable-delta',
							'Withdrawable by borrower grew by the credit',
							'usdc',
							credit,
							claimDelta
						),
				notApplicable(
					'residual-direct',
					'Residual sent to the borrower wallet',
					'routed through ResidualApplied'
				)
			]
		};
	}
	if (residual > 0n && direct === residual) {
		return {
			route: 'direct-to-borrower',
			applied: null,
			debtRepaid: 0n,
			checks: [
				notApplicable(
					'residual-split',
					'ResidualApplied splits the residual',
					'no ResidualApplied event in this receipt'
				),
				check(
					'residual-direct',
					'Residual sent to the borrower wallet',
					'usdc',
					residual,
					direct,
					'Snapshot contract pays the residual straight to the borrower; the spec routes it through MiniLend.settleLiquidationResidual.'
				),
				check(
					'borrower-usdc',
					'Borrower wallet USDC change',
					'usdc',
					residual,
					after.borrowerUsdc - before.borrowerUsdc
				)
			]
		};
	}
	if (residual === 0n) {
		return { route: 'none', applied: null, debtRepaid: 0n, checks: [] };
	}
	return {
		route: 'unaccounted',
		applied: null,
		debtRepaid: 0n,
		checks: [check('residual-route', 'Residual has a destination', 'usdc', residual, direct)]
	};
}

export function reconcileLiquidation(
	logs: DecodedLog[],
	before: BalanceSnapshot,
	after: BalanceSnapshot,
	ctx: ReconcileContext
): Reconciliation {
	const debt = { before: before.debt.toString(), after: after.debt.toString() };
	const adapterEvent = findEvent(logs, ctx.adapter, 'Liquidated');
	if (!adapterEvent) {
		return {
			liquidation: null,
			residualRoute: 'unaccounted',
			residualApplied: null,
			debt,
			checks: [check('adapter-event', 'Adapter Liquidated event present', 'raw', 1n, 0n)]
		};
	}
	const [repaid, seized, proceeds, bounty, residual] = [
		'repaid',
		'seized',
		'proceeds',
		'bounty',
		'residual'
	].map((name) => arg(adapterEvent, name) ?? 0n);
	const marketEvent = findEvent(logs, ctx.market, 'Liquidated');
	const badDebt = arg(marketEvent, 'badDebt') ?? 0n;
	const hookSwap = logs.find((l) => l.swap?.canonical);
	const pmSwap = logs.find(
		(l) => l.swap?.emitter === 'poolManager' && l.swap.poolIdMatches && l.swap.senderIsAdapter
	);
	const hookLegs = swapLegs(hookSwap, ctx.rwaIsCurrency0);
	const pmLegs = swapLegs(pmSwap, ctx.rwaIsCurrency0);
	const residualPart = residualChecks(logs, residual, before, after, ctx);

	const checks: Check[] = [
		check(
			'split',
			'Proceeds = repaid + bounty + residual',
			'usdc',
			proceeds,
			repaid + bounty + residual
		),
		check(
			'market-match',
			'Market event repaid matches the adapter',
			'usdc',
			repaid,
			arg(marketEvent, 'repaid')
		),
		check(
			'hook-swap-sold',
			'Canonical hook Swap sold the seized RWA',
			'rwa',
			seized,
			hookLegs.sold
		),
		check(
			'hook-swap-proceeds',
			'Canonical hook Swap paid the proceeds',
			'usdc',
			proceeds,
			hookLegs.received
		),
		check(
			'pm-swap',
			'PoolManager Swap agrees with the hook Swap',
			'usdc',
			hookLegs.received,
			pmLegs.received
		),
		check(
			'rwa-market-adapter',
			'RWA moved market → adapter',
			'rwa',
			seized,
			transferAmount(logs, ctx.rwa, ctx.market, ctx.adapter)
		),
		check(
			'rwa-adapter-pa',
			'RWA moved adapter → pool wrapper',
			'rwa',
			seized,
			transferAmount(logs, ctx.rwa, ctx.adapter, ctx.pa)
		),
		check(
			'bounty-transfer',
			'Bounty transfer to the keeper',
			'usdc',
			bounty,
			transferAmount(logs, ctx.usdc, ctx.adapter, ctx.keeper)
		),
		check(
			'keeper-usdc',
			'Keeper USDC change',
			'usdc',
			bounty,
			after.keeperUsdc - before.keeperUsdc
		),
		check('keeper-rwa', 'Keeper RWA after', 'rwa', 0n, after.keeperRwa),
		check('pm-rwa', 'PoolManager raw RWA after', 'rwa', 0n, after.pmRwa),
		// Absolute balances, one per token: the adapter must end the transaction holding nothing.
		check('adapter-rwa', 'Adapter RWA after', 'rwa', 0n, after.adapterRwa),
		check('adapter-usdc', 'Adapter USDC after', 'usdc', 0n, after.adapterUsdc),
		...residualPart.checks,
		check(
			'debt',
			'Debt drop = repaid + residual to debt + written off',
			'usdc',
			repaid + residualPart.debtRepaid + badDebt,
			before.debt - after.debt
		),
		check(
			'collateral',
			'Collateral drop = seized',
			'rwa',
			seized,
			before.collateral - after.collateral
		)
	];

	return {
		liquidation: {
			repaid: repaid.toString(),
			seized: seized.toString(),
			proceeds: proceeds.toString(),
			bounty: bounty.toString(),
			residual: residual.toString(),
			badDebt: badDebt.toString()
		},
		residualRoute: residualPart.route,
		residualApplied: residualPart.applied,
		debt,
		checks
	};
}
