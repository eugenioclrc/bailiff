/**
 * Display and price math on bigints. Nothing here converts a bigint to a JS number
 * before deciding a value, so it is safe to reuse on the server.
 */
import type { Unit } from './types';

export const MAX_UINT256 = 2n ** 256n - 1n;
export const WAD = 10n ** 18n;
const Q96 = 2n ** 96n;
const Q192 = 2n ** 192n;
/** 1e18 (RWA decimals) * 1e18 (WAD) / 1e6 (USDC decimals), as in MiniLend.PRICE_SCALE. */
const PRICE_SCALE = 10n ** 30n;
const BPS = 10_000n;

export const UNIT_DECIMALS: Record<Unit, number> = { usdc: 6, rwa: 18, wad: 18, raw: 0 };
const UNIT_FRACTION: Record<Unit, number> = { usdc: 2, rwa: 4, wad: 2, raw: 0 };

const FLAG_NAMES: [number, string][] = [
	[0x8000, 'HOLDER'],
	[0x0001, 'SWAP'],
	[0x0002, 'LIQUIDITY']
];

/** Pool spot in USDC per whole RWA, WAD-scaled, floored. */
export function spotPriceWad(sqrtPriceX96: bigint, rwaIsCurrency0: boolean): bigint {
	if (sqrtPriceX96 === 0n) return 0n;
	const squared = sqrtPriceX96 * sqrtPriceX96;
	return rwaIsCurrency0 ? (squared * PRICE_SCALE) / Q192 : (PRICE_SCALE * Q192) / squared;
}

/** ceil(nav * bps / 10000), the adapter's conservative NAV floor. */
export function navFloorWad(nav: bigint, bps: number): bigint {
	const numerator = nav * BigInt(bps);
	return (numerator + BPS - 1n) / BPS;
}

/** Virtual depth of a full-range position: token amounts equivalent to L at the current price. */
export function virtualReserves(
	liquidity: bigint,
	sqrtPriceX96: bigint,
	rwaIsCurrency0: boolean
): { rwa: bigint; usdc: bigint } {
	if (sqrtPriceX96 === 0n) return { rwa: 0n, usdc: 0n };
	const amount0 = (liquidity * Q96) / sqrtPriceX96;
	const amount1 = (liquidity * sqrtPriceX96) / Q96;
	return rwaIsCurrency0 ? { rwa: amount0, usdc: amount1 } : { rwa: amount1, usdc: amount0 };
}

function groupThousands(digits: string): string {
	return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/** Fixed-point bigint to a grouped decimal string, rounded half up at `fraction` digits. */
export function formatFixed(value: bigint, decimals: number, fraction: number): string {
	const negative = value < 0n;
	const abs = negative ? -value : value;
	const drop = decimals - fraction;
	let scaled: bigint;
	if (drop > 0) {
		const divisor = 10n ** BigInt(drop);
		scaled = (abs + divisor / 2n) / divisor;
	} else {
		scaled = abs * 10n ** BigInt(-drop);
	}
	const unit = 10n ** BigInt(fraction);
	const whole = groupThousands((scaled / unit).toString());
	const frac = fraction > 0 ? '.' + (scaled % unit).toString().padStart(fraction, '0') : '';
	return `${negative ? '-' : ''}${whole}${frac}`;
}

export function formatUnit(value: string | bigint, unit: Unit, fraction?: number): string {
	if (typeof value === 'string' && !/^-?\d+$/.test(value)) return value;
	return formatFixed(BigInt(value), UNIT_DECIMALS[unit], fraction ?? UNIT_FRACTION[unit]);
}

export function formatHealthFactor(hf: bigint): string {
	return hf === MAX_UINT256 ? 'no debt' : formatFixed(hf, 18, 4);
}

export function formatLiquidity(liquidity: bigint): string {
	if (liquidity < 1000n) return liquidity.toString();
	const digits = liquidity.toString();
	const exponent = digits.length - 1;
	const mantissa = formatFixed(BigInt(digits.slice(0, 4)), 3, 2);
	return `${mantissa}e${exponent}`;
}

export function formatFlags(flags: number): string {
	if (flags === 0) return 'NONE';
	const known = FLAG_NAMES.filter(([bit]) => (flags & bit) !== 0).map(([, name]) => name);
	const knownMask = FLAG_NAMES.reduce((mask, [bit]) => mask | bit, 0);
	if ((flags & ~knownMask) !== 0 || known.length === 0) {
		return `0x${flags.toString(16).padStart(4, '0')}`;
	}
	return known.join(', ');
}

export function formatDuration(seconds: bigint): string {
	if (seconds <= 0n) return '0s';
	const units: [bigint, string][] = [
		[86_400n, 'd'],
		[3_600n, 'h'],
		[60n, 'm'],
		[1n, 's']
	];
	const parts: string[] = [];
	let rest = seconds;
	for (const [size, suffix] of units) {
		if (rest >= size || parts.length > 0) {
			parts.push(`${rest / size}${suffix}`);
			rest %= size;
		}
		if (parts.length === 2) break;
	}
	return parts.join(' ');
}

export function shortAddress(address: string): string {
	return /^0x[0-9a-fA-F]{40}$/.test(address) ? `${address.slice(0, 6)}…${address.slice(-4)}` : address;
}
