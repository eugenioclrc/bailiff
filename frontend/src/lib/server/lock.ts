/**
 * One action at a time: the demo signs with fixed keys, so concurrent sends would race on nonces
 * and a reset could land in the middle of a liquidation.
 */
let holder: string | null = null;

export function tryAcquire(label: string): (() => void) | null {
	if (holder !== null) return null;
	holder = label;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		holder = null;
	};
}

export function currentHolder(): string | null {
	return holder;
}
