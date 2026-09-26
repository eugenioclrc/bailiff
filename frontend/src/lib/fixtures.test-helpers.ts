/** Synthetic receipt logs for the decoder and reconciliation tests. */
import { encodeAbiParameters, encodeEventTopics, type Abi, type AbiEvent, type Hex } from 'viem';
import {
	adapterAbi,
	hookAbi,
	miniLendAbi,
	paAbi,
	poolManagerAbi,
	rwaAbi,
	usdcAbi
} from './abis.generated';
import type { LogContext, RawLog } from './logs';

export const ADDR = {
	market: '0xD3B75A6478E05D33efD4ef87Fc4f26A9356DeD3e',
	adapter: '0x0457329C4AB669D6eB6F4a9ad5E90Ab8551174C6',
	rwa: '0xCc4C8af3781f1040769A6ecAa4f1B71F2e9bB50f',
	usdc: '0xDe70e0eE374e7bD67A47A6F08c2c74A0e23637c9',
	pa: '0x7060947614ECED6CA376A318C81dF6C088f00718',
	hook: '0x51247E2291d290d17C08813A175AC86465EdE8c0',
	poolManager: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
	desk: '0xb08Bad5d71024c4cFF8ea81584C814e5434ECD10',
	factory: '0xE6B0d96919334C33d06266d1420F97f6f434fA2B',
	keeper: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
	borrower: '0x90F79bf6EB2c4f870365E785982E1f101E93b906'
} as const;

export const POOL_ID = '0xedc4098ab8ade6e09beeaad5e2dbd4cf38cf5564d652a4e47fcedf317fe8fec2' as Hex;
export const ZERO = '0x0000000000000000000000000000000000000000';

export const logContext: LogContext = {
	labels: Object.fromEntries(Object.entries(ADDR).map(([k, v]) => [v.toLowerCase(), k])),
	contracts: {
		market: ADDR.market,
		adapter: ADDR.adapter,
		rwa: ADDR.rwa,
		usdc: ADDR.usdc,
		pa: ADDR.pa,
		hook: ADDR.hook,
		poolManager: ADDR.poolManager,
		desk: ADDR.desk,
		factory: ADDR.factory
	},
	poolId: POOL_ID
};

export function makeLog(
	address: string,
	abi: Abi,
	eventName: string,
	args: Record<string, unknown>,
	logIndex: number
): RawLog {
	const event = abi.find((e): e is AbiEvent => e.type === 'event' && e.name === eventName);
	if (!event) throw new Error(`no event ${eventName}`);
	const topics = encodeEventTopics({
		abi: [event],
		eventName,
		args: Object.fromEntries(
			event.inputs.filter((i) => i.indexed).map((i) => [i.name, args[i.name!]])
		)
	} as never) as Hex[];
	const plain = event.inputs.filter((i) => !i.indexed);
	const data = encodeAbiParameters(
		plain,
		plain.map((i) => args[i.name!])
	);
	return { address, topics, data, logIndex };
}

export const LIQ = {
	repaid: 75_000_000_000n,
	seized: 935_294_117_647_058_823_529n,
	proceeds: 91_541_590_000n,
	bounty: 4_500_000_000n,
	residual: 12_041_590_000n
};

type Amounts = typeof LIQ;

/** Logs of a snapshot (pre-fix) adapter liquidation, deliberately out of logIndex order. */
export function preFixLiquidationLogs(liq: Amounts = LIQ): RawLog[] {
	const swapArgs = (sender: string) => ({
		id: POOL_ID,
		sender,
		amount0: -liq.seized,
		amount1: liq.proceeds,
		sqrtPriceX96: 790_000_000_000_000_000_000_000n,
		liquidity: 500_000_000_000_000_000n,
		tick: -230_300,
		fee: 3000
	});
	return [
		makeLog(
			ADDR.adapter,
			adapterAbi as Abi,
			'Liquidated',
			{ borrower: ADDR.borrower, keeper: ADDR.keeper, ...liq },
			10
		),
		makeLog(ADDR.hook, hookAbi as Abi, 'Swap', swapArgs(ADDR.adapter), 1),
		makeLog(ADDR.poolManager, poolManagerAbi as Abi, 'Swap', swapArgs(ADDR.adapter), 0),
		makeLog(
			ADDR.usdc,
			usdcAbi as Abi,
			'Transfer',
			{ from: ADDR.poolManager, to: ADDR.adapter, value: liq.proceeds },
			2
		),
		makeLog(
			ADDR.rwa,
			rwaAbi as Abi,
			'Transfer',
			{ from: ADDR.market, to: ADDR.adapter, value: liq.seized },
			3
		),
		makeLog(
			ADDR.usdc,
			usdcAbi as Abi,
			'Transfer',
			{ from: ADDR.adapter, to: ADDR.market, value: liq.repaid },
			4
		),
		makeLog(
			ADDR.market,
			miniLendAbi as Abi,
			'Liquidated',
			{
				liquidator: ADDR.adapter,
				borrower: ADDR.borrower,
				repaid: liq.repaid,
				seized: liq.seized,
				badDebt: 0n
			},
			5
		),
		makeLog(
			ADDR.rwa,
			rwaAbi as Abi,
			'Transfer',
			{ from: ADDR.adapter, to: ADDR.pa, value: liq.seized },
			6
		),
		makeLog(
			ADDR.pa,
			paAbi as Abi,
			'Transfer',
			{ from: ZERO, to: ADDR.poolManager, value: liq.seized },
			7
		),
		makeLog(
			ADDR.usdc,
			usdcAbi as Abi,
			'Transfer',
			{ from: ADDR.adapter, to: ADDR.keeper, value: liq.bounty },
			8
		),
		makeLog(
			ADDR.usdc,
			usdcAbi as Abi,
			'Transfer',
			{ from: ADDR.adapter, to: ADDR.borrower, value: liq.residual },
			9
		)
	];
}
