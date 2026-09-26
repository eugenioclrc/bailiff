import { describe, expect, test } from 'bun:test';
import {
	ContractFunctionRevertedError,
	HttpRequestError,
	RpcRequestError,
	encodeErrorResult,
	encodeFunctionResult,
	type Abi,
	type Hex
} from 'viem';
import { errorsAbi, miniLendAbi } from '../abis.generated';
import { isRevertError, readMany, revertOf, simulate } from './chain';
import { fakeContext } from './context.test-helpers';

const { ctx } = fakeContext();
const MARKET = ctx.manifest.market;
const healthy = encodeErrorResult({ abi: errorsAbi, errorName: 'Healthy', args: [2n * 10n ** 18n] });
const rpcRevert = (data: Hex) =>
	new RpcRequestError({
		body: { method: 'eth_call' },
		error: { code: 3, message: 'execution reverted', data },
		url: 'http://127.0.0.1:8545'
	});

describe('revert versus transport classification', () => {
	test('a contract revert decodes to its error', () => {
		const err = new ContractFunctionRevertedError({
			abi: errorsAbi as Abi,
			data: healthy,
			functionName: 'liquidate'
		});
		expect(isRevertError(err)).toBe(true);
		expect(revertOf(ctx, err, MARKET)?.name).toBe('Healthy');
	});

	test('an RPC error with code 3 is a revert', () => {
		const err = rpcRevert(healthy);
		expect(isRevertError(err)).toBe(true);
		const revert = revertOf(ctx, err, MARKET);
		expect(revert?.name).toBe('Healthy');
		expect(revert?.layers[0].target?.label).toBe('market');
	});

	test('a transport failure is not a revert', () => {
		const err = new HttpRequestError({ url: 'http://127.0.0.1:8545' });
		expect(isRevertError(err)).toBe(false);
		expect(revertOf(ctx, err, MARKET)).toBeNull();
		expect(isRevertError(new Error('boom'))).toBe(false);
	});
});

describe('simulate', () => {
	test('returns the call data on success, on the pending block by default', async () => {
		const fake = fakeContext({ call: async () => ({ data: '0x1234' }) });
		const outcome = await simulate(fake.ctx, fake.ctx.manifest.keeper, MARKET, '0x');
		expect(outcome).toEqual({ ok: true, data: '0x1234' });
		expect(fake.calls[0]).toMatchObject({ blockTag: 'pending', account: fake.ctx.manifest.keeper });
	});

	test('a revert becomes a decoded outcome, a transport error is rethrown', async () => {
		const reverting = fakeContext({ call: () => Promise.reject(rpcRevert(healthy)) });
		const outcome = await simulate(reverting.ctx, reverting.ctx.manifest.keeper, MARKET, '0x');
		expect(outcome.ok).toBe(false);
		const down = fakeContext({
			call: () => Promise.reject(new HttpRequestError({ url: 'http://127.0.0.1:8545' }))
		});
		await expect(simulate(down.ctx, down.ctx.manifest.keeper, MARKET, '0x')).rejects.toThrow();
	});
});

describe('readMany', () => {
	const calls = [
		{ key: 'nav', address: MARKET, abi: miniLendAbi as Abi, functionName: 'nav' },
		{
			key: 'claim',
			address: MARKET,
			abi: miniLendAbi as Abi,
			functionName: 'claimableResidual',
			args: [ctx.manifest.borrower]
		},
		{
			key: 'hf',
			address: MARKET,
			abi: miniLendAbi as Abi,
			functionName: 'healthFactor',
			args: [ctx.manifest.borrower]
		}
	];

	test('decodes successes, marks missing spec getters and keeps real reverts', async () => {
		const nav = encodeFunctionResult({
			abi: miniLendAbi as Abi,
			functionName: 'nav',
			result: 85n * 10n ** 18n
		});
		const fake = fakeContext({
			readContract: async () => [
				{ success: true, returnData: nav },
				{ success: false, returnData: '0x' },
				{ success: false, returnData: healthy }
			]
		});
		const r = await readMany(fake.ctx, calls, 100n);
		expect(r.nav).toEqual({ ok: true, value: 85n * 10n ** 18n });
		expect(r.claim).toMatchObject({ ok: false, notImplemented: true });
		expect(r.hf).toMatchObject({ ok: false, notImplemented: false });
		expect(r.hf.ok ? '' : r.hf.revert.name).toBe('Healthy');
	});

	test('undecodable success data is a failure, never a zero', async () => {
		const fake = fakeContext({
			readContract: async () => calls.map(() => ({ success: true, returnData: '0x' }))
		});
		const r = await readMany(fake.ctx, calls, 100n);
		expect(r.nav.ok).toBe(false);
	});
});
