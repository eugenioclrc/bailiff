import { describe, expect, test } from 'bun:test';
import { errorArgText } from './units';

describe('errorArgText', () => {
	test('formats known error arguments in token units', () => {
		expect(errorArgText('proceeds', '67916346056')).toBe('67,916.35 USDC');
		expect(errorArgText('minBounty', '4365000000')).toBe('4,365.00 USDC');
		expect(errorArgText('seize', '1000000000000000000000')).toBe('1,000.0000 RWA');
		expect(errorArgText('hf', '906666666666666666')).toBe('0.9067');
		expect(errorArgText('nav', '85000000000000000000')).toBe('85.00 USDC per RWA');
	});

	test('leaves unknown names and non-numeric values alone', () => {
		expect(errorArgText('amount', '12')).toBeNull();
		expect(errorArgText('proceeds', '0xabc')).toBeNull();
	});
});
