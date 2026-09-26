/**
 * Revert decoding. Unwraps Uniswap v4 `WrappedError(target, selector, reason, details)` recursively
 * and names the innermost known cause. Unknown errors keep their target and selector; nothing is
 * inferred that the revert data does not say.
 */
import { decodeErrorResult, getAddress, isHex, size, slice, type Hex } from 'viem';
import { errorSources, errorsAbi, functionNames } from './abis.generated';
import type { DecodedArg, DecodedRevert, ErrorLayer } from './types';

export type DecodeContext = {
	/** lowercase address -> manifest role ("hook", "adapter", "keeper", ...) */
	labels: Readonly<Record<string, string>>;
};

const MAX_DEPTH = 8;

const PANIC_REASONS: Record<string, string> = {
	'1': 'assertion failed',
	'17': 'arithmetic overflow/underflow',
	'18': 'division or modulo by zero',
	'33': 'invalid enum value',
	'34': 'invalid storage byte array',
	'49': 'pop on empty array',
	'50': 'array index out of bounds',
	'65': 'out of memory',
	'81': 'call to a zero-initialized function'
};

type Target = ErrorLayer['target'];

function toTarget(address: string | undefined, ctx: DecodeContext): Target {
	if (!address) return null;
	const checksummed = getAddress(address);
	return { address: checksummed, label: ctx.labels[checksummed.toLowerCase()] ?? null };
}

function stringify(value: unknown): string {
	if (typeof value === 'bigint' || typeof value === 'number' || typeof value === 'boolean') {
		return value.toString();
	}
	if (typeof value === 'string') return value;
	return JSON.stringify(value, (_k, v: unknown) => (typeof v === 'bigint' ? v.toString() : v));
}

export function decodeArgs(
	inputs: readonly { name?: string; type: string }[],
	values: readonly unknown[],
	ctx: DecodeContext
): DecodedArg[] {
	return inputs.map((input, i) => {
		const raw = values[i];
		if (input.type === 'address' && typeof raw === 'string') {
			const address = getAddress(raw);
			const label = ctx.labels[address.toLowerCase()];
			return { name: input.name || `arg${i}`, type: input.type, value: address, ...(label ? { label } : {}) };
		}
		return { name: input.name || `arg${i}`, type: input.type, value: stringify(raw) };
	});
}

function signatureOf(name: string, inputs: readonly { type: string }[]): string {
	return `${name}(${inputs.map((i) => i.type).join(',')})`;
}

function describeContext(details: Hex): string {
	if (size(details) < 4) return details;
	const selector = slice(details, 0, 4);
	try {
		const decoded = decodeErrorResult({ abi: errorsAbi, data: details });
		return signatureOf(decoded.errorName, decoded.abiItem.inputs);
	} catch {
		return selector;
	}
}

function emptyLayer(target: Target): ErrorLayer {
	return { kind: 'empty', selector: null, name: null, signature: null, args: [], target, declaredBy: [] };
}

function unknownLayer(data: Hex, target: Target): ErrorLayer {
	const selector = size(data) >= 4 ? slice(data, 0, 4) : data;
	return {
		kind: 'unknown',
		selector,
		name: null,
		signature: null,
		args: [],
		target,
		declaredBy: errorSources[selector] ? [...errorSources[selector]] : [],
		raw: data
	};
}

function decodeLayers(data: Hex | undefined, target: Target, ctx: DecodeContext, depth: number): ErrorLayer[] {
	if (!data || data === '0x') return [emptyLayer(target)];
	if (size(data) < 4) return [unknownLayer(data, target)];
	let decoded;
	try {
		decoded = decodeErrorResult({ abi: errorsAbi, data });
	} catch {
		return [unknownLayer(data, target)];
	}
	const selector = slice(data, 0, 4);
	const inputs = decoded.abiItem.inputs;
	const values = (decoded.args ?? []) as readonly unknown[];
	const base: ErrorLayer = {
		kind: 'known',
		selector,
		name: decoded.errorName,
		signature: signatureOf(decoded.errorName, inputs),
		args: decodeArgs(inputs, values, ctx),
		target,
		declaredBy: errorSources[selector] ? [...errorSources[selector]] : []
	};
	if (decoded.errorName !== 'WrappedError' || depth >= MAX_DEPTH) return [base];

	const [inner, callSelector, reason, details] = values as [string, Hex, Hex, Hex];
	const wrapper: ErrorLayer = {
		...base,
		kind: 'wrapped',
		call: functionNames[callSelector] ?? callSelector,
		context: describeContext(details)
	};
	return [wrapper, ...decodeLayers(reason, toTarget(inner, ctx), ctx, depth + 1)];
}

function argText(arg: DecodedArg): string {
	return arg.label ? `${arg.name}=${arg.label} ${arg.value}` : `${arg.name}=${arg.value}`;
}

function targetText(target: Target): string {
	if (!target) return 'the called contract';
	return target.label ? `${target.label} (${target.address})` : target.address;
}

function shortCall(call: string | undefined): string {
	if (!call) return 'a call';
	const withoutContract = call.includes('.') ? call.slice(call.indexOf('.') + 1) : call;
	return withoutContract.includes('(') ? withoutContract.slice(0, withoutContract.indexOf('(')) : withoutContract;
}

function leafText(layer: ErrorLayer): string {
	if (layer.kind === 'empty') return 'reverted without error data';
	if (layer.kind === 'unknown') return `unknown error ${layer.selector} (raw data kept)`;
	if (layer.name === 'Panic') {
		const code = layer.args[0]?.value ?? '';
		return `Panic(${code}): ${PANIC_REASONS[code] ?? 'unknown panic code'}`;
	}
	if (layer.name === 'Error') return `Error("${layer.args[0]?.value ?? ''}")`;
	return `${layer.name}(${layer.args.map(argText).join(', ')})`;
}

function leafName(layer: ErrorLayer): string {
	if (layer.kind === 'empty') return 'EmptyRevert';
	if (layer.kind === 'unknown' || !layer.name) return 'UnknownError';
	return layer.name;
}

export function decodeRevert(data: Hex | undefined, ctx: DecodeContext, target?: string): DecodedRevert {
	const layers = decodeLayers(data, toTarget(target, ctx), ctx, 0);
	const cause = layers[layers.length - 1];
	const wrappers = layers.filter((l) => l.kind === 'wrapped');
	const source = cause.target ? ` from ${targetText(cause.target)}` : '';
	const path = wrappers.length
		? `; raised in ${wrappers.map((w) => shortCall(w.call)).join(' → ')} and wrapped as ${wrappers
				.map((w) => w.context ?? 'WrappedError')
				.join(' → ')}`
		: '';
	return { name: leafName(cause), message: `${leafText(cause)}${source}${path}`, layers };
}

/** Finds the revert payload on a viem error or any nested `cause`, without assuming its class. */
export function extractRevertData(err: unknown): Hex | undefined {
	let current: unknown = err;
	for (let depth = 0; current && depth < 16; depth += 1) {
		if (typeof current !== 'object') return undefined;
		const node = current as { data?: unknown; raw?: unknown; cause?: unknown };
		for (const candidate of [node.raw, node.data]) {
			if (typeof candidate === 'string' && isHex(candidate)) return candidate;
			if (candidate && typeof candidate === 'object') {
				const nested = (candidate as { data?: unknown }).data;
				if (typeof nested === 'string' && isHex(nested)) return nested;
			}
		}
		current = node.cause;
	}
	return undefined;
}
