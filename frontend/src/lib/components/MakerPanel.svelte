<script lang="ts">
	import type { Demo } from '$lib/demo.svelte';
	import { formatLiquidity, formatUnit } from '$lib/format';
	import { holderOf, showBool, showFlags, showRead, type Shown } from '$lib/view';
	import ActionButton from './ActionButton.svelte';
	import Figure from './Figure.svelte';
	import Panel from './Panel.svelte';

	let { demo }: { demo: Demo } = $props();

	let s = $derived(demo.state);
	let liquidity = $derived.by((): Shown => {
		const read = s?.pool.liquidity;
		return read?.ok
			? { text: formatLiquidity(BigInt(read.value)), tone: 'value' }
			: showRead(read, 'raw');
	});
	let depthRwa = $derived.by((): Shown =>
		s?.pool.virtualRwa
			? { text: formatUnit(s.pool.virtualRwa, 'rwa', 0), tone: 'value' }
			: { text: 'read failed', tone: 'failed' }
	);
	let depthUsdc = $derived.by((): Shown =>
		s?.pool.virtualUsdc
			? { text: formatUnit(s.pool.virtualUsdc, 'usdc', 0), tone: 'value' }
			: { text: 'read failed', tone: 'failed' }
	);
</script>

<Panel
	title="Market maker"
	address={s?.addresses.mm}
	blurb="Team-run and KYC'd; the only LP. All pool liquidity is its own."
	loaded={s !== null}
	failed={demo.loadError !== null}
>
	<Figure
		label="Pool liquidity L"
		shown={liquidity}
		detail={s?.pool.liquidity.ok ? s.pool.liquidity.value : undefined}
	/>
	<Figure label="Virtual depth, RWA side" shown={depthRwa} unit="RWA" />
	<Figure label="Virtual depth, USDC side" shown={depthUsdc} unit="USDC" />
	<Figure label="Checker flags" shown={showFlags(holderOf(s, 'mm')?.flags)} />
	<Figure
		label="Desk as pool wrapper"
		shown={showBool(s?.permissions.deskWrapper, 'allowed', 'revoked')}
	/>

	{#snippet actions()}
		<ActionButton {demo} action="withdraw95" />
	{/snippet}
</Panel>
