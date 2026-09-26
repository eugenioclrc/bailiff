import { ACTIONS, type ActionName } from './types';

export const ACTION_LABELS: Record<ActionName, string> = {
	crash: 'Cut NAV to 85',
	horizon: 'Direct liquidation (simulated)',
	liquidateFull: 'Liquidate full position',
	withdraw95: 'Withdraw 95% of liquidity',
	liquidateChunk: 'Liquidate 10,000 USDC',
	revoke: 'Revoke adapter wrapper',
	reset: 'Reset to healthy snapshot'
};

const ACTION_SET: ReadonlySet<string> = new Set(ACTIONS);

export type ParsedAction = { ok: true; action: ActionName } | { ok: false; message: string };

/** The closed O5 body: exactly `{ action }`, with one of the seven known names. */
export function parseActionBody(body: unknown): ParsedAction {
	if (typeof body !== 'object' || body === null || Array.isArray(body)) {
		return { ok: false, message: 'Body must be a JSON object: {"action": "<name>"}.' };
	}
	const keys = Object.keys(body);
	if (keys.length !== 1 || keys[0] !== 'action') {
		return { ok: false, message: 'Body must contain only the "action" key.' };
	}
	const action: unknown = (body as Record<string, unknown>).action;
	if (typeof action !== 'string' || !ACTION_SET.has(action)) {
		return { ok: false, message: `Unknown action. Expected one of: ${ACTIONS.join(', ')}.` };
	}
	return { ok: true, action: action as ActionName };
}

export function isLiquidationAction(action: ActionName): boolean {
	return action === 'horizon' || action === 'liquidateFull' || action === 'liquidateChunk';
}
