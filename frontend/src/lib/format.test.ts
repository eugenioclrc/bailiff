import { describe, expect, test } from 'bun:test';
import {
	MAX_UINT256,
	formatDuration,
	formatFixed,
	formatFlags,
	formatHealthFactor,
	formatLiquidity,
	formatUnit,
	navFloorWad,
	shortAddress,
	spotPriceWad,
	virtualReserves
} from './format';

const WAD = 10n ** 18n;
// Baseline pool from the dev deployment: PA is currency0, spot 100 USDC per RWA, L = 5e17.
const SQRT_P_100 = 792281625142643375935439n;
const L = 500_000_000_000_000_000n;

describe('spotPriceWad', () => {
	test('PA as currency0 reads 100 USDC per RWA (floored by at most 1 wei)', () => {
		const spot = spotPriceWad(SQRT_P_100, true);
		expect(100n * WAD - spot).toBeLessThanOrEqual(1n);
		expect(formatFixed(spot, 18, 2)).toBe('100.00');
	});

	test('PA as currency1 inverts the ratio', () => {
		// sqrt(1e30 * 2^192 / 100e18) = 2^96 * 1e5 for the mirrored pool
		const inverse = 2n ** 96n * 100_000n;
		expect(spotPriceWad(inverse, false)).toBe(100n * WAD);
	});

	test('zero price yields zero instead of dividing by zero', () => {
		expect(spotPriceWad(0n, false)).toBe(0n);
	});
});

describe('navFloorWad', () => {
	test('99% of 85 is 84.15, rounded up', () => {
		expect(navFloorWad(85n * WAD, 9900)).toBe(8415n * 10n ** 16n);
	});

	test('rounds up on a remainder', () => {
		expect(navFloorWad(1n, 9900)).toBe(1n);
	});
});

describe('virtualReserves', () => {
	test('L = 5e17 at 100 is about 50,000 RWA and 5,000,000 USDC', () => {
		const { rwa, usdc } = virtualReserves(L, SQRT_P_100, true);
		expect(rwa / WAD).toBe(50_000n);
		expect(usdc / 10n ** 6n).toBe(5_000_000n - 1n);
	});

	test('95% withdrawn leaves about 2,500 RWA and 250,000 USDC', () => {
		const { rwa, usdc } = virtualReserves(L / 20n, SQRT_P_100, true);
		expect(rwa / WAD).toBe(2_500n);
		expect(usdc / 10n ** 6n).toBe(249_999n);
	});
});

describe('formatFixed', () => {
	test('groups thousands and pads decimals', () => {
		expect(formatFixed(75_000_000_000n, 6, 2)).toBe('75,000.00');
		expect(formatFixed(0n, 6, 2)).toBe('0.00');
	});

	test('rounds half up at the last shown digit', () => {
		expect(formatFixed(1_066_666_666_666_666_666n, 18, 4)).toBe('1.0667');
		expect(formatFixed(906_666_666_666_666_666n, 18, 4)).toBe('0.9067');
		expect(formatFixed(12_345n, 3, 1)).toBe('12.3');
	});

	test('handles negatives and zero decimals', () => {
		expect(formatFixed(-1_500_000n, 6, 2)).toBe('-1.50');
		expect(formatFixed(1_234_567n, 0, 0)).toBe('1,234,567');
	});
});

describe('formatUnit', () => {
	test('uses token decimals per unit', () => {
		expect(formatUnit('91541590000', 'usdc')).toBe('91,541.59');
		expect(formatUnit('935294117647058823529', 'rwa')).toBe('935.2941');
		expect(formatUnit('84150000000000000000', 'wad')).toBe('84.15');
		expect(formatUnit('17', 'raw')).toBe('17');
	});

	test('passes non-numeric strings through', () => {
		expect(formatUnit('n/a', 'usdc')).toBe('n/a');
	});
});

describe('formatHealthFactor', () => {
	test('max uint means no debt', () => {
		expect(formatHealthFactor(MAX_UINT256)).toBe('no debt');
	});

	test('four decimals', () => {
		expect(formatHealthFactor(1_066_666_666_666_666_666n)).toBe('1.0667');
	});
});

describe('formatLiquidity', () => {
	test('scientific with two decimals', () => {
		expect(formatLiquidity(L)).toBe('5.00e17');
		expect(formatLiquidity(25_000_000_000_000_000n)).toBe('2.50e16');
		expect(formatLiquidity(0n)).toBe('0');
		expect(formatLiquidity(999n)).toBe('999');
	});
});

describe('formatFlags', () => {
	test('names the checker bits', () => {
		expect(formatFlags(0)).toBe('NONE');
		expect(formatFlags(0x8000)).toBe('HOLDER');
		expect(formatFlags(0x8003)).toBe('HOLDER, SWAP, LIQUIDITY');
		expect(formatFlags(0x8001)).toBe('HOLDER, SWAP');
		expect(formatFlags(0x0100)).toBe('0x0100');
	});
});

describe('formatDuration', () => {
	test('picks the two largest units', () => {
		expect(formatDuration(45n)).toBe('45s');
		expect(formatDuration(125n)).toBe('2m 5s');
		expect(formatDuration(3_700n)).toBe('1h 1m');
		expect(formatDuration(90_000n)).toBe('1d 1h');
		expect(formatDuration(86_400n)).toBe('1d');
		expect(formatDuration(3_600n)).toBe('1h');
		expect(formatDuration(-5n)).toBe('0s');
	});
});

describe('shortAddress', () => {
	test('keeps the checksum case', () => {
		expect(shortAddress('0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266')).toBe('0xf39F…2266');
		expect(shortAddress('nope')).toBe('nope');
	});
});
