import { describe, expect, test } from 'bun:test';
import {
	encodeAbiParameters,
	encodeErrorResult,
	parseAbi,
	slice,
	toFunctionSelector,
	type Hex
} from 'viem';
import { errorsAbi } from './abis.generated';
import { decodeRevert, extractRevertData, type DecodeContext } from './errors';

const HOOK = '0x51247E2291d290d17C08813A175AC86465EdE8c0';
const PM = '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543';
const KEEPER = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC';
const ADAPTER = '0x0457329C4AB669D6eB6F4a9ad5E90Ab8551174C6';
const MARKET = '0x1111111111111111111111111111111111111111';

const ctx: DecodeContext = {
	labels: {
		[HOOK.toLowerCase()]: 'hook',
		[PM.toLowerCase()]: 'PoolManager',
		[KEEPER.toLowerCase()]: 'keeper',
		[ADAPTER.toLowerCase()]: 'adapter',
		[MARKET.toLowerCase()]: 'market'
	}
};

const BEFORE_SWAP = toFunctionSelector(
	'beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)'
);
const HOOK_CALL_FAILED = toFunctionSelector('HookCallFailed()');

function wrapped(target: string, selector: Hex, reason: Hex, context: Hex): Hex {
	return encodeErrorResult({
		abi: errorsAbi,
		errorName: 'WrappedError',
		args: [target as Hex, selector, reason, context]
	});
}

const unauthorized = encodeErrorResult({ abi: errorsAbi, errorName: 'Unauthorized' });

describe('decodeRevert', () => {
	test('names a direct error and labels its address argument', () => {
		const data = encodeErrorResult({ abi: errorsAbi, errorName: 'NotAllowlisted', args: [KEEPER] });
		const decoded = decodeRevert(data, ctx);
		expect(decoded.name).toBe('NotAllowlisted');
		expect(decoded.layers).toHaveLength(1);
		expect(decoded.layers[0].args[0]).toMatchObject({ name: 'to', value: KEEPER, label: 'keeper' });
		expect(decoded.layers[0].declaredBy).toContain('MockRWA3643');
		expect(decoded.message).toContain('NotAllowlisted');
		expect(decoded.message).toContain('keeper');
	});

	test('unwraps a hook WrappedError down to the hook cause', () => {
		const data = wrapped(HOOK, BEFORE_SWAP, unauthorized, HOOK_CALL_FAILED);
		const decoded = decodeRevert(data, ctx);
		expect(decoded.name).toBe('Unauthorized');
		expect(decoded.layers.map((l) => l.kind)).toEqual(['wrapped', 'known']);
		expect(decoded.layers[0].call).toContain('beforeSwap');
		expect(decoded.layers[0].context).toBe('HookCallFailed()');
		expect(decoded.layers[1].target).toEqual({ address: HOOK, label: 'hook' });
		expect(decoded.layers[1].declaredBy).toContain('PermissionedHooks');
		expect(decoded.message).toContain('hook');
		expect(decoded.message).toContain('beforeSwap');
	});

	test('recurses through nested wrappers', () => {
		const inner = wrapped(HOOK, BEFORE_SWAP, unauthorized, HOOK_CALL_FAILED);
		const outer = wrapped(PM, toFunctionSelector('unlock(bytes)'), inner, HOOK_CALL_FAILED);
		const decoded = decodeRevert(outer, ctx);
		expect(decoded.name).toBe('Unauthorized');
		expect(decoded.layers.map((l) => l.kind)).toEqual(['wrapped', 'wrapped', 'known']);
		expect(decoded.layers[2].target?.label).toBe('hook');
	});

	test('keeps target and selector of an unknown error', () => {
		const data =
			'0xdeadbeef0000000000000000000000000000000000000000000000000000000000000001' as Hex;
		const decoded = decodeRevert(data, ctx, ADAPTER);
		expect(decoded.name).toBe('UnknownError');
		expect(decoded.layers[0]).toMatchObject({ kind: 'unknown', selector: '0xdeadbeef', raw: data });
		expect(decoded.layers[0].target).toEqual({ address: ADAPTER, label: 'adapter' });
		expect(decoded.message).toContain('0xdeadbeef');
	});

	test('an unknown reason inside a wrapper keeps the wrapped target', () => {
		const data = wrapped(HOOK, BEFORE_SWAP, '0x12345678', HOOK_CALL_FAILED);
		const decoded = decodeRevert(data, ctx);
		expect(decoded.name).toBe('UnknownError');
		expect(decoded.layers[1]).toMatchObject({ kind: 'unknown', selector: '0x12345678' });
		expect(decoded.layers[1].target?.label).toBe('hook');
	});

	test('empty revert data is reported as such', () => {
		for (const data of ['0x', undefined] as const) {
			const decoded = decodeRevert(data, ctx);
			expect(decoded.name).toBe('EmptyRevert');
			expect(decoded.layers[0].kind).toBe('empty');
		}
	});

	test('decodes Error(string) and Panic(uint256)', () => {
		const abi = parseAbi(['error Error(string)', 'error Panic(uint256)']);
		const message = decodeRevert(
			encodeErrorResult({ abi, errorName: 'Error', args: ['nope'] }),
			ctx
		);
		expect(message.name).toBe('Error');
		expect(message.message).toContain('nope');
		const panic = decodeRevert(encodeErrorResult({ abi, errorName: 'Panic', args: [0x11n] }), ctx);
		expect(panic.name).toBe('Panic');
		expect(panic.message).toContain('overflow');
	});

	test('decodes numeric arguments as decimal strings', () => {
		const data = encodeErrorResult({
			abi: errorsAbi,
			errorName: 'InsufficientProceeds',
			args: [67_000_000_000n, 75_000_000_000n]
		});
		const decoded = decodeRevert(data, ctx);
		expect(decoded.name).toBe('InsufficientProceeds');
		expect(decoded.layers[0].args.map((a) => a.value)).toEqual(['67000000000', '75000000000']);
	});

	test('a selector shorter than four bytes is unknown, not a crash', () => {
		expect(decodeRevert('0x1234', ctx).name).toBe('UnknownError');
	});

	test('a wrapper whose details carry an unknown selector keeps that selector as context', () => {
		const decoded = decodeRevert(wrapped(HOOK, BEFORE_SWAP, unauthorized, '0xdeadbeef'), ctx);
		expect(decoded.layers[0].context).toBe('0xdeadbeef');
		expect(decoded.name).toBe('Unauthorized');
	});

	test('a known selector with a truncated payload is unknown and still names its declarers', () => {
		const full = encodeErrorResult({
			abi: errorsAbi,
			errorName: 'InsufficientProceeds',
			args: [1n, 2n]
		});
		const decoded = decodeRevert(slice(full, 0, 4), ctx, ADAPTER);
		expect(decoded.name).toBe('UnknownError');
		expect(decoded.layers[0].selector).toBe(slice(full, 0, 4));
		expect(decoded.layers[0].declaredBy).toEqual(['LiquidationAdapter']);
	});

	test('a WrappedError with an empty reason ends in EmptyRevert', () => {
		const decoded = decodeRevert(wrapped(HOOK, BEFORE_SWAP, '0x', HOOK_CALL_FAILED), ctx);
		expect(decoded.name).toBe('EmptyRevert');
		expect(decoded.layers.map((l) => l.kind)).toEqual(['wrapped', 'empty']);
	});

	test('a WrappedError with empty details says so instead of printing 0x', () => {
		const decoded = decodeRevert(wrapped(HOOK, BEFORE_SWAP, unauthorized, '0x'), ctx);
		expect(decoded.name).toBe('Unauthorized');
		expect(decoded.layers[0].context).toBe('no details');
		expect(decoded.message).toContain('wrapped as no details');
		expect(decoded.message).not.toContain('wrapped as 0x');
	});

	test('nesting deeper than eight wrappers is cut off and marked, not decoded forever', () => {
		let data: Hex = unauthorized;
		for (let i = 0; i < 10; i += 1) data = wrapped(HOOK, BEFORE_SWAP, data, HOOK_CALL_FAILED);
		const decoded = decodeRevert(data, ctx);
		expect(decoded.layers).toHaveLength(9);
		const last = decoded.layers[8];
		expect(last.kind).toBe('wrapped');
		expect(last.truncated).toBe(true);
		expect(last.raw).toBeDefined();
		expect(decoded.name).toBe('WrappedError');
		expect(decoded.message).toContain('not decoded');
	});

	test('a known raising contract that declares the error is the only declarer named', () => {
		const decoded = decodeRevert(wrapped(HOOK, BEFORE_SWAP, unauthorized, HOOK_CALL_FAILED), ctx);
		expect(decoded.layers[1].declaredBy).toEqual(['PermissionedHooks']);
		expect(decoded.message).toContain('[declared by PermissionedHooks]');
		expect(decoded.message).not.toContain('LiquidationAdapter');
		const healthy = encodeErrorResult({ abi: errorsAbi, errorName: 'Healthy', args: [10n ** 18n] });
		expect(decodeRevert(healthy, ctx, MARKET).layers[0].declaredBy).toEqual(['MiniLend']);
	});

	test('without a known raiser, spec-only declarers are marked as not deployed', () => {
		expect(decodeRevert(unauthorized, ctx).layers[0].declaredBy).toEqual([
			'LiquidationAdapter (spec ABI, not deployed)',
			'PermissionedHooks'
		]);
		const blocked = encodeErrorResult({
			abi: errorsAbi,
			errorName: 'LiquidationBlocked',
			args: [KEEPER]
		});
		expect(decodeRevert(blocked, ctx).layers[0].declaredBy).toEqual([
			'MiniLend (spec ABI, not deployed)'
		]);
	});

	test('a spec copy of a deployed declarer is not listed twice', () => {
		const healthy = encodeErrorResult({ abi: errorsAbi, errorName: 'Healthy', args: [1n] });
		expect(decodeRevert(healthy, ctx).layers[0].declaredBy).toEqual(['MiniLend']);
	});

	test('the message shows token amounts in token units, the layer keeps raw values', () => {
		const data = encodeErrorResult({
			abi: errorsAbi,
			errorName: 'InsufficientProceeds',
			args: [67_916_346_056n, 75_000_000_000n]
		});
		const decoded = decodeRevert(data, ctx);
		expect(decoded.message).toContain('proceeds=67,916.35 USDC');
		expect(decoded.message).toContain('repaid=75,000.00 USDC');
		expect(decoded.layers[0].args[0].value).toBe('67916346056');
		const partial = decodeRevert(
			encodeErrorResult({
				abi: errorsAbi,
				errorName: 'PartialFill',
				args: [935_294_117_647_058_823_529n, 1_000n * 10n ** 18n]
			}),
			ctx
		);
		expect(partial.message).toContain('sold=935.2941 RWA');
		const healthy = decodeRevert(
			encodeErrorResult({
				abi: errorsAbi,
				errorName: 'Healthy',
				args: [1_066_666_666_666_666_666n]
			}),
			ctx
		);
		expect(healthy.message).toContain('hf=1.0667');
	});
});

describe('extractRevertData', () => {
	test('finds hex data on a nested cause', () => {
		const data = encodeAbiParameters([{ type: 'uint256' }], [1n]);
		const err = { cause: { cause: { data } } };
		expect(extractRevertData(err)).toBe(data);
	});

	test('reads data wrapped in an object', () => {
		expect(extractRevertData({ cause: { data: { data: '0xabcdef01' } } })).toBe('0xabcdef01');
	});

	test('returns undefined without revert data', () => {
		expect(extractRevertData(new Error('fetch failed'))).toBeUndefined();
		expect(extractRevertData({ data: 'not hex' })).toBeUndefined();
	});
});
