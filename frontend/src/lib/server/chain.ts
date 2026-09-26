/**
 * Chain primitives: simulate (eth_call from a role), send and wait, read a batch through
 * Multicall3 with per-call failures, and recover a mined revert from the call trace.
 */
import {
	BaseError,
	ContractFunctionRevertedError,
	ExecutionRevertedError,
	RawContractError,
	decodeFunctionResult,
	encodeFunctionData,
	multicall3Abi,
	slice,
	type Abi,
	type Address,
	type Hex,
	type TransactionReceipt
} from 'viem';
import { specOnlyFunctions } from '../abis.generated';
import { decodeRevert, extractRevertData } from '../errors';
import type { DecodedRevert } from '../types';
import { MULTICALL3, type DemoContext, type Role } from './context';
import { HttpFailure, describeForLog } from './guards';

const RECEIPT_TIMEOUT_MS = 60_000;
const SPEC_ONLY_SELECTORS = new Set(specOnlyFunctions.map((entry) => entry.slice(0, 10)));

export type SimOutcome = { ok: true; data: Hex } | { ok: false; revert: DecodedRevert };

/** True when the node reported an execution revert (as opposed to a transport failure). */
export function isRevertError(err: unknown): boolean {
	if (!(err instanceof BaseError)) return false;
	return Boolean(
		err.walk(
			(e) =>
				e instanceof ExecutionRevertedError ||
				e instanceof ContractFunctionRevertedError ||
				e instanceof RawContractError ||
				(e as { code?: unknown }).code === 3
		)
	);
}

export function revertOf(ctx: DemoContext, err: unknown, target: Address): DecodedRevert | null {
	const data = extractRevertData(err);
	if (data === undefined && !isRevertError(err)) return null;
	return decodeRevert(data, ctx.logContext, target);
}

/** eth_call from `from`. Defaults to the pending block: the timestamp the next transaction will see. */
export async function simulate(
	ctx: DemoContext,
	from: Address,
	to: Address,
	data: Hex,
	at: bigint | 'pending' = 'pending'
): Promise<SimOutcome> {
	try {
		const where = at === 'pending' ? { blockTag: 'pending' as const } : { blockNumber: at };
		const result = await ctx.client.call({ account: from, to, data, ...where });
		return { ok: true, data: result.data ?? '0x' };
	} catch (err) {
		const revert = revertOf(ctx, err, to);
		if (revert) return { ok: false, revert };
		throw err;
	}
}

export async function sendAndWait(
	ctx: DemoContext,
	role: Role,
	to: Address,
	data: Hex
): Promise<{ hash: Hex; receipt: TransactionReceipt }> {
	const wallet = ctx.wallets[role];
	const hash = await wallet.sendTransaction({
		account: wallet.account,
		chain: ctx.chain,
		to,
		data
	});
	// From here on the transaction exists: a failed wait must not lose its hash.
	let receipt: TransactionReceipt;
	try {
		receipt = await ctx.client.waitForTransactionReceipt({
			hash,
			timeout: RECEIPT_TIMEOUT_MS,
			pollingInterval: 250
		});
	} catch (err) {
		console.error(`[bailiff] receipt wait for ${hash}: ${describeForLog(err)}`);
		throw new HttpFailure(
			502,
			`Sent ${hash} but no receipt arrived; check it on Anvil before retrying.`,
			{ txHash: hash }
		);
	}
	return { hash, receipt };
}

export async function rpc<T>(ctx: DemoContext, method: string, params: unknown[] = []): Promise<T> {
	const request = ctx.client.request as unknown as (args: {
		method: string;
		params: unknown[];
	}) => Promise<unknown>;
	return (await request({ method, params })) as T;
}

/** Revert reason of a mined, failed transaction, read from Anvil's call trace. */
export async function traceRevert(
	ctx: DemoContext,
	hash: Hex,
	target: Address
): Promise<DecodedRevert | null> {
	try {
		const trace = await rpc<{ output?: Hex }>(ctx, 'debug_traceTransaction', [
			hash,
			{ tracer: 'callTracer' }
		]);
		return decodeRevert(trace.output, ctx.logContext, target);
	} catch {
		return null;
	}
}

export type ReadCall = {
	key: string;
	address: Address;
	abi: Abi;
	functionName: string;
	args?: readonly unknown[];
};

export type ReadResult =
	{ ok: true; value: unknown } | { ok: false; notImplemented: boolean; revert: DecodedRevert };

/** One Multicall3.aggregate3 at a pinned block; each call may fail on its own. */
export async function readMany(
	ctx: DemoContext,
	calls: readonly ReadCall[],
	blockNumber: bigint
): Promise<Record<string, ReadResult>> {
	const encoded = calls.map((c) => ({
		target: c.address,
		allowFailure: true,
		callData: encodeFunctionData({
			abi: c.abi,
			functionName: c.functionName,
			args: c.args ?? []
		} as never)
	}));
	const results = (await ctx.client.readContract({
		address: MULTICALL3,
		abi: multicall3Abi,
		functionName: 'aggregate3',
		args: [encoded],
		blockNumber
	})) as readonly { success: boolean; returnData: Hex }[];

	return Object.fromEntries(
		calls.map((call, i) => {
			const { success, returnData } = results[i];
			const selector = slice(encoded[i].callData, 0, 4);
			const failure = (): ReadResult => ({
				ok: false,
				notImplemented: returnData === '0x' && SPEC_ONLY_SELECTORS.has(selector),
				revert: decodeRevert(returnData, ctx.logContext, call.address)
			});
			if (!success) return [call.key, failure()];
			try {
				const value = decodeFunctionResult({
					abi: call.abi,
					functionName: call.functionName,
					data: returnData
				} as never);
				return [call.key, { ok: true, value }];
			} catch {
				return [call.key, failure()];
			}
		})
	);
}
