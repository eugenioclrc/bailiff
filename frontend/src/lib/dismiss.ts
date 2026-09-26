/**
 * Closes a <details> overlay on Escape, when focus leaves it and on a pointer press outside it, so
 * an opened overlay never outlives the reader's attention and keeps covering the figures under it.
 * A click on plain text moves focus to no element, which is why the pointer press is watched too.
 *
 * Only an overlay (content positioned absolutely, as at the demo width) closes on its own. Content
 * in the page flow covers nothing, and closing it on a press would collapse it under the finger and
 * move the button being tapped, so the tap lands elsewhere; it closes on Escape or its summary.
 * Used as an attachment: {@attach dismissable}.
 */
export function dismissable(details: HTMLDetailsElement): () => void {
	const shut = () => {
		details.open = false;
	};

	const isOverlay = () => {
		const content = details.querySelector(':scope > :not(summary)');
		return content instanceof HTMLElement && getComputedStyle(content).position === 'absolute';
	};

	const onKeyDown = (event: KeyboardEvent) => {
		if (event.key !== 'Escape' || !details.open) return;
		event.preventDefault();
		shut();
	};

	const onFocusOut = (event: FocusEvent) => {
		const next = event.relatedTarget;
		if (next instanceof Node && !details.contains(next) && isOverlay()) shut();
	};

	const onPointerDown = (event: PointerEvent) => {
		if (!details.open || !isOverlay()) return;
		if (event.target instanceof Node && details.contains(event.target)) return;
		shut();
	};

	details.addEventListener('keydown', onKeyDown);
	details.addEventListener('focusout', onFocusOut);
	document.addEventListener('pointerdown', onPointerDown);
	return () => {
		details.removeEventListener('keydown', onKeyDown);
		details.removeEventListener('focusout', onFocusOut);
		document.removeEventListener('pointerdown', onPointerDown);
	};
}
