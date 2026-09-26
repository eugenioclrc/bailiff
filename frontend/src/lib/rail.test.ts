import { describe, expect, test } from 'bun:test';
import { railScene, railSentence, residualLabel, type RailScene } from './rail';
import type { ActionItem, ProbeItem } from './timeline';
import type {
	ActionName,
	ActionResponse,
	DecodedRevert,
	ErrorLayer,
	Reconciliation
} from './types';

const KEEPER = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC';

function layer(name: string, declaredBy: string[], extra: Partial<ErrorLayer> = {}): ErrorLayer {
	return {
		kind: 'known',
		selector: '0x00000000',
		name,
		signature: `${name}()`,
		args: [],
		target: null,
		declaredBy,
		...extra
	};
}

function revert(...layers: ErrorLayer[]): DecodedRevert {
	const inner = layers.at(-1)!;
	return { name: inner.name ?? 'unknown', message: `${inner.name}()`, layers };
}

function action(
	id: number,
	name: ActionName,
	response: Omit<ActionResponse, 'detail'> & { detail?: Partial<ActionResponse['detail']> }
): ActionItem {
	return {
		kind: 'action',
		id,
		at: '22:52:55',
		action: name,
		response: {
			...response,
			detail: { action: name, signer: null, call: '', simulations: [], ...response.detail }
		}
	};
}

function probe(id: number, quote: ProbeItem['quote']): ProbeItem {
	return { kind: 'probe', id, at: '23:01:12', block: '1', from: KEEPER, call: '', quote };
}

const RECONCILIATION: Reconciliation = {
	liquidation: {
		repaid: '75000000000',
		seized: '935294117647058823529',
		proceeds: '91541594333',
		bounty: '4500000000',
		residual: '12041594333',
		badDebt: '0'
	},
	residualRoute: 'direct-to-borrower',
	residualApplied: null,
	debt: { before: '75000000000', after: '0' },
	checks: []
};

const HEALTHY = revert(layer('Healthy', ['MiniLend']));
const INSUFFICIENT = revert(layer('InsufficientProceeds', ['LiquidationAdapter']));
const UNAUTHORIZED = revert(
	{
		...layer('WrappedError', ['CustomRevert']),
		kind: 'wrapped',
		call: 'PermissionedHooks.beforeSwap(...)'
	},
	layer('Unauthorized', ['PermissionedHooks'])
);
const NOT_ALLOWLISTED = revert(
	layer('NotAllowlisted', ['MockRWA3643'], {
		args: [{ name: 'to', type: 'address', value: KEEPER, label: 'keeper' }]
	})
);

describe('railScene', () => {
	test('is idle with no timeline entry and after actions that move no collateral', () => {
		expect(railScene(undefined)).toEqual({ kind: 'idle' });
		const crash = action(1, 'crash', { status: 'mined', txHash: '0x1' });
		expect(railScene(crash)).toEqual({ kind: 'idle' });
		const reset = action(2, 'reset', { status: 'reset', snapshotId: '0x2' });
		expect(railScene(reset)).toEqual({ kind: 'idle' });
	});

	test('a mined liquidation lights the rail with the amounts of its receipt', () => {
		const item = action(7, 'liquidateFull', {
			status: 'mined',
			txHash: '0x7',
			detail: { reconciliation: RECONCILIATION }
		});
		expect(railScene(item)).toEqual({
			kind: 'mined',
			id: 7,
			seized: '935294117647058823529',
			proceeds: '91541594333',
			repaid: '75000000000',
			bounty: '4500000000',
			residual: '12041594333',
			residualRoute: 'direct-to-borrower'
		});
	});

	test('a mined liquidation without reconciled amounts leaves the rail idle', () => {
		const item = action(8, 'liquidateChunk', { status: 'mined', txHash: '0x8' });
		expect(railScene(item)).toEqual({ kind: 'idle' });
	});

	test('the direct route stops at the RWA token, which refuses to pay the keeper', () => {
		const item = action(3, 'horizon', {
			status: 'simulation-reverted',
			error: { name: 'NotAllowlisted', message: '' },
			detail: { revert: NOT_ALLOWLISTED }
		});
		expect(railScene(item)).toEqual({
			kind: 'stopped',
			id: 3,
			route: 'direct',
			stop: 'keeper',
			error: 'NotAllowlisted',
			by: 'the RWA token',
			mined: false
		});
	});

	test('a healthy position stops either route at MiniLend', () => {
		const direct = action(4, 'horizon', {
			status: 'simulation-reverted',
			detail: { revert: HEALTHY }
		});
		expect(railScene(direct)).toMatchObject({ route: 'direct', stop: 'market', by: 'MiniLend' });
		const adapter = action(5, 'liquidateFull', {
			status: 'simulation-reverted',
			detail: { revert: HEALTHY }
		});
		expect(railScene(adapter)).toMatchObject({ route: 'adapter', stop: 'market' });
	});

	test('a thin pool stops the adapter route at the adapter', () => {
		const item = action(6, 'liquidateFull', {
			status: 'simulation-reverted',
			detail: { revert: INSUFFICIENT }
		});
		expect(railScene(item)).toMatchObject({
			kind: 'stopped',
			route: 'adapter',
			stop: 'adapter',
			error: 'InsufficientProceeds',
			by: 'the adapter'
		});
	});

	test('after a revoke the probe stops at the canonical hook, inside the PoolManager swap', () => {
		const item = probe(9, {
			ok: false,
			repayAssets: '0',
			error: { name: 'Unauthorized', message: '' },
			revert: UNAUTHORIZED
		});
		expect(railScene(item)).toEqual({
			kind: 'stopped',
			id: 9,
			route: 'adapter',
			stop: 'poolManager',
			error: 'Unauthorized',
			by: 'the canonical hook',
			mined: false
		});
	});

	test('a probe that would succeed runs the whole adapter route', () => {
		const item = probe(10, { ok: true, repayAssets: '0', bounty: '4500000000' });
		expect(railScene(item)).toEqual({ kind: 'clear', id: 10, bounty: '4500000000' });
	});

	test('an error no deployed contract declares keeps its name but no stop', () => {
		const unknown = revert({ ...layer('', []), kind: 'unknown', name: null });
		const item = probe(11, {
			ok: false,
			repayAssets: '0',
			error: { name: 'UnknownError', message: '' },
			revert: unknown
		});
		expect(railScene(item)).toMatchObject({ stop: null, by: null, error: 'UnknownError' });
	});

	test('a sent liquidation that reverted is a stop, marked as mined', () => {
		const item = action(12, 'liquidateChunk', {
			status: 'mined',
			txHash: '0xc',
			error: { name: 'Unauthorized', message: '' },
			detail: { revert: UNAUTHORIZED }
		});
		expect(railScene(item)).toMatchObject({ kind: 'stopped', stop: 'poolManager', mined: true });
	});
});

describe('residualLabel', () => {
	test('names where the residual went, as the receipt shows it', () => {
		expect(residualLabel('direct-to-borrower')).toBe('residual to the borrower wallet');
		expect(residualLabel('residual-applied')).toBe('residual applied by MiniLend');
		expect(residualLabel('unaccounted')).toBe('residual with no matching transfer');
		expect(residualLabel('none')).toBeNull();
	});
});

describe('railSentence', () => {
	const mined = railScene(
		action(7, 'liquidateFull', {
			status: 'mined',
			txHash: '0x7',
			detail: { reconciliation: RECONCILIATION }
		})
	);

	test('reads a mined liquidation as the route and the split, in token units', () => {
		expect(railSentence(mined)).toBe(
			'Last mined liquidation: 935.2941 RWA went from MiniLend to the adapter to the pool wrapper (PA), which minted 935.2941 pool tokens to PoolManager. 91,541.59 USDC came back to the adapter: 75,000.00 repaid to MiniLend, 4,500.00 bounty to the keeper, 12,041.59 residual to the borrower wallet.'
		);
	});

	test('says where a simulated route stops and that nothing was sent', () => {
		const scene: RailScene = {
			kind: 'stopped',
			id: 1,
			route: 'adapter',
			stop: 'poolManager',
			error: 'Unauthorized',
			by: 'the canonical hook',
			mined: false
		};
		expect(railSentence(scene)).toBe(
			'Simulation of the adapter route would revert with Unauthorized from the canonical hook. Nothing was sent.'
		);
		expect(
			railSentence({ ...scene, route: 'direct', error: 'NotAllowlisted', by: 'the RWA token' })
		).toBe(
			'Simulation of the direct route, the keeper calling MiniLend, would revert with NotAllowlisted from the RWA token. Nothing was sent.'
		);
		expect(railSentence({ ...scene, mined: true, by: null })).toBe(
			'The sent liquidation reverted with Unauthorized; no seized RWA moved.'
		);
	});

	test('covers the idle rail and a probe that would succeed', () => {
		expect(railSentence({ kind: 'idle' })).toBe('No liquidation on this branch yet.');
		expect(railSentence({ kind: 'clear', id: 2, bounty: '4500000000' })).toBe(
			'Simulation of the adapter route would succeed with a 4,500.00 USDC bounty. Nothing was sent.'
		);
	});
});
