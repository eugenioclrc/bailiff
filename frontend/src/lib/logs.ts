/**
 * Receipt log decoding. Each log is decoded with the ABI of the contract that emitted it, so the
 * hook's Swap and the PoolManager's Swap (same signature) stay attributed to the right emitter.
 */
import { decodeEventLog, getAddress, toEventSelector, type Abi, type AbiEvent, type Hex } from 'viem';
import {
	adapterAbi,
	deskAbi,
	eventSignatures,
	factoryAbi,
	hookAbi,
	miniLendAbi,
	paAbi,
	poolManagerAbi,
	rwaAbi,
	usdcAbi
} from './abis.generated';
import { decodeArgs, type DecodeContext } from './errors';
import type { DecodedLog, SwapAttribution } from './types';

export type ContractKey = 'market' | 'adapter' | 'rwa' | 'usdc' | 'pa' | 'hook' | 'poolManager' | 'desk' | 'factory';

export type LogContext = DecodeContext & {
	contracts: Readonly<Record<ContractKey, string>>;
	poolId: string;
};

export type RawLog = {
	address: string;
	topics: readonly Hex[];
	data: Hex;
	logIndex: number | bigint | null;
};

const ABI_BY_CONTRACT: Record<ContractKey, Abi> = {
	market: miniLendAbi as Abi,
	adapter: adapterAbi as Abi,
	rwa: rwaAbi as Abi,
	usdc: usdcAbi as Abi,
	pa: paAbi as Abi,
	hook: hookAbi as Abi,
	poolManager: poolManagerAbi as Abi,
	desk: deskAbi as Abi,
	factory: factoryAbi as Abi
};

type EventIndex = Map<string, AbiEvent>;

function indexEvents(abis: Abi[]): EventIndex {
	const index: EventIndex = new Map();
	for (const abi of abis) {
		for (const item of abi) {
			if (item.type !== 'event') continue;
			const topic = toEventSelector(item);
			if (!index.has(topic)) index.set(topic, item);
		}
	}
	return index;
}

const EVENTS_BY_CONTRACT = Object.fromEntries(
	Object.entries(ABI_BY_CONTRACT).map(([key, abi]) => [key, indexEvents([abi])])
) as Record<ContractKey, EventIndex>;

/** Used only for emitters outside the manifest; their attribution says "other". */
const ANY_EVENT = indexEvents(Object.values(ABI_BY_CONTRACT));

function contractKeyOf(address: string, ctx: LogContext): ContractKey | null {
	const lower = address.toLowerCase();
	const hit = (Object.entries(ctx.contracts) as [ContractKey, string][]).find(
		([, value]) => value.toLowerCase() === lower
	);
	return hit ? hit[0] : null;
}

function swapAttribution(
	key: ContractKey | null,
	args: DecodedLog['args'],
	ctx: LogContext
): SwapAttribution {
	const id = args.find((a) => a.name === 'id')?.value.toLowerCase();
	const sender = args.find((a) => a.name === 'sender')?.value.toLowerCase();
	const emitter = key === 'hook' ? 'hook' : key === 'poolManager' ? 'poolManager' : 'other';
	const poolIdMatches = id === ctx.poolId.toLowerCase();
	const senderIsAdapter = sender === ctx.contracts.adapter.toLowerCase();
	return {
		emitter,
		poolIdMatches,
		senderIsAdapter,
		canonical: emitter === 'hook' && poolIdMatches && senderIsAdapter
	};
}

function decodeOne(log: RawLog, ctx: LogContext): DecodedLog {
	const address = getAddress(log.address);
	const key = contractKeyOf(address, ctx);
	const topic0 = log.topics[0];
	const logIndex = Number(log.logIndex ?? -1);
	const emitter = key ?? ctx.labels[address.toLowerCase()] ?? address;
	const base: DecodedLog = { logIndex, address, emitter, event: null, signature: null, args: [] };
	if (!topic0) return base;

	const event = (key ? EVENTS_BY_CONTRACT[key] : ANY_EVENT).get(topic0);
	if (!event) return { ...base, signature: key ? null : (eventSignatures[topic0] ?? null) };

	try {
		const decoded = decodeEventLog({
			abi: [event],
			topics: log.topics as [Hex, ...Hex[]],
			data: log.data,
			strict: true
		});
		const named = decoded.args as unknown as Record<string, unknown>;
		const values = event.inputs.map((input, i) => named[input.name ?? String(i)] ?? named[String(i)]);
		const args = decodeArgs(event.inputs, values, ctx);
		const signature = `${event.name}(${event.inputs.map((i) => i.type).join(',')})`;
		const decodedLog: DecodedLog = { ...base, event: event.name, signature, args };
		return event.name === 'Swap' ? { ...decodedLog, swap: swapAttribution(key, args, ctx) } : decodedLog;
	} catch {
		return base;
	}
}

export function decodeLogs(logs: readonly RawLog[], ctx: LogContext): DecodedLog[] {
	return logs.map((log) => decodeOne(log, ctx)).sort((a, b) => a.logIndex - b.logIndex);
}
