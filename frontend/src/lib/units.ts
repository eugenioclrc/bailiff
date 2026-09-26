/**
 * Which token an event or error argument is expressed in, so amounts render in token units
 * instead of raw base units. Pure; shared by the revert decoder and the page.
 */
import { formatHealthFactor, formatUnit } from './format';
import type { Unit } from './types';

const USDC_ARGS = new Set([
	'repaid',
	'proceeds',
	'bounty',
	'minBounty',
	'residual',
	'badDebt',
	'debtRepaid',
	'badDebtRecovered',
	'borrowerCredit',
	'assets'
]);

const RWA_ARGS = new Set(['seized', 'seize', 'sold']);

/** Pool and oracle integers a judge checks against cast, which prints them ungrouped. */
const PLAIN_INT_ARGS = new Set([
	'timestamp',
	'tick',
	'tickLower',
	'tickUpper',
	'tickSpacing',
	'sqrtPriceX96',
	'liquidity',
	'liquidityDelta',
	'fee',
	'protocolFee',
	'id',
	'flags'
]);

/** Which decimals an event argument is expressed in. */
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
	if (PLAIN_INT_ARGS.has(arg)) return 'int';
	if (RWA_ARGS.has(arg)) return 'rwa';
	if (USDC_ARGS.has(arg)) return 'usdc';
	return 'raw';
}

const UNIT_SUFFIX: Partial<Record<Unit, string>> = { usdc: ' USDC', rwa: ' RWA' };

/**
 * A custom-error argument in token units, e.g. proceeds=67916346056 -> "67,916.35 USDC".
 * null when the name is not a known amount, so the caller shows the raw value.
 */
export function errorArgText(name: string, value: string): string | null {
	if (!/^-?\d+$/.test(value)) return null;
	if (name === 'hf') return formatHealthFactor(BigInt(value));
	if (name === 'nav') return `${formatUnit(value, 'wad')} USDC per RWA`;
	const unit = RWA_ARGS.has(name) ? 'rwa' : USDC_ARGS.has(name) ? 'usdc' : null;
	return unit ? `${formatUnit(value, unit)}${UNIT_SUFFIX[unit] ?? ''}` : null;
}
