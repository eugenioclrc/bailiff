/** NAV freshness and the liquidation gate. Pure; mirrors MiniLend._freshNav. */
import { WAD, formatDuration, navFloorWad } from './format';
import type { ChainState } from './types';

/** O3 healthy snapshot NAV, in USDC per RWA with 18 decimals. */
export const BASELINE_NAV = 100n * WAD;

export type NavInputs = { nav?: bigint; updatedAt?: bigint; maxStaleness?: bigint };

/**
 * MiniLend reverts StaleNav when block.timestamp > navUpdatedAt + MAX_STALENESS, so the NAV is
 * fresh up to and including that second. `timestamp` should be the next block's timestamp.
 */
export function navStatus(
	inputs: NavInputs,
	timestamp: bigint,
	floorBps: number
): ChainState['navStatus'] {
	const { nav, updatedAt, maxStaleness } = inputs;
	if (nav === undefined || updatedAt === undefined || maxStaleness === undefined) {
		return { fresh: null, ageSeconds: null, floor: null };
	}
	return {
		fresh: timestamp <= updatedAt + maxStaleness,
		ageSeconds: (timestamp - updatedAt).toString(),
		floor: navFloorWad(nav, floorBps).toString()
	};
}

/** A stale or unreadable NAV closes every liquidation route; the reason is shown next to the buttons. */
export function liquidationGate(
	status: ChainState['navStatus'],
	maxStaleness: bigint | undefined
): ChainState['liquidation'] {
	if (status.fresh === null) {
		return { enabled: false, reason: 'NAV could not be read, so liquidation is disabled.' };
	}
	if (status.fresh) return { enabled: true, reason: null };
	const age = formatDuration(BigInt(status.ageSeconds ?? '0'));
	const limit = maxStaleness === undefined ? 'the limit' : formatDuration(maxStaleness);
	return {
		enabled: false,
		reason: `NAV is stale: last update ${age} ago, limit ${limit}. MiniLend would revert with StaleNav.`
	};
}
