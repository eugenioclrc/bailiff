/**
 * The full dashboard state at one pinned block: one Multicall3 batch plus the two keeper quotes.
 * Getters the snapshot contracts lack come back as "not implemented yet", never as zero.
 */
import { decodeFunctionResult, encodeFunctionData, maxUint256, type Abi, type Address } from 'viem';
import { adapterAbi, miniLendAbi, paAbi, rwaAbi, stateViewAbi, usdcAbi } from '../abis.generated';
import { spotPriceWad, virtualReserves } from '../format';
import { liquidationGate, navStatus } from '../nav';
import type { BalanceSnapshot } from '../reconcile';
import { PROBE_CALL } from '../timeline';
import type { ChainState, Holder, HolderKey, ProbeRecord, Quote, ReadValue } from '../types';
import { readMany, simulate, type ReadCall, type ReadResult } from './chain';
import type { DemoContext } from './context';
import { currentBranch } from './reset';

export const CHUNK_REPAY = 10_000n * 10n ** 6n;

const HOLDERS: { key: HolderKey; label: string }[] = [
	{ key: 'issuer', label: 'Issuer' },
	{ key: 'mm', label: 'Market maker' },
	{ key: 'keeper', label: 'Keeper' },
	{ key: 'borrower', label: 'Borrower' },
	{ key: 'lender', label: 'Lender' },
	{ key: 'market', label: 'MiniLend market' },
	{ key: 'adapter', label: 'Liquidation adapter' },
	{ key: 'pa', label: 'Pool wrapper (PA)' },
	{ key: 'poolManager', label: 'PoolManager' },
	{ key: 'desk', label: 'Liquidity desk' }
];

const MARKET_GETTERS = [
	'nav',
	'navUpdatedAt',
	'MAX_STALENESS',
	'totalDebt',
	'totalSupplyAssets',
	'totalBadDebt',
	'totalResidualClaims'
] as const;
const BORROWER_GETTERS = [
	'positions',
	'healthFactor',
	'badDebtOf',
	'claimableResidual',
	'liquidationBlocked'
] as const;

function stateCalls(ctx: DemoContext): ReadCall[] {
	const m = ctx.manifest;
	const market = (fn: string, args?: readonly unknown[]): ReadCall => ({
		key: `market.${fn}`,
		address: m.market,
		abi: miniLendAbi as Abi,
		functionName: fn,
		args
	});
	const holderCalls = HOLDERS.flatMap(({ key }) => [
		{
			key: `rwa.balance.${key}`,
			address: m.rwa,
			abi: rwaAbi as Abi,
			functionName: 'balanceOf',
			args: [m[key]]
		},
		{
			key: `usdc.balance.${key}`,
			address: m.usdc,
			abi: usdcAbi as Abi,
			functionName: 'balanceOf',
			args: [m[key]]
		},
		{
			key: `rwa.flags.${key}`,
			address: m.rwa,
			abi: rwaAbi as Abi,
			functionName: 'flags',
			args: [m[key]]
		},
		{
			key: `rwa.frozen.${key}`,
			address: m.rwa,
			abi: rwaAbi as Abi,
			functionName: 'frozen',
			args: [m[key]]
		}
	]);
	const pa = (key: string, fn: string, args?: readonly unknown[]): ReadCall => ({
		key,
		address: m.pa,
		abi: paAbi as Abi,
		functionName: fn,
		args
	});
	return [
		...MARKET_GETTERS.map((fn) => market(fn)),
		...BORROWER_GETTERS.map((fn) => market(fn, [m.borrower])),
		...holderCalls,
		{ key: 'rwa.paused', address: m.rwa, abi: rwaAbi as Abi, functionName: 'paused' },
		pa('pa.swappingEnabled', 'swappingEnabled'),
		pa('pa.adapterWrapper', 'allowedWrappers', [m.adapter]),
		pa('pa.deskWrapper', 'allowedWrappers', [m.desk]),
		pa('pa.hookAllowed', 'allowedHooks', [m.hook]),
		{
			key: 'adapter.NAV_FLOOR_BPS',
			address: m.adapter,
			abi: adapterAbi as Abi,
			functionName: 'NAV_FLOOR_BPS'
		},
		{
			key: 'pool.slot0',
			address: m.stateView,
			abi: stateViewAbi as Abi,
			functionName: 'getSlot0',
			args: [m.poolId]
		},
		{
			key: 'pool.liquidity',
			address: m.stateView,
			abi: stateViewAbi as Abi,
			functionName: 'getLiquidity',
			args: [m.poolId]
		}
	];
}

function toRead<T>(result: ReadResult | undefined, map: (value: unknown) => T): ReadValue<T> {
	if (!result) return { ok: false, reason: 'reverted', message: 'not read' };
	if (result.ok) return { ok: true, value: map(result.value) };
	if (result.notImplemented)
		return { ok: false, reason: 'not-implemented', message: 'not implemented yet' };
	return { ok: false, reason: 'reverted', message: result.revert.message };
}

const big = (v: unknown) => (v as bigint).toString();
const num = (v: unknown) => Number(v);
const bool = (v: unknown) => Boolean(v);
const tupleAt = (i: number) => (v: unknown) => (v as readonly unknown[])[i];
const valueOf = (r: ReadResult | undefined): unknown => (r?.ok ? r.value : undefined);

/** Keeper quote on the pending block, so a stale NAV shows up exactly as the next send would see it. */
async function quote(ctx: DemoContext, repayAssets: bigint): Promise<Quote> {
	const m = ctx.manifest;
	const data = encodeFunctionData({
		abi: adapterAbi,
		functionName: 'liquidate',
		args: [m.borrower, repayAssets, 0n]
	});
	const outcome = await simulate(ctx, m.keeper, m.adapter, data, 'pending');
	const repay = repayAssets.toString();
	if (!outcome.ok) {
		return {
			repayAssets: repay,
			ok: false,
			error: { name: outcome.revert.name, message: outcome.revert.message },
			revert: outcome.revert
		};
	}
	try {
		const bounty = decodeFunctionResult({
			abi: adapterAbi,
			functionName: 'liquidate',
			data: outcome.data
		});
		return { repayAssets: repay, ok: true, bounty: bounty.toString() };
	} catch {
		return {
			repayAssets: repay,
			ok: false,
			error: { name: 'NoReturnData', message: 'adapter.liquidate returned no bounty data' }
		};
	}
}

/** O7 control pair: the same full-close quote the dashboard shows, with its block and branch. */
export async function readProbe(ctx: DemoContext): Promise<ProbeRecord> {
	const [block, branch, full] = await Promise.all([
		ctx.client.getBlock(),
		currentBranch(ctx),
		quote(ctx, maxUint256)
	]);
	return {
		branch,
		block: block.number.toString(),
		from: ctx.manifest.keeper,
		call: PROBE_CALL,
		quote: full
	};
}

function poolState(
	ctx: DemoContext,
	r: Record<string, ReadResult>,
	floor: string | null
): ChainState['pool'] {
	const slot0 = r['pool.slot0'];
	const sqrtPrice = valueOf(slot0)
		? ((valueOf(slot0) as readonly unknown[])[0] as bigint)
		: undefined;
	const liquidity = valueOf(r['pool.liquidity']) as bigint | undefined;
	const spot =
		sqrtPrice === undefined ? null : spotPriceWad(sqrtPrice, ctx.manifest.rwaIsCurrency0);
	const reserves =
		sqrtPrice === undefined || liquidity === undefined
			? null
			: virtualReserves(liquidity, sqrtPrice, ctx.manifest.rwaIsCurrency0);
	return {
		sqrtPriceX96: toRead(slot0, (v) => big(tupleAt(0)(v))),
		tick: toRead(slot0, (v) => num(tupleAt(1)(v))),
		lpFee: toRead(slot0, (v) => num(tupleAt(3)(v))),
		liquidity: toRead(r['pool.liquidity'], big),
		spot: spot?.toString() ?? null,
		virtualRwa: reserves?.rwa.toString() ?? null,
		virtualUsdc: reserves?.usdc.toString() ?? null,
		spotAboveFloor: spot === null || floor === null ? null : spot > BigInt(floor)
	};
}

export async function readState(ctx: DemoContext): Promise<ChainState> {
	const m = ctx.manifest;
	const block = await ctx.client.getBlock();
	// Anvil's pending block carries the timestamp the next transaction will be mined with.
	const pending = await ctx.client.getBlock({ blockTag: 'pending' }).catch(() => block);
	const [r, full, chunk, branch] = await Promise.all([
		readMany(ctx, stateCalls(ctx), block.number),
		quote(ctx, maxUint256),
		quote(ctx, CHUNK_REPAY),
		currentBranch(ctx)
	]);
	const maxStaleness = valueOf(r['market.MAX_STALENESS']) as bigint | undefined;
	const status = navStatus(
		{
			nav: valueOf(r['market.nav']) as bigint | undefined,
			updatedAt: valueOf(r['market.navUpdatedAt']) as bigint | undefined,
			maxStaleness
		},
		pending.timestamp,
		m.navFloorBps
	);
	const holders: Holder[] = HOLDERS.map(({ key, label }) => ({
		key,
		label,
		address: m[key],
		rwa: toRead(r[`rwa.balance.${key}`], big),
		usdc: toRead(r[`usdc.balance.${key}`], big),
		flags: toRead(r[`rwa.flags.${key}`], num),
		frozen: toRead(r[`rwa.frozen.${key}`], bool)
	}));
	const addressFields = [
		'market',
		'adapter',
		'desk',
		'rwa',
		'usdc',
		'pa',
		'hook',
		'poolManager',
		'stateView',
		'factory',
		'issuer',
		'mm',
		'keeper',
		'borrower',
		'lender'
	] as const;

	return {
		env: {
			label: `Anvil fork from block ${m.forkBlock}`,
			network: m.network,
			chainId: m.chainId,
			forkBlock: m.forkBlock,
			sourceCommit: m.sourceCommit
		},
		block: { number: block.number.toString(), timestamp: block.timestamp.toString() },
		branch,
		addresses: Object.fromEntries(addressFields.map((f) => [f, m[f] as Address])),
		poolId: m.poolId,
		rwaIsCurrency0: m.rwaIsCurrency0,
		navFloorBps: m.navFloorBps,
		market: {
			nav: toRead(r['market.nav'], big),
			navUpdatedAt: toRead(r['market.navUpdatedAt'], big),
			maxStaleness: toRead(r['market.MAX_STALENESS'], big),
			healthFactor: toRead(r['market.healthFactor'], big),
			collateral: toRead(r['market.positions'], (v) => big(tupleAt(0)(v))),
			debt: toRead(r['market.positions'], (v) => big(tupleAt(1)(v))),
			totalDebt: toRead(r['market.totalDebt'], big),
			totalSupplyAssets: toRead(r['market.totalSupplyAssets'], big),
			totalBadDebt: toRead(r['market.totalBadDebt'], big),
			badDebtOf: toRead(r['market.badDebtOf'], big),
			claimableResidual: toRead(r['market.claimableResidual'], big),
			totalResidualClaims: toRead(r['market.totalResidualClaims'], big),
			liquidationBlocked: toRead(r['market.liquidationBlocked'], bool)
		},
		navStatus: status,
		adapterNavFloorBps: toRead(r['adapter.NAV_FLOOR_BPS'], num),
		pool: poolState(ctx, r, status.floor),
		holders,
		rwaPaused: toRead(r['rwa.paused'], bool),
		permissions: {
			swappingEnabled: toRead(r['pa.swappingEnabled'], bool),
			adapterWrapper: toRead(r['pa.adapterWrapper'], bool),
			deskWrapper: toRead(r['pa.deskWrapper'], bool),
			hookAllowed: toRead(r['pa.hookAllowed'], bool)
		},
		quotes: { full, chunk },
		liquidation: liquidationGate(status, maxStaleness)
	};
}

/** Balances needed to reconcile one liquidation, at a given block. */
export async function readBalanceSnapshot(
	ctx: DemoContext,
	blockNumber: bigint
): Promise<BalanceSnapshot> {
	const m = ctx.manifest;
	const calls: ReadCall[] = [
		{
			key: 'pos',
			address: m.market,
			abi: miniLendAbi as Abi,
			functionName: 'positions',
			args: [m.borrower]
		},
		{
			key: 'claim',
			address: m.market,
			abi: miniLendAbi as Abi,
			functionName: 'claimableResidual',
			args: [m.borrower]
		},
		{
			key: 'keeperUsdc',
			address: m.usdc,
			abi: usdcAbi as Abi,
			functionName: 'balanceOf',
			args: [m.keeper]
		},
		{
			key: 'keeperRwa',
			address: m.rwa,
			abi: rwaAbi as Abi,
			functionName: 'balanceOf',
			args: [m.keeper]
		},
		{
			key: 'borrowerUsdc',
			address: m.usdc,
			abi: usdcAbi as Abi,
			functionName: 'balanceOf',
			args: [m.borrower]
		},
		{
			key: 'adapterRwa',
			address: m.rwa,
			abi: rwaAbi as Abi,
			functionName: 'balanceOf',
			args: [m.adapter]
		},
		{
			key: 'adapterUsdc',
			address: m.usdc,
			abi: usdcAbi as Abi,
			functionName: 'balanceOf',
			args: [m.adapter]
		},
		{
			key: 'pmRwa',
			address: m.rwa,
			abi: rwaAbi as Abi,
			functionName: 'balanceOf',
			args: [m.poolManager]
		}
	];
	const r = await readMany(ctx, calls, blockNumber);
	const need = (key: string): bigint => {
		const result = r[key];
		if (!result?.ok) throw new Error(`reconciliation read ${key} failed at block ${blockNumber}`);
		return result.value as bigint;
	};
	const position = valueOf(r.pos) as readonly bigint[] | undefined;
	if (!position) throw new Error(`reconciliation read positions failed at block ${blockNumber}`);
	const claim = valueOf(r.claim);
	return {
		collateral: position[0],
		debt: position[1],
		keeperUsdc: need('keeperUsdc'),
		keeperRwa: need('keeperRwa'),
		borrowerUsdc: need('borrowerUsdc'),
		adapterRwa: need('adapterRwa'),
		adapterUsdc: need('adapterUsdc'),
		pmRwa: need('pmRwa'),
		claimableResidual: typeof claim === 'bigint' ? claim : null
	};
}
