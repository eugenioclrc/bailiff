/**
 * The seven O5 actions. Every argument comes from the manifest or this file, never from the
 * browser. Each signed action is simulated from its signer before it is sent; a simulation revert
 * is returned as "simulation-reverted" and nothing is sent.
 */
import {
	decodeFunctionResult,
	encodeFunctionData,
	maxUint256,
	type Address,
	type Hex,
	type TransactionReceipt
} from 'viem';
import { adapterAbi, deskAbi, miniLendAbi, paAbi } from '../abis.generated';
import { formatUnit } from '../format';
import { decodeLogs } from '../logs';
import { reconcileLiquidation } from '../reconcile';
import type {
	ActionDetail,
	ActionName,
	ActionResponse,
	DecodedLog,
	DecodedRevert,
	SimulationRecord
} from '../types';
import { revertOf, sendAndWait, simulate, traceRevert, type SimOutcome } from './chain';
import type { DemoContext, Role } from './context';
import { HttpFailure, describeForLog } from './guards';
import { resetToBaseline } from './reset';
import { CHUNK_REPAY, readBalanceSnapshot } from './state';

const NAV_AFTER_CRASH = 85n * 10n ** 18n;
/** 95% of the 5e17 initial liquidity, as O5 fixes it. */
const LIQUIDITY_TO_WITHDRAW = 475_000_000_000_000_000n;
const MIN_BOUNTY_PERCENT = 97n;

type TxSpec = { action: ActionName; role: Role; to: Address; data: Hex; call: string };
type Extra = (receipt: TransactionReceipt, logs: DecodedLog[]) => Promise<Partial<ActionDetail>>;

function record(
	label: string,
	from: Address,
	call: string,
	outcome: SimOutcome,
	result?: string
): SimulationRecord {
	return outcome.ok
		? { label, from, call, ok: true, ...(result ? { result } : {}) }
		: { label, from, call, ok: false, error: outcome.revert };
}

function simulationReverted(detail: ActionDetail, revert: DecodedRevert): ActionResponse {
	return {
		status: 'simulation-reverted',
		error: { name: revert.name, message: revert.message },
		detail: { ...detail, revert }
	};
}

async function mine(
	ctx: DemoContext,
	detail: ActionDetail,
	spec: TxSpec,
	extra?: Extra
): Promise<ActionResponse> {
	let sent: Awaited<ReturnType<typeof sendAndWait>>;
	try {
		sent = await sendAndWait(ctx, spec.role, spec.to, spec.data);
	} catch (err) {
		const revert = revertOf(ctx, err, spec.to);
		if (!revert) throw err;
		const from = ctx.wallets[spec.role].account.address;
		const estimate: SimulationRecord = {
			label: 'Gas estimation before sending',
			from,
			call: spec.call,
			ok: false,
			error: revert
		};
		return simulationReverted(
			{ ...detail, simulations: [...detail.simulations, estimate] },
			revert
		);
	}
	const { hash, receipt } = sent;
	const logs = decodeLogs(receipt.logs, ctx.logContext);
	const receiptDetail = {
		blockNumber: receipt.blockNumber.toString(),
		gasUsed: receipt.gasUsed.toString(),
		status: receipt.status,
		logs
	};
	if (receipt.status === 'reverted') {
		const traced = await traceRevert(ctx, hash, spec.to);
		const message = traced
			? `Mined with status 0. Cause from the call trace: ${traced.message}`
			: 'Mined with status 0. The trace had no revert data; the cause is not inferred from the receipt.';
		return {
			status: 'mined',
			txHash: hash,
			error: { name: traced?.name ?? 'TransactionReverted', message },
			detail: { ...detail, receipt: receiptDetail, ...(traced ? { revert: traced } : {}) }
		};
	}
	// The transaction is mined: a failed read afterwards must not hide its hash behind an HTTP 500.
	let more: Partial<ActionDetail> = {};
	try {
		if (extra) more = await extra(receipt, logs);
	} catch (err) {
		console.error(`[bailiff] reconciliation after ${hash}: ${describeForLog(err)}`);
		more = {
			reconciliationError: `Balances could not be read around block ${receipt.blockNumber}; reconciliation skipped. The transaction itself mined.`
		};
	}
	return { status: 'mined', txHash: hash, detail: { ...detail, receipt: receiptDetail, ...more } };
}

async function sendSigned(ctx: DemoContext, spec: TxSpec): Promise<ActionResponse> {
	const from = ctx.wallets[spec.role].account.address;
	const outcome = await simulate(ctx, from, spec.to, spec.data);
	const detail: ActionDetail = {
		action: spec.action,
		signer: { role: spec.role, address: from },
		call: spec.call,
		simulations: [record('Simulation before sending', from, spec.call, outcome)]
	};
	return outcome.ok ? mine(ctx, detail, spec) : simulationReverted(detail, outcome.revert);
}

/** O5 horizon: the direct KYC-gated route, simulated from the keeper. Never sent. */
async function simulateDirectRoute(ctx: DemoContext): Promise<ActionResponse> {
	const { market, borrower, keeper } = ctx.manifest;
	const call = 'market.liquidate(borrower, maxUint256, 0x) from the keeper';
	const data = encodeFunctionData({
		abi: miniLendAbi,
		functionName: 'liquidate',
		args: [borrower, maxUint256, '0x']
	});
	const outcome = await simulate(ctx, keeper, market, data);
	if (outcome.ok) {
		throw new HttpFailure(
			409,
			'The direct route simulation did not revert; nothing was sent. Check keeper flags and balances.'
		);
	}
	const detail: ActionDetail = {
		action: 'horizon',
		signer: null,
		call,
		simulations: [record('Direct route simulation (not sent)', keeper, call, outcome)]
	};
	return simulationReverted(detail, outcome.revert);
}

/** The quoted bounty. A successful call without return data means the adapter is not deployed here. */
function decodeBounty(data: Hex): bigint {
	try {
		return decodeFunctionResult({ abi: adapterAbi, functionName: 'liquidate', data });
	} catch {
		throw new HttpFailure(
			502,
			'adapter.liquidate returned no bounty data; the manifest contracts may be missing. Rerun the local deploy and seed (O4).'
		);
	}
}

/** O5 liquidateFull / liquidateChunk: quote, set minBounty to 97%, re-simulate, send, reconcile. */
async function liquidateViaAdapter(
	ctx: DemoContext,
	action: ActionName,
	repayAssets: bigint
): Promise<ActionResponse> {
	const { adapter, borrower, market, rwa, usdc, pa, rwaIsCurrency0 } = ctx.manifest;
	const keeper = ctx.wallets.keeper.account.address;
	const repayText =
		repayAssets === maxUint256 ? 'maxUint256' : `${formatUnit(repayAssets, 'usdc')} USDC`;
	const encode = (minBounty: bigint) =>
		encodeFunctionData({
			abi: adapterAbi,
			functionName: 'liquidate',
			args: [borrower, repayAssets, minBounty]
		});
	const callText = (minBounty: bigint) =>
		`adapter.liquidate(borrower, ${repayText}, minBounty ${formatUnit(minBounty, 'usdc')} USDC)`;

	const quoted = await simulate(ctx, keeper, adapter, encode(0n));
	const signer = { role: 'keeper' as const, address: keeper };
	if (!quoted.ok) {
		const quoteFailure = record('Quote (minBounty 0)', keeper, callText(0n), quoted);
		return simulationReverted(
			{ action, signer, call: callText(0n), simulations: [quoteFailure] },
			quoted.revert
		);
	}

	const bounty = decodeBounty(quoted.data);
	const minBounty = (bounty * MIN_BOUNTY_PERCENT) / 100n;
	const quoteRecord = record(
		'Quote (minBounty 0)',
		keeper,
		callText(0n),
		quoted,
		`bounty ${formatUnit(bounty, 'usdc')} USDC`
	);
	const data = encode(minBounty);
	const checked = await simulate(ctx, keeper, adapter, data);
	const detail: ActionDetail = {
		action,
		signer,
		call: callText(minBounty),
		quote: {
			repayAssets: repayAssets.toString(),
			bounty: bounty.toString(),
			minBounty: minBounty.toString()
		},
		simulations: [
			quoteRecord,
			record('Re-simulation with the send arguments', keeper, callText(minBounty), checked)
		]
	};
	if (!checked.ok) return simulationReverted(detail, checked.revert);

	const reconcile: Extra = async (receipt, logs) => {
		const [before, after] = await Promise.all([
			readBalanceSnapshot(ctx, receipt.blockNumber - 1n),
			readBalanceSnapshot(ctx, receipt.blockNumber)
		]);
		const reconcileCtx = { market, adapter, rwa, usdc, pa, keeper, borrower, rwaIsCurrency0 };
		return { reconciliation: reconcileLiquidation(logs, before, after, reconcileCtx) };
	};
	return mine(
		ctx,
		detail,
		{ action, role: 'keeper', to: adapter, data, call: callText(minBounty) },
		reconcile
	);
}

export async function runAction(ctx: DemoContext, action: ActionName): Promise<ActionResponse> {
	const m = ctx.manifest;
	switch (action) {
		case 'crash':
			return sendSigned(ctx, {
				action,
				role: 'issuer',
				to: m.market,
				data: encodeFunctionData({
					abi: miniLendAbi,
					functionName: 'setNav',
					args: [NAV_AFTER_CRASH]
				}),
				call: 'market.setNav(85e18)'
			});
		case 'revoke':
			return sendSigned(ctx, {
				action,
				role: 'issuer',
				to: m.pa,
				data: encodeFunctionData({
					abi: paAbi,
					functionName: 'updateAllowedWrapper',
					args: [m.adapter, false]
				}),
				call: 'permissionsAdapter.updateAllowedWrapper(adapter, false)'
			});
		case 'withdraw95':
			return sendSigned(ctx, {
				action,
				role: 'mm',
				to: m.desk,
				data: encodeFunctionData({
					abi: deskAbi,
					functionName: 'modifyLiquidity',
					args: [m.poolKey, m.tickLower, m.tickUpper, -LIQUIDITY_TO_WITHDRAW]
				}),
				call: `desk.modifyLiquidity(poolKey, ${m.tickLower}, ${m.tickUpper}, -4.75e17)`
			});
		case 'horizon':
			return simulateDirectRoute(ctx);
		case 'liquidateFull':
			return liquidateViaAdapter(ctx, action, maxUint256);
		case 'liquidateChunk':
			return liquidateViaAdapter(ctx, action, CHUNK_REPAY);
		case 'reset':
			return resetToBaseline(ctx);
	}
}
