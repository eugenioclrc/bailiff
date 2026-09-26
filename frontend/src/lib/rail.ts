/**
 * What the collateral rail shows for the newest timeline entry. Pure, so it runs under `bun test`.
 *
 * The rail is the route of the seized RWA: MiniLend market, liquidation adapter, pool wrapper (PA),
 * PoolManager. A mined liquidation lights it with the amounts of its receipt; a simulation that
 * would revert stops at the contract that declares the error. The keeper stays off the rail.
 */
import { formatUnit } from './format';
import type { TimelineItem } from './timeline';
import type { DecodedRevert, ResidualRoute } from './types';

export type Station = 'market' | 'adapter' | 'pa' | 'poolManager';

/** In route order: seized RWA only ever moves left to right along these. */
export const STATIONS: readonly Station[] = ['market', 'adapter', 'pa', 'poolManager'];

export type RailScene =
	| { kind: 'idle' }
	| {
			kind: 'mined';
			id: number;
			seized: string;
			proceeds: string;
			repaid: string;
			bounty: string;
			residual: string;
			residualRoute: ResidualRoute;
	  }
	| {
			kind: 'stopped';
			id: number;
			/** 'adapter' is the Bailiff route; 'direct' is the keeper calling MiniLend itself. */
			route: 'adapter' | 'direct';
			/** 'keeper' when the RWA token refuses to pay the keeper; null when no contract is known. */
			stop: Station | 'keeper' | null;
			error: string;
			/** Who raised it, in words; null when no deployed ABI declares the error. */
			by: string | null;
			/** A sent transaction that reverted, not a simulation. */
			mined: boolean;
	  }
	| { kind: 'clear'; id: number; bounty: string };

const IDLE: RailScene = { kind: 'idle' };

/** 'token' until the payee is known: the RWA token refuses a transfer, not a station. */
type Declarer = { stop: Station | 'keeper' | 'token'; by: string };

/** The ABI that declares the innermost error names the contract that raised it. */
const DECLARERS: Record<string, Declarer> = {
	MiniLend: { stop: 'market', by: 'MiniLend' },
	LiquidationAdapter: { stop: 'adapter', by: 'the adapter' },
	PermissionsAdapter: { stop: 'pa', by: 'the pool wrapper (PA)' },
	// The hook runs inside the PoolManager swap, so its refusal stops the route at that station.
	PermissionedHooks: { stop: 'poolManager', by: 'the canonical hook' },
	PoolManager: { stop: 'poolManager', by: 'PoolManager' },
	MockRWA3643: { stop: 'token', by: 'the RWA token' }
};

/** Manifest labels of the addresses a token transfer can be refused to. */
const PAYEES: Record<string, Station | 'keeper'> = {
	market: 'market',
	adapter: 'adapter',
	'pool wrapper (PA)': 'pa',
	pa: 'pa',
	PoolManager: 'poolManager',
	poolManager: 'poolManager',
	keeper: 'keeper'
};

function declarerOf(revert: DecodedRevert | undefined): Declarer | null {
	const layers = revert?.layers ?? [];
	for (let i = layers.length - 1; i >= 0; i--) {
		const layer = layers[i];
		if (layer.kind !== 'known') continue;
		const found = layer.declaredBy.map((name) => DECLARERS[name]).find(Boolean);
		if (!found) continue;
		if (found.stop !== 'token') return found;
		// A token refusal stops the RWA before the address it was being paid to.
		const payee = layer.args
			.map((arg) => (arg.label ? PAYEES[arg.label] : undefined))
			.find(Boolean);
		return payee ? { stop: payee, by: found.by } : null;
	}
	return null;
}

function stopped(
	id: number,
	route: 'adapter' | 'direct',
	error: string,
	revert: DecodedRevert | undefined,
	mined: boolean
): RailScene {
	const declarer = declarerOf(revert);
	const stop = declarer?.stop === 'token' ? null : (declarer?.stop ?? null);
	return { kind: 'stopped', id, route, stop, error, by: declarer?.by ?? null, mined };
}

export function railScene(item: TimelineItem | undefined): RailScene {
	if (!item) return IDLE;
	if (item.kind === 'probe') {
		const { quote } = item;
		if (quote.ok) return { kind: 'clear', id: item.id, bounty: quote.bounty };
		return stopped(item.id, 'adapter', quote.error.name, quote.revert, false);
	}

	const { action, response } = item;
	const route = action === 'horizon' ? 'direct' : 'adapter';
	if (action !== 'horizon' && action !== 'liquidateFull' && action !== 'liquidateChunk')
		return IDLE;

	if (response.status === 'simulation-reverted' || response.error) {
		const error = response.error?.name ?? response.detail.revert?.name ?? 'unknown error';
		return stopped(item.id, route, error, response.detail.revert, response.status === 'mined');
	}

	const liquidation = response.detail.reconciliation?.liquidation;
	if (response.status !== 'mined' || !liquidation) return IDLE;
	return {
		kind: 'mined',
		id: item.id,
		seized: liquidation.seized,
		proceeds: liquidation.proceeds,
		repaid: liquidation.repaid,
		bounty: liquidation.bounty,
		residual: liquidation.residual,
		residualRoute: response.detail.reconciliation!.residualRoute
	};
}

/** Where the residual went, as the receipt shows it; null when there was none. */
export function residualLabel(route: ResidualRoute): string | null {
	switch (route) {
		case 'direct-to-borrower':
			return 'residual to the borrower wallet';
		case 'residual-applied':
			return 'residual applied by MiniLend';
		case 'unaccounted':
			return 'residual with no matching transfer';
		default:
			return null;
	}
}

const ROUTE_NAMES = {
	adapter: 'the adapter route',
	direct: 'the direct route, the keeper calling MiniLend,'
} as const;

/** The scene in one sentence for screen readers; the drawn lanes carry the same facts. */
export function railSentence(scene: RailScene): string {
	switch (scene.kind) {
		case 'idle':
			return 'No liquidation on this branch yet.';
		case 'clear':
			return `Simulation of the adapter route would succeed with a ${formatUnit(scene.bounty, 'usdc')} USDC bounty. Nothing was sent.`;
		case 'stopped': {
			const from = scene.by ? ` from ${scene.by}` : '';
			if (scene.mined)
				return `The sent liquidation reverted with ${scene.error}${from}; no seized RWA moved.`;
			return `Simulation of ${ROUTE_NAMES[scene.route]} would revert with ${scene.error}${from}. Nothing was sent.`;
		}
		case 'mined': {
			const rwa = formatUnit(scene.seized, 'rwa');
			const residual = residualLabel(scene.residualRoute);
			const split = [
				`${formatUnit(scene.repaid, 'usdc')} repaid to MiniLend`,
				`${formatUnit(scene.bounty, 'usdc')} bounty to the keeper`,
				...(residual ? [`${formatUnit(scene.residual, 'usdc')} ${residual}`] : [])
			];
			return `Last mined liquidation: ${rwa} RWA went from MiniLend to the adapter to the pool wrapper (PA), which minted ${rwa} pool tokens to PoolManager. ${formatUnit(scene.proceeds, 'usdc')} USDC came back to the adapter: ${split.join(', ')}.`;
		}
	}
}
