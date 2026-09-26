/**
 * Wire types shared by the server routes and the page.
 * Every integer that can exceed 2^53 travels as a decimal string.
 */

export const ACTIONS = [
	'crash',
	'horizon',
	'liquidateFull',
	'withdraw95',
	'liquidateChunk',
	'revoke',
	'reset'
] as const;

export type ActionName = (typeof ACTIONS)[number];

export type ActionStatus = 'mined' | 'simulation-reverted' | 'reset';

export type Unit = 'usdc' | 'rwa' | 'wad' | 'raw';

export type DecodedArg = {
	name: string;
	type: string;
	value: string;
	/** Manifest role of an address argument, when known. */
	label?: string;
};

export type ErrorLayer = {
	kind: 'known' | 'wrapped' | 'unknown' | 'empty';
	/** 4-byte error selector; null for a revert without data. */
	selector: string | null;
	name: string | null;
	signature: string | null;
	args: DecodedArg[];
	/** Contract that produced this layer, when the wrapper says so. */
	target: { address: string; label: string | null } | null;
	/** Contracts whose ABI declares this selector. */
	declaredBy: string[];
	/** WrappedError only: the function called on the target and the extra context. */
	call?: string;
	context?: string;
	raw?: string;
	/** WrappedError past the nesting limit: its reason was kept raw, not decoded. */
	truncated?: boolean;
};

export type DecodedRevert = {
	/** Innermost known cause, e.g. "Unauthorized". */
	name: string;
	message: string;
	layers: ErrorLayer[];
};

export type SwapAttribution = {
	emitter: 'hook' | 'poolManager' | 'other';
	poolIdMatches: boolean;
	senderIsAdapter: boolean;
	/** Emitted by the canonical hook, for this pool, with the adapter as sender. */
	canonical: boolean;
};

export type DecodedLog = {
	logIndex: number;
	address: string;
	emitter: string;
	event: string | null;
	signature: string | null;
	args: DecodedArg[];
	swap?: SwapAttribution;
};

export type Check = {
	id: string;
	label: string;
	unit: Unit;
	expected: string | null;
	actual: string | null;
	/** null when the check does not apply to this receipt. */
	ok: boolean | null;
	note?: string;
};

export type ResidualRoute = 'residual-applied' | 'direct-to-borrower' | 'none' | 'unaccounted';

export type Reconciliation = {
	liquidation: {
		repaid: string;
		seized: string;
		proceeds: string;
		bounty: string;
		residual: string;
		badDebt: string;
	} | null;
	residualRoute: ResidualRoute;
	residualApplied: { debtRepaid: string; badDebtRecovered: string; borrowerCredit: string } | null;
	debt: { before: string; after: string };
	checks: Check[];
};

export type SimulationRecord = {
	label: string;
	from: string;
	call: string;
	ok: boolean;
	result?: string;
	error?: DecodedRevert;
};

export type ActionDetail = {
	action: ActionName;
	signer: { role: 'issuer' | 'mm' | 'keeper'; address: string } | null;
	call: string;
	simulations: SimulationRecord[];
	quote?: { repayAssets: string; bounty: string; minBounty: string };
	receipt?: {
		blockNumber: string;
		gasUsed: string;
		status: 'success' | 'reverted';
		logs: DecodedLog[];
	};
	reconciliation?: Reconciliation;
	/** Set when the transaction mined but the balances around it could not be read. */
	reconciliationError?: string;
	revert?: DecodedRevert;
	reset?: { revertedTo: string; blockNumber: string; blockTimestamp: string };
};

/** O5 response: status, txHash, error and snapshotId, plus the decoded evidence in `detail`. */
export type ActionResponse = {
	status: ActionStatus;
	txHash?: string;
	error?: { name: string; message: string };
	snapshotId?: string;
	detail: ActionDetail;
};

export type ReadValue<T = string> =
	{ ok: true; value: T } | { ok: false; reason: 'not-implemented' | 'reverted'; message: string };

export type HolderKey =
	| 'issuer'
	| 'mm'
	| 'keeper'
	| 'borrower'
	| 'lender'
	| 'market'
	| 'adapter'
	| 'pa'
	| 'poolManager'
	| 'desk';

export type Holder = {
	key: HolderKey;
	label: string;
	address: string;
	rwa: ReadValue;
	usdc: ReadValue;
	flags: ReadValue<number>;
	frozen: ReadValue<boolean>;
};

export type Quote = { repayAssets: string } & (
	| { ok: true; bounty: string }
	| { ok: false; error: { name: string; message: string }; revert?: DecodedRevert }
);

/** POST /api/probe: the keeper's adapter eth_call for the O7 control pair. Never signed or sent. */
export type ProbeRecord = {
	/** Snapshot id of the branch the simulation ran on. */
	branch: string | null;
	block: string;
	from: string;
	call: string;
	quote: Quote;
};

export type ChainState = {
	env: {
		label: string;
		network: string;
		chainId: number;
		forkBlock: string | null;
		sourceCommit: string;
	};
	block: { number: string; timestamp: string };
	/** Snapshot id saved by the last reset; it changes on every reset, so it names the branch. */
	branch: string | null;
	addresses: Record<string, string>;
	poolId: string;
	/** PA sorts before USDC, so the RWA side of a Swap is amount0. */
	rwaIsCurrency0: boolean;
	navFloorBps: number;
	market: {
		nav: ReadValue;
		navUpdatedAt: ReadValue;
		maxStaleness: ReadValue;
		healthFactor: ReadValue;
		collateral: ReadValue;
		debt: ReadValue;
		totalDebt: ReadValue;
		totalSupplyAssets: ReadValue;
		totalBadDebt: ReadValue;
		badDebtOf: ReadValue;
		claimableResidual: ReadValue;
		totalResidualClaims: ReadValue;
		liquidationBlocked: ReadValue<boolean>;
	};
	navStatus: { fresh: boolean | null; ageSeconds: string | null; floor: string | null };
	/** LiquidationAdapter.NAV_FLOOR_BPS(): "not implemented" while the deployed adapter has no NAV floor. */
	adapterNavFloorBps: ReadValue<number>;
	pool: {
		sqrtPriceX96: ReadValue;
		tick: ReadValue<number>;
		lpFee: ReadValue<number>;
		liquidity: ReadValue;
		spot: string | null;
		virtualRwa: string | null;
		virtualUsdc: string | null;
		spotAboveFloor: boolean | null;
	};
	holders: Holder[];
	rwaPaused: ReadValue<boolean>;
	permissions: {
		swappingEnabled: ReadValue<boolean>;
		adapterWrapper: ReadValue<boolean>;
		deskWrapper: ReadValue<boolean>;
		hookAllowed: ReadValue<boolean>;
	};
	quotes: { full: Quote; chunk: Quote };
	liquidation: { enabled: boolean; reason: string | null };
};
