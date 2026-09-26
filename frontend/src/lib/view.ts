/** Display helpers shared by the page components. Pure. */
import { ACTION_LABELS } from './actions';
import {
	MAX_UINT256,
	WAD,
	formatDuration,
	formatFlags,
	formatHealthFactor,
	formatUnit
} from './format';
import type {
	ActionName,
	ActionResponse,
	ChainState,
	Holder,
	HolderKey,
	Quote,
	ReadValue,
	Unit
} from './types';

export { argUnit } from './units';

export type Tone = 'value' | 'missing' | 'failed';
export type Shown = { text: string; tone: Tone };

/** No state has arrived yet; "read failed" is kept for reads that really failed. */
const NOT_READ: Shown = { text: 'not read yet', tone: 'missing' };

export function showRead(read: ReadValue | undefined, unit: Unit): Shown {
	if (!read) return NOT_READ;
	if (read.ok) return { text: formatUnit(read.value, unit), tone: 'value' };
	return read.reason === 'not-implemented'
		? { text: 'not implemented yet', tone: 'missing' }
		: { text: 'read failed', tone: 'failed' };
}

export function showFlags(read: ReadValue<number> | undefined): Shown {
	if (!read) return NOT_READ;
	if (!read.ok) return showRead(read as ReadValue, 'raw');
	return { text: formatFlags(read.value), tone: 'value' };
}

export function showBool(read: ReadValue<boolean> | undefined, yes: string, no: string): Shown {
	if (!read) return NOT_READ;
	if (!read.ok) return showRead(read as ReadValue, 'raw');
	return { text: read.value ? yes : no, tone: 'value' };
}

export function showHealth(read: ReadValue | undefined): Shown {
	if (!read?.ok) return showRead(read, 'raw');
	return { text: formatHealthFactor(BigInt(read.value)), tone: 'value' };
}

/**
 * Header sync line. A failed read is checked before a pending refresh, so the header never keeps
 * saying "Updating" after the read that should have ended it failed. "Local" because the block is
 * the Anvil head, which does not exist on Sepolia.
 */
export function syncText(
	state: Pick<ChainState, 'block' | 'navStatus'> | null,
	stale: boolean,
	loadError: string | null
): string {
	if (!state) return loadError ? 'No chain state yet' : 'Reading chain state…';
	if (loadError) {
		return stale
			? 'Read failed after the last action: figures predate it'
			: `Last good read at local block ${state.block.number}`;
	}
	if (stale) return 'Updating after the last action…';
	const age = state.navStatus.ageSeconds
		? `, NAV set ${formatDuration(BigInt(state.navStatus.ageSeconds))} ago`
		: '';
	return `Local chain at block ${state.block.number}${age}`;
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

export function statusLabel(response: ActionResponse): string {
	if (response.status === 'reset') return 'Local reset, not a transaction';
	if (response.status === 'simulation-reverted') return 'Simulation: would revert';
	return response.error ? 'Mined on local Anvil, reverted' : 'Mined on local Anvil';
}

export function probeStatusLabel(quote: Quote): string {
	return quote.ok ? 'Simulation: would succeed' : 'Simulation: would revert';
}

export function probeSummary(quote: Quote): string {
	return quote.ok
		? `Adapter route simulation would succeed with a ${formatUnit(quote.bounty, 'usdc')} USDC bounty. Nothing was sent.`
		: `Adapter route simulation would revert with ${quote.error.name}. Nothing was sent.`;
}

/** One sentence for the live region after each action. */
export function summarize(action: ActionName, response: ActionResponse): string {
	const label = ACTION_LABELS[action];
	if (response.status === 'reset') {
		return `Local reset to the healthy snapshot; new snapshot ${response.snapshotId}. The previous branch moved to earlier branches.`;
	}
	if (response.status === 'simulation-reverted') {
		return `${label}: simulation would revert with ${response.error?.name ?? 'an unknown error'}. Nothing was sent.`;
	}
	if (response.error) return `${label}: mined but reverted with ${response.error.name}.`;
	return `${label}: mined on local Anvil, transaction ${response.txHash}.`;
}
