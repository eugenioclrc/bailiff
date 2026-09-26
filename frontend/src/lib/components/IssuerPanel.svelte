<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { formatDuration } from '$lib/format';
	import { showBool, showRead } from '$lib/view';
	import ActionButton from './ActionButton.svelte';
	import Figure from './Figure.svelte';
	import Panel from './Panel.svelte';

	let { demo }: { demo: Demo } = $props();

	let s = $derived(demo.state);
	let navNote = $derived.by(() => {
		const age = s?.navStatus.ageSeconds;
		if (!age) return undefined;
		const text = formatDuration(BigInt(age));
		return s?.navStatus.fresh === false ? `stale, set ${text} ago` : `set ${text} ago`;
	});
	let wrapperRevoked = $derived(
		s?.permissions.adapterWrapper.ok === true && !s.permissions.adapterWrapper.value
	);
	let paused = $derived(s?.rwaPaused.ok === true && s.rwaPaused.value);
</script>

<Panel
	title="Issuer"
	address={s?.addresses.issuer}
	blurb="Owns the pool wrapper and the NAV oracle; provides no liquidity."
	loaded={s !== null}
	failed={demo.loadError !== null}
>
	<Figure
		label="NAV, USDC/RWA"
		shown={showRead(s?.market.nav, 'wad')}
		note={navNote}
		state={s?.navStatus.fresh === false ? 'bad' : 'plain'}
	/>
	<Figure
		label="Adapter as pool wrapper"
		shown={showBool(s?.permissions.adapterWrapper, 'allowed', 'revoked')}
		state={wrapperRevoked ? 'bad' : 'good'}
	/>
	<Figure
		label="Canonical hook"
		shown={showBool(s?.permissions.hookAllowed, 'allowed', 'not allowed')}
	/>
	<Figure
		label="Pool swapping"
		shown={showBool(s?.permissions.swappingEnabled, 'enabled', 'disabled')}
	/>
	<Figure
		label="RWA token"
		shown={showBool(s?.rwaPaused, 'paused', 'active')}
		state={paused ? 'bad' : 'plain'}
	/>

	{#snippet actions()}
		<ActionButton {demo} action="crash" />
		<ActionButton {demo} action="revoke" tone="warn" />
	{/snippet}
</Panel>
