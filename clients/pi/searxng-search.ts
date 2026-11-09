// searxng_search tool for Pi, backed by this repo's SearXNG (no API key, nothing leaves the stack
// except SearXNG's own engine queries). Port of clients/dsh/searxng-search.mjs.
// Endpoint: $SEARXNG_URL, else http://127.0.0.1:8889 (SearXNG's local port on the Studio).
// Install: copy to ~/.pi/agent/extensions/ on the machine that runs Pi.
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BASE_URL = (process.env.SEARXNG_URL ?? "http://127.0.0.1:8889").replace(/\/+$/, "");

const searxngSearch = defineTool({
	name: "searxng_search",
	label: "Web search",
	description:
		"Search the web through the local SearXNG metasearch engine. Returns titles, URLs and snippets. " +
		"Use it for current information, docs and anything outside the codebase; fetch a page with curl when the snippet is not enough.",
	parameters: Type.Object({
		query: Type.String({ description: "The search query." }),
		max_results: Type.Optional(Type.Integer({ minimum: 1, maximum: 30, description: "How many results. Default 8." })),
		time_range: Type.Optional(Type.Union([Type.Literal("day"), Type.Literal("month"), Type.Literal("year")], { description: "Only results from this period." })),
	}),
	async execute(_id, a, signal) {
		const params = new URLSearchParams({ q: a.query, format: "json", ...(a.time_range && { time_range: a.time_range }) });
		let response: Response;
		try {
			response = await fetch(`${BASE_URL}/search?${params}`, { signal, headers: { accept: "application/json" } });
		} catch (error: any) {
			if (signal?.aborted) throw error;
			throw new Error(`SearXNG unreachable at ${BASE_URL} (is the stack up? ~/studio-stack.sh status): ${error?.message ?? error}`);
		}
		if (!response.ok) throw new Error(`SearXNG returned HTTP ${response.status}`);
		const data: any = await response.json();
		const max = a.max_results ?? 8;
		const seen = new Set<string>();
		const lines: string[] = [];
		for (const r of data.results ?? []) {
			if (!r.url || seen.has(r.url)) continue;
			seen.add(r.url);
			lines.push(`${seen.size}. ${r.title ?? r.url}\n   ${r.url}${r.publishedDate ? ` (${r.publishedDate})` : ""}${r.content ? `\n   ${r.content}` : ""}`);
			if (seen.size >= max) break;
		}
		const answers = (data.answers ?? []).map((x: any) => (typeof x === "string" ? x : x?.answer)).filter(Boolean);
		const text = (answers.length ? `Answer: ${answers.join("\n")}\n\n` : "") + (lines.length ? lines.join("\n") : `No results for "${a.query}".`);
		return { content: [{ type: "text" as const, text }], details: { count: lines.length } };
	},
});

export default function (pi: ExtensionAPI) {
	pi.registerTool(searxngSearch);
}
