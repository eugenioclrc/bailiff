import { describe, expect, test } from 'bun:test';
import {
	RpcRequestError,
	decodeFunctionData,
	encodeErrorResult,
	encodeFunctionResult,
	maxUint256,
	type Hex
} from 'viem';
import { adapterAbi, deskAbi, errorsAbi, miniLendAbi, paAbi } from '../abis.generated';
import { runAction } from './actions';
import { fakeContext, type SimCall } from './context.test-helpers';
import { HttpFailure } from './guards';

const revertWith = (data: Hex) =>
	new RpcRequestError({
		body: { method: 'eth_call' },
		error: { code: 3, message: 'execution reverted', data },
		url: 'http://127.0.0.1:8545'
	});
const bountyOf = (bounty: bigint) =>
	encodeFunctionResult({ abi: adapterAbi, functionName: 'liquidate', result: bounty });
const healthy = encodeErrorResult({
	abi: errorsAbi,
	errorName: 'Healthy',
	args: [1_066_666_666_666_666_666n]
});

function liquidateArgs(call: SimCall | { data: Hex }) {
	return decodeFunctionData({ abi: adapterAbi, data: call.data! }).args as readonly [
		string,
		bigint,
		bigint
	];
}

describe('liquidateFull / liquidateChunk', () => {
	test('a reverting quote returns simulation-reverted and sends nothing', async () => {
		const fake = fakeContext({ call: () => Promise.reject(revertWith(healthy)) });
		const response = await runAction(fake.ctx, 'liquidateFull');
		expect(response.status).toBe('simulation-reverted');
		expect(response.error?.name).toBe('Healthy');
		expect(response.txHash).toBeUndefined();
		expect(fake.sent).toEqual([]);
		expect(fake.calls).toHaveLength(1);
	});

	test('minBounty is floor(97%) of the quote, re-simulated with the exact calldata that is sent', async () => {
		const fake = fakeContext({ call: async () => ({ data: bountyOf(4_500_000_000n) }) });
		const response = await runAction(fake.ctx, 'liquidateFull');
		expect(response.status).toBe('mined');
		expect(response.detail.quote).toEqual({
			repayAssets: maxUint256.toString(),
			bounty: '4500000000',
			minBounty: '4365000000'
		});
		expect(fake.calls).toHaveLength(2);
		const [quoteArgs, checkArgs] = fake.calls.map(liquidateArgs);
		expect(quoteArgs).toEqual([fake.ctx.manifest.borrower, maxUint256, 0n]);
		expect(checkArgs[2]).toBe(4_365_000_000n);
		expect(fake.sent).toHaveLength(1);
		expect(fake.sent[0]).toMatchObject({ role: 'keeper', to: fake.ctx.manifest.adapter });
		expect(fake.sent[0].data).toBe(fake.calls[1].data!);
		expect(fake.calls.every((c) => c.account === fake.ctx.manifest.keeper)).toBe(true);
		expect(response.detail.call).toContain('minBounty 4,365.00 USDC');
	});

	test('floor rounding: a bounty of 1 wei gives minBounty 0', async () => {
		const fake = fakeContext({ call: async () => ({ data: bountyOf(1n) }) });
		const response = await runAction(fake.ctx, 'liquidateChunk');
		expect(response.detail.quote?.minBounty).toBe('0');
		expect(liquidateArgs(fake.sent[0])[1]).toBe(10_000_000_000n);
	});

	test('a failed re-simulation sends nothing', async () => {
		const fake = fakeContext({
			call: (_args, i) =>
				i === 0 ? Promise.resolve({ data: bountyOf(600_000_000n) }) : Promise.reject(revertWith(healthy))
		});
		const response = await runAction(fake.ctx, 'liquidateChunk');
		expect(response.status).toBe('simulation-reverted');
		expect(fake.sent).toEqual([]);
		expect(response.detail.simulations.map((s) => s.ok)).toEqual([true, false]);
	});

	test('a mined liquidation keeps its hash when the reconciliation reads fail', async () => {
		const fake = fakeContext({
			call: async () => ({ data: bountyOf(4_500_000_000n) }),
			readContract: () => Promise.reject(new Error('multicall down'))
		});
		const response = await runAction(fake.ctx, 'liquidateFull');
		expect(response.status).toBe('mined');
		expect(response.txHash).toMatch(/^0x[0-9a-f]{64}$/);
		expect(response.detail.reconciliationError).toContain('block 100');
		expect(response.detail.reconciliation).toBeUndefined();
	});

	test('a revert at gas estimation is a simulation revert, not a mined transaction', async () => {
		const fake = fakeContext({
			call: async () => ({ data: bountyOf(4_500_000_000n) }),
			send: () => Promise.reject(revertWith(healthy))
		});
		const response = await runAction(fake.ctx, 'liquidateFull');
		expect(response.status).toBe('simulation-reverted');
		expect(response.detail.simulations.at(-1)?.label).toBe('Gas estimation before sending');
	});

	test('a status-0 receipt takes its cause from the trace, never from the receipt', async () => {
		const unauthorized = encodeErrorResult({ abi: errorsAbi, errorName: 'Unauthorized' });
		const traced = fakeContext({
			call: async () => ({ data: bountyOf(4_500_000_000n) }),
			receipt: { status: 'reverted' },
			request: async () => ({ output: unauthorized })
		});
		const response = await runAction(traced.ctx, 'liquidateFull');
		expect(response).toMatchObject({ status: 'mined', error: { name: 'Unauthorized' } });
		const untraced = fakeContext({
			call: async () => ({ data: bountyOf(4_500_000_000n) }),
			receipt: { status: 'reverted' },
			request: () => Promise.reject(new Error('no debug api'))
		});
		const plain = await runAction(untraced.ctx, 'liquidateFull');
		expect(plain.error?.name).toBe('TransactionReverted');
		expect(plain.error?.message).toContain('not inferred');
	});

	test('a successful call without return data is an operator error, not a zero bounty', async () => {
		const fake = fakeContext({ call: async () => ({ data: '0x' }) });
		await expect(runAction(fake.ctx, 'liquidateFull')).rejects.toBeInstanceOf(HttpFailure);
		expect(fake.sent).toEqual([]);
	});
});

describe('horizon', () => {
	test('simulates the direct route once from the keeper and never sends', async () => {
		const notAllowlisted = encodeErrorResult({
			abi: errorsAbi,
			errorName: 'NotAllowlisted',
			args: ['0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC']
		});
		const fake = fakeContext({ call: () => Promise.reject(revertWith(notAllowlisted)) });
		const response = await runAction(fake.ctx, 'horizon');
		expect(response.status).toBe('simulation-reverted');
		expect(response.error?.name).toBe('NotAllowlisted');
		expect(response.txHash).toBeUndefined();
		expect(fake.calls).toHaveLength(1);
		expect(fake.calls[0]).toMatchObject({
			account: fake.ctx.manifest.keeper,
			to: fake.ctx.manifest.market
		});
		const { functionName, args } = decodeFunctionData({ abi: miniLendAbi, data: fake.calls[0].data! });
		expect(functionName).toBe('liquidate');
		expect(args).toEqual([fake.ctx.manifest.borrower, maxUint256, '0x']);
		expect(fake.sent).toEqual([]);
	});

	test('a direct route that would succeed is refused, not sent', async () => {
		const fake = fakeContext();
		await expect(runAction(fake.ctx, 'horizon')).rejects.toBeInstanceOf(HttpFailure);
		expect(fake.sent).toEqual([]);
	});
});

describe('signed actions', () => {
	test('crash: setNav(85e18) to the market, signed by the issuer', async () => {
		const fake = fakeContext();
		const response = await runAction(fake.ctx, 'crash');
		expect(response.status).toBe('mined');
		expect(fake.sent[0]).toMatchObject({ role: 'issuer', to: fake.ctx.manifest.market });
		const { functionName, args } = decodeFunctionData({ abi: miniLendAbi, data: fake.sent[0].data });
		expect([functionName, args]).toEqual(['setNav', [85n * 10n ** 18n]]);
	});

	test('withdraw95: removes 4.75e17 of liquidity through the desk, signed by the market maker', async () => {
		const fake = fakeContext();
		await runAction(fake.ctx, 'withdraw95');
		expect(fake.sent[0]).toMatchObject({ role: 'mm', to: fake.ctx.manifest.desk });
		const { functionName, args } = decodeFunctionData({ abi: deskAbi, data: fake.sent[0].data });
		expect(functionName).toBe('modifyLiquidity');
		expect(args?.slice(1)).toEqual([-887220, 887220, -475_000_000_000_000_000n]);
	});

	test('revoke: only updateAllowedWrapper(adapter, false) on the PA, signed by the issuer', async () => {
		const fake = fakeContext();
		await runAction(fake.ctx, 'revoke');
		expect(fake.sent[0]).toMatchObject({ role: 'issuer', to: fake.ctx.manifest.pa });
		const { functionName, args } = decodeFunctionData({ abi: paAbi, data: fake.sent[0].data });
		expect([functionName, args]).toEqual([
			'updateAllowedWrapper',
			[fake.ctx.manifest.adapter, false]
		]);
	});

	test('a signed action whose simulation reverts is not sent', async () => {
		const fake = fakeContext({ call: () => Promise.reject(revertWith(healthy)) });
		const response = await runAction(fake.ctx, 'crash');
		expect(response.status).toBe('simulation-reverted');
		expect(fake.sent).toEqual([]);
	});
});
