/** Display helpers shared by the page components. Pure. */
import { ACTION_LABELS } from './actions';
import { MAX_UINT256, WAD, formatFlags, formatHealthFactor, formatUnit } from './format';
import type {
	ActionName,
	ActionResponse,
	ChainState,
	Holder,
	HolderKey,
	ReadValue,
	Unit
} from './types';

export type Tone = 'value' | 'missing' | 'failed';
export type Shown = { text: string; tone: Tone };

export function showRead(read: ReadValue | undefined, unit: Unit): Shown {
	if (!read) return { text: 'read failed', tone: 'failed' };
	if (read.ok) return { text: formatUnit(read.value, unit), tone: 'value' };
	return read.reason === 'not-implemented'
		? { text: 'not implemented yet', tone: 'missing' }
		: { text: 'read failed', tone: 'failed' };
}

export function showFlags(read: ReadValue<number> | undefined): Shown {
	if (!read) return { text: 'read failed', tone: 'failed' };
	if (!read.ok) return showRead(read as ReadValue, 'raw');
	return { text: formatFlags(read.value), tone: 'value' };
}

export function showBool(read: ReadValue<boolean> | undefined, yes: string, no: string): Shown {
	if (!read) return { text: 'read failed', tone: 'failed' };
	if (!read.ok) return showRead(read as ReadValue, 'raw');
	return { text: read.value ? yes : no, tone: 'value' };
}

export function showHealth(read: ReadValue | undefined): Shown {
	if (!read?.ok) return showRead(read, 'raw');
	return { text: formatHealthFactor(BigInt(read.value)), tone: 'value' };
}

export type HealthStatus = 'healthy' | 'liquidatable' | 'no-debt' | 'unknown';

export function healthStatus(read: ReadValue | undefined): HealthStatus {
	if (!read?.ok) return 'unknown';
	const hf = BigInt(read.value);
	if (hf === MAX_UINT256) return 'no-debt';
	return hf < WAD ? 'liquidatable' : 'healthy';
}

export function holderOf(state: ChainState | null, key: HolderKey): Holder | undefined {
	return state?.holders.find((h) => h.key === key);
}

const EMITTER_NAMES: Record<string, string> = {
	market: 'MiniLend',
	adapter: 'Adapter',
	rwa: 'RWA token',
	usdc: 'USDC',
	pa: 'Pool wrapper (PA)',
	hook: 'Hook',
	poolManager: 'PoolManager',
	desk: 'Desk',
	factory: 'Factory'
};

export function emitterName(key: string): string {
	return EMITTER_NAMES[key] ?? key;
}

const USDC_ARGS = new Set([
	'repaid',
	'proceeds',
	'bounty',
	'residual',
	'badDebt',
	'debtRepaid',
	'badDebtRecovered',
	'borrowerCredit',
	'assets'
]);

/** Which decimals an event argument is expressed in, so amounts render in token units. */
export function argUnit(
	emitter: string,
	event: string | null,
	arg: string,
	rwaIsCurrency0: boolean
): Unit {
	if (event === 'Transfer' && arg === 'value') {
		if (emitter === 'usdc') return 'usdc';
		if (emitter === 'rwa' || emitter === 'pa') return 'rwa';
	}
	if (event === 'Swap' && (arg === 'amount0' || arg === 'amount1')) {
		const rwaSide = rwaIsCurrency0 ? 'amount0' : 'amount1';
		return arg === rwaSide ? 'rwa' : 'usdc';
	}
	if (event === 'NavUpdated' && arg === 'nav') return 'wad';
	if (arg === 'seized') return 'rwa';
	if (USDC_ARGS.has(arg)) return 'usdc';
	return 'raw';
}

export function statusLabel(response: ActionResponse): string {
	if (response.status === 'reset') return 'Local reset, not a transaction';
	if (response.status === 'simulation-reverted') return 'Simulation: would revert';
	return response.error ? 'Mined, reverted on-chain' : 'Mined transaction';
}

/** One sentence for the live region after each action. */
export function summarize(action: ActionName, response: ActionResponse): string {
	const label = ACTION_LABELS[action];
	if (response.status === 'reset') {
		return `Local reset to the healthy snapshot; new snapshot ${response.snapshotId}. Timeline cleared.`;
	}
	if (response.status === 'simulation-reverted') {
		return `${label}: simulation would revert with ${response.error?.name ?? 'an unknown error'}. Nothing was sent.`;
	}
	if (response.error) return `${label}: mined but reverted with ${response.error.name}.`;
	return `${label}: mined transaction ${response.txHash}.`;
}
