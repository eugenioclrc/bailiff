/**
 * Builds src/lib/abis.generated.ts from the Foundry artifacts in ../contracts/out.
 * Run with `bun run abis`. Output is deterministic, so running it twice gives the same file.
 *
 * Each exported contract ABI merges the deployed implementation with its spec interface
 * (test/finalspec/SpecInterfaces.sol) by signature: the implementation entry wins, the spec adds
 * the getters, events and errors the humans have not implemented yet.
 */
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keccak256, toBytes, toEventSelector, toFunctionSelector } from 'viem';

type AbiParam = { name?: string; type: string; indexed?: boolean; components?: AbiParam[] };
type AbiEntry = {
	type: string;
	name?: string;
	inputs?: AbiParam[];
	outputs?: AbiParam[];
	stateMutability?: string;
	anonymous?: boolean;
};
type Artifact = {
	abi: AbiEntry[];
	metadata?: {
		settings?: { compilationTarget?: Record<string, string> };
		sources?: Record<string, { keccak256?: string }>;
	};
};

const HERE = dirname(fileURLToPath(import.meta.url));
const FRONTEND = resolve(HERE, '..');
const CONTRACTS = resolve(FRONTEND, '../contracts');
const OUT = join(CONTRACTS, 'out');
const TARGET = join(FRONTEND, 'src/lib/abis.generated.ts');

/** Artifacts compiled from this repo's own sources: their source hash must match the file on disk. */
const OWN = {
	MiniLend: 'MiniLend.sol/MiniLend.json',
	LiquidationAdapter: 'LiquidationAdapter.sol/LiquidationAdapter.json',
	MockRWA3643: 'MockRWA3643.sol/MockRWA3643.json',
	LiquidityDesk: 'LiquidityDesk.sol/LiquidityDesk.json',
	BountyMath: 'BountyMath.sol/BountyMath.json',
	'MiniLend (spec)': 'SpecInterfaces.sol/ISpecMiniLend.json',
	'LiquidationAdapter (spec)': 'SpecInterfaces.sol/ISpecLiquidationAdapter.json',
	'MockUSDC (spec)': 'SpecInterfaces.sol/ISpecMockUSDC.json'
} as const;

/** Uniswap Labs and OpenZeppelin artifacts built from the pinned lib/ submodules. */
const LIB = {
	PoolManager: 'PoolManager.sol/PoolManager.json',
	PermissionedHooks: 'PermissionedHooks.sol/PermissionedHooks.json',
	PermissionsAdapter: 'PermissionsAdapter.sol/PermissionsAdapter.json',
	PermissionsAdapterFactory: 'PermissionsAdapterFactory.sol/PermissionsAdapterFactory.json',
	StateView: 'IStateView.sol/IStateView.json',
	CustomRevert: 'CustomRevert.sol/CustomRevert.json',
	Hooks: 'Hooks.sol/Hooks.json',
	Pool: 'Pool.sol/Pool.json',
	CurrencyLibrary: 'Currency.sol/CurrencyLibrary.json',
	TickMath: 'TickMath.sol/TickMath.json',
	SafeCast: 'SafeCast.sol/SafeCast.json',
	LPFeeLibrary: 'LPFeeLibrary.sol/LPFeeLibrary.json',
	IERC20Errors: 'draft-IERC6093.sol/IERC20Errors.json',
	SafeERC20: 'SafeERC20.sol/SafeERC20.json',
	ReentrancyGuard: 'ReentrancyGuard.sol/ReentrancyGuard.json',
	Math: 'Math.sol/Math.json'
} as const;

type Label = keyof typeof OWN | keyof typeof LIB;

/** Exported ABI name -> labels merged into it, implementation before spec. */
const CONTRACT_ABIS: Record<string, Label[]> = {
	miniLendAbi: ['MiniLend', 'MiniLend (spec)', 'SafeERC20', 'ReentrancyGuard', 'Math'],
	adapterAbi: ['LiquidationAdapter', 'LiquidationAdapter (spec)', 'BountyMath', 'SafeERC20'],
	rwaAbi: ['MockRWA3643'],
	usdcAbi: ['MockUSDC (spec)', 'IERC20Errors'],
	deskAbi: ['LiquidityDesk', 'SafeERC20'],
	paAbi: ['PermissionsAdapter'],
	factoryAbi: ['PermissionsAdapterFactory'],
	poolManagerAbi: [
		'PoolManager',
		'CustomRevert',
		'Hooks',
		'Pool',
		'CurrencyLibrary',
		'TickMath',
		'SafeCast',
		'LPFeeLibrary'
	],
	hookAbi: ['PermissionedHooks'],
	stateViewAbi: ['StateView']
};

function canonicalType(param: AbiParam): string {
	if (!param.type.startsWith('tuple')) return param.type;
	const inner = (param.components ?? []).map(canonicalType).join(',');
	return `(${inner})${param.type.slice('tuple'.length)}`;
}

function signature(entry: AbiEntry): string {
	return `${entry.name ?? ''}(${(entry.inputs ?? []).map(canonicalType).join(',')})`;
}

/** Events with the same signature but a different indexed layout are different events. */
function mergeKey(entry: AbiEntry): string {
	const indexed =
		entry.type === 'event' ? (entry.inputs ?? []).map((p) => (p.indexed ? 'i' : '-')).join('') : '';
	return `${entry.type}:${signature(entry)}:${indexed}`;
}

const TYPE_ORDER = ['constructor', 'function', 'event', 'error', 'fallback', 'receive'];

function sortEntries(entries: AbiEntry[]): AbiEntry[] {
	return [...entries].sort((a, b) => {
		const byType = TYPE_ORDER.indexOf(a.type) - TYPE_ORDER.indexOf(b.type);
		return byType !== 0 ? byType : mergeKey(a).localeCompare(mergeKey(b));
	});
}

async function loadArtifact(path: string): Promise<Artifact> {
	const full = join(OUT, path);
	try {
		return JSON.parse(await readFile(full, 'utf8')) as Artifact;
	} catch (cause) {
		throw new Error(`cannot read ${full}; run \`forge build\` in contracts/ before this script`, {
			cause
		});
	}
}

/** Fails when an own artifact was compiled from a different source than the file on disk. */
async function assertFresh(label: string, artifact: Artifact): Promise<void> {
	const targets = Object.keys(artifact.metadata?.settings?.compilationTarget ?? {});
	if (targets.length !== 1) throw new Error(`${label}: artifact has no single compilation target`);
	const source = targets[0];
	const expected = artifact.metadata?.sources?.[source]?.keccak256;
	const actual = keccak256(toBytes(await readFile(join(CONTRACTS, source), 'utf8')));
	if (expected !== actual) {
		throw new Error(
			`${label}: contracts/out is stale for ${source}; run \`forge build\` in contracts/`
		);
	}
}

function merge(artifacts: Map<Label, Artifact>, labels: Label[]): AbiEntry[] {
	const merged = new Map<string, AbiEntry>();
	for (const label of labels) {
		for (const entry of artifacts.get(label)?.abi ?? []) {
			if (entry.type === 'constructor') continue;
			const key = mergeKey(entry);
			if (!merged.has(key)) merged.set(key, entry);
		}
	}
	return sortEntries([...merged.values()]);
}

function errorIndex(artifacts: Map<Label, Artifact>) {
	const errors = new Map<string, AbiEntry>();
	const sources = new Map<string, Set<string>>();
	for (const [label, artifact] of artifacts) {
		for (const entry of artifact.abi.filter((e) => e.type === 'error')) {
			const sig = signature(entry);
			if (!errors.has(sig)) errors.set(sig, entry);
			const selector = toFunctionSelector(sig);
			sources.set(selector, (sources.get(selector) ?? new Set()).add(label));
		}
	}
	const errorSources = Object.fromEntries(
		[...sources.entries()]
			.sort(([a], [b]) => a.localeCompare(b))
			.map(([selector, labels]) => [selector, [...labels].sort()])
	);
	return { errorsAbi: sortEntries([...errors.values()]), errorSources };
}

/** Function selector -> "Contract.fn(types)", used to name the call inside a WrappedError. */
function functionIndex(artifacts: Map<Label, Artifact>): Record<string, string> {
	const names = new Map<string, string>();
	for (const [label, artifact] of artifacts) {
		for (const entry of artifact.abi.filter((e) => e.type === 'function')) {
			const selector = toFunctionSelector(signature(entry));
			if (!names.has(selector)) names.set(selector, `${label}.${signature(entry)}`);
		}
	}
	return Object.fromEntries([...names.entries()].sort(([a], [b]) => a.localeCompare(b)));
}

/** Spec getters/functions the deployed implementation does not have yet. */
function specOnly(artifacts: Map<Label, Artifact>): string[] {
	const pairs: [Label, Label][] = [
		['MiniLend', 'MiniLend (spec)'],
		['LiquidationAdapter', 'LiquidationAdapter (spec)']
	];
	const missing = new Set<string>();
	for (const [impl, spec] of pairs) {
		const have = new Set(
			(artifacts.get(impl)?.abi ?? []).filter((e) => e.type === 'function').map(signature)
		);
		for (const entry of artifacts.get(spec)?.abi ?? []) {
			if (entry.type === 'function' && !have.has(signature(entry))) {
				missing.add(toFunctionSelector(signature(entry)) + ' ' + signature(entry));
			}
		}
	}
	return [...missing].sort();
}

function eventTopics(abis: Record<string, AbiEntry[]>): Record<string, string> {
	const topics = new Map<string, string>();
	for (const entries of Object.values(abis)) {
		for (const entry of entries.filter((e) => e.type === 'event')) {
			topics.set(toEventSelector(signature(entry)), signature(entry));
		}
	}
	return Object.fromEntries([...topics.entries()].sort(([a], [b]) => a.localeCompare(b)));
}

function render(name: string, value: unknown, asConst = true): string {
	return `export const ${name} = ${JSON.stringify(value, null, '\t')}${asConst ? ' as const' : ''};\n`;
}

async function main(): Promise<void> {
	const artifacts = new Map<Label, Artifact>();
	for (const [label, path] of Object.entries(OWN) as [Label, string][]) {
		const artifact = await loadArtifact(path);
		await assertFresh(label, artifact);
		artifacts.set(label, artifact);
	}
	for (const [label, path] of Object.entries(LIB) as [Label, string][]) {
		artifacts.set(label, await loadArtifact(path));
	}

	const abis = Object.fromEntries(
		Object.entries(CONTRACT_ABIS).map(([name, labels]) => [name, merge(artifacts, labels)])
	);
	const { errorsAbi, errorSources } = errorIndex(artifacts);
	const sources = [...Object.entries(OWN), ...Object.entries(LIB)]
		.map(([label, path]) => ` *   ${label}: contracts/out/${path}`)
		.join('\n');

	const body = [
		'// generated by scripts/abis.ts — do not edit',
		'/**',
		' * Regenerate with `bun run abis` after `forge build` in contracts/.',
		' * Sources:',
		sources,
		' */',
		'',
		...Object.entries(abis).map(([name, abi]) => render(name, abi)),
		'/** Every known error, merged by signature. */',
		render('errorsAbi', errorsAbi),
		'/** Error selector -> contracts that declare it. */',
		`export const errorSources: Readonly<Record<string, readonly string[]>> = ${JSON.stringify(errorSources, null, '\t')};\n`,
		'/** Function selector -> declaring contract and signature. */',
		`export const functionNames: Readonly<Record<string, string>> = ${JSON.stringify(functionIndex(artifacts), null, '\t')};\n`,
		'/** Event topic0 -> signature, across the contract ABIs above. */',
		`export const eventSignatures: Readonly<Record<string, string>> = ${JSON.stringify(eventTopics(abis), null, '\t')};\n`,
		'/** "selector signature" of spec functions the deployed snapshot does not implement yet. */',
		render('specOnlyFunctions', specOnly(artifacts))
	].join('\n');

	await writeFile(TARGET, body);
	console.log(`abis: wrote ${TARGET}`);
}

main().catch((err: unknown) => {
	console.error(`abis: ${err instanceof Error ? err.message : String(err)}`);
	process.exit(1);
});
