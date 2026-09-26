/**
 * Closes a <details> overlay on Escape, when focus leaves it and on a pointer press outside it, so
 * an opened overlay never outlives the reader's attention and keeps covering the figures under it.
 * A click on plain text moves focus to no element, which is why the pointer press is watched too.
 * Used as an attachment: {@attach dismissable}.
 */
export function dismissable(details: HTMLDetailsElement): () => void {
	const shut = () => {
		details.open = false;
	};

	const onKeyDown = (event: KeyboardEvent) => {
		if (event.key !== 'Escape' || !details.open) return;
		event.preventDefault();
		shut();
	};

	const onFocusOut = (event: FocusEvent) => {
		const next = event.relatedTarget;
		if (next instanceof Node && !details.contains(next)) shut();
	};

	const onPointerDown = (event: PointerEvent) => {
		if (!details.open) return;
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
