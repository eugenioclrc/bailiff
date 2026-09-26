import { describe, expect, test } from 'bun:test';
import type { Abi } from 'viem';
import { miniLendAbi } from './abis.generated';
import { ADDR, LIQ, logContext, makeLog, preFixLiquidationLogs } from './fixtures.test-helpers';
import { decodeLogs } from './logs';
import { reconcileLiquidation, type BalanceSnapshot } from './reconcile';

const ctx = { ...ADDR, rwaIsCurrency0: true };

const before: BalanceSnapshot = {
	debt: 75_000_000_000n,
	collateral: 1_000n * 10n ** 18n,
	keeperUsdc: 0n,
	keeperRwa: 0n,
	borrowerUsdc: 75_000_000_000n,
	adapterRwa: 0n,
	adapterUsdc: 0n,
	pmRwa: 0n,
	claimableResidual: null
};

function after(overrides: Partial<BalanceSnapshot> = {}): BalanceSnapshot {
	return {
		...before,
		debt: 0n,
		collateral: before.collateral - LIQ.seized,
		keeperUsdc: LIQ.bounty,
		borrowerUsdc: before.borrowerUsdc + LIQ.residual,
		...overrides
	};
}

function checkMap(checks: { id: string; ok: boolean | null }[]) {
	return Object.fromEntries(checks.map((c) => [c.id, c.ok]));
}

describe('reconcileLiquidation', () => {
	test('snapshot contracts: every check passes and the residual goes straight to the borrower', () => {
		const logs = decodeLogs(preFixLiquidationLogs(), logContext);
		const result = reconcileLiquidation(logs, before, after(), ctx);
		expect(result.residualRoute).toBe('direct-to-borrower');
		expect(result.liquidation).toMatchObject({
			repaid: '75000000000',
			bounty: '4500000000',
			residual: '12041590000'
		});
		const checks = checkMap(result.checks);
		for (const id of [
			'split',
			'market-match',
			'hook-swap-sold',
			'hook-swap-proceeds',
			'pm-swap',
			'rwa-market-adapter',
			'rwa-adapter-pa',
			'bounty-transfer',
			'keeper-usdc',
			'keeper-rwa',
			'pm-rwa',
			'adapter-rwa',
			'adapter-usdc',
			'residual-direct',
			'debt',
			'collateral'
		]) {
			expect([id, checks[id]]).toEqual([id, true]);
		}
		expect(checks['residual-split']).toBeNull();
		expect(result.checks.find((c) => c.id === 'residual-direct')?.note).toBe(
			'The deployed LiquidationAdapter pays the residual straight to the borrower; the spec routes it through MiniLend.settleLiquidationResidual.'
		);
	});

	test('keeper holding RWA afterwards fails the custody check', () => {
		const logs = decodeLogs(preFixLiquidationLogs(), logContext);
		const result = reconcileLiquidation(logs, before, after({ keeperRwa: 1n }), ctx);
		expect(checkMap(result.checks)['keeper-rwa']).toBe(false);
	});

	test('adapter RWA and USDC leftovers are checked apart, so opposite signs cannot cancel', () => {
		const logs = decodeLogs(preFixLiquidationLogs(), logContext);
		const start = { ...before, adapterUsdc: 5n };
		const result = reconcileLiquidation(
			logs,
			start,
			after({ adapterRwa: 5n, adapterUsdc: 0n }),
			ctx
		);
		const checks = checkMap(result.checks);
		expect(checks['adapter-rwa']).toBe(false);
		expect(checks['adapter-usdc']).toBe(true);
		expect(checks['adapter-flat']).toBeUndefined();
	});

	test('a balance the adapter already held is still flagged', () => {
		const logs = decodeLogs(preFixLiquidationLogs(), logContext);
		const start = { ...before, adapterUsdc: 7n };
		const result = reconcileLiquidation(logs, start, after({ adapterUsdc: 7n }), ctx);
		expect(checkMap(result.checks)['adapter-usdc']).toBe(false);
		const usdc = result.checks.find((c) => c.id === 'adapter-usdc');
		expect(usdc).toMatchObject({ unit: 'usdc', expected: '0', actual: '7' });
	});

	test('a debt drop that does not match the events fails', () => {
		const logs = decodeLogs(preFixLiquidationLogs(), logContext);
		const result = reconcileLiquidation(logs, before, after({ debt: 1n }), ctx);
		expect(checkMap(result.checks)['debt']).toBe(false);
	});

	test('fixed contracts: ResidualApplied splits the residual and repays debt', () => {
		const chunk = {
			repaid: 10_000_000_000n,
			seized: 124_705_882_352_941_176_470n,
			proceeds: 11_844_140_000n,
			bounty: 600_000_000n,
			residual: 1_244_140_000n
		};
		const raw = preFixLiquidationLogs(chunk).filter((l) => l.logIndex !== 9);
		raw.push(
			makeLog(
				ADDR.market,
				miniLendAbi as Abi,
				'ResidualApplied',
				{
					borrower: ADDR.borrower,
					debtRepaid: chunk.residual,
					badDebtRecovered: 0n,
					borrowerCredit: 0n
				},
				9
			)
		);
		const logs = decodeLogs(raw, logContext);
		const start = { ...before, claimableResidual: 0n };
		const end: BalanceSnapshot = {
			...start,
			debt: before.debt - chunk.repaid - chunk.residual,
			collateral: before.collateral - chunk.seized,
			keeperUsdc: chunk.bounty
		};
		const result = reconcileLiquidation(logs, start, end, ctx);
		expect(result.residualRoute).toBe('residual-applied');
		expect(result.residualApplied).toEqual({
			debtRepaid: '1244140000',
			badDebtRecovered: '0',
			borrowerCredit: '0'
		});
		const checks = checkMap(result.checks);
		expect(checks['residual-split']).toBe(true);
		expect(checks['claimable-delta']).toBe(true);
		expect(checks['debt']).toBe(true);
		expect(checks['residual-direct']).toBeNull();
	});

	test('a residual with no route is flagged', () => {
		const raw = preFixLiquidationLogs().filter((l) => l.logIndex !== 9);
		const logs = decodeLogs(raw, logContext);
		const result = reconcileLiquidation(
			logs,
			before,
			after({ borrowerUsdc: before.borrowerUsdc }),
			ctx
		);
		expect(result.residualRoute).toBe('unaccounted');
		expect(checkMap(result.checks)['residual-route']).toBe(false);
	});

	test('without the adapter event nothing is claimed', () => {
		const logs = decodeLogs(
			preFixLiquidationLogs().filter((l) => l.logIndex !== 10),
			logContext
		);
		const result = reconcileLiquidation(logs, before, after(), ctx);
		expect(result.liquidation).toBeNull();
		expect(checkMap(result.checks)['adapter-event']).toBe(false);
	});
});
