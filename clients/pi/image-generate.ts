// Image tools for Pi, backed by this repo's image-server (Qwen-Image 2.1 via mflux).
// Port of clients/dsh/image-generate.mjs:
//
//   generate_image  text-to-image; transparent (RGBA) output; or a variation of
//                   an existing image (init_image + strength)
//   edit_image      instruction edits over 1-10 images: change, restyle or combine them
//
// Results are saved under the session's cwd as generated-images/<YYYY-MM-DD>/<theme>/<title>.png
// (or `filename`). Input and output paths must stay inside the cwd.
// Endpoint: $IMAGE_SERVER_URL, else http://127.0.0.1:8890 (the image-server's loopback port on the Studio).
// Install: copy to ~/.pi/agent/extensions/ on the machine that runs Pi.
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BASE_URL = (process.env.IMAGE_SERVER_URL ?? "http://127.0.0.1:8890").replace(/\/+$/, "");
// The server needs multiples of 32.
const SIZES = ["512x512", "768x768", "1024x1024", "1024x768", "768x1024", "1344x768", "768x1344", "1536x1024", "1024x1536"];
const DETAIL: Record<string, number> = { low: 512, medium: 768, high: 1024 };
const INPUT_TYPES: Record<string, string> = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp" };
const MAX_INPUT_BYTES = 25 * 1024 * 1024;

const slug = (text: string, max = 40) =>
	text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, max).replace(/-+$/, "") || "image";

function localDate() {
	const d = new Date();
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// Resolve a path inside the workspace; refuse anything that escapes it.
function inside(workspace: string, path: string, what: string) {
	const target = isAbsolute(path) ? path : resolve(workspace, normalize(path));
	const back = relative(workspace, target);
	if (back.startsWith("..") || isAbsolute(back) || back.split(sep).includes("..")) throw new Error(`${what} must stay inside ${workspace}`);
	return target;
}

// `filename` if given, else generated-images/<date>/<theme>/<title>.png, never overwriting (-2, -3, ...).
async function outputPath(workspace: string, p: { filename?: string; theme?: string; title?: string; prompt: string }) {
	if (p.filename) {
		let rel = p.filename.trim().replace(/\s*\/\s*/g, "/").replace(/\/+$/, "");
		if (isAbsolute(rel)) throw new Error("filename must be relative to the workspace");
		if (!/\.png$/i.test(rel)) rel += ".png";
		return inside(workspace, rel, "filename");
	}
	const dir = join("generated-images", localDate(), slug(p.theme || "misc"));
	const base = slug(p.title || p.prompt, 60);
	for (let n = 1; ; n++) {
		const target = inside(workspace, join(dir, `${base}${n > 1 ? `-${n}` : ""}.png`), "output path");
		if (!(await stat(target).catch(() => null))) return target;
	}
}

async function readInput(workspace: string, path: string) {
	const file = inside(workspace, path, `image "${path}"`);
	const type = INPUT_TYPES[extname(file).toLowerCase()];
	if (!type) throw new Error(`"${path}" must be a PNG, JPEG or WebP file`);
	const info = await stat(file).catch(() => null);
	if (!info?.isFile()) throw new Error(`"${path}" does not exist`);
	if (info.size > MAX_INPUT_BYTES) throw new Error(`"${path}" is larger than 25 MB`);
	return `data:${type};base64,${(await readFile(file)).toString("base64")}`;
}

// POST to image-server, download the PNG into the workspace, describe the result.
async function run(workspace: string, endpoint: string, body: object, target: string, transparent: boolean, signal?: AbortSignal) {
	let response: Response;
	try {
		response = await fetch(`${BASE_URL}${endpoint}`, {
			method: "POST",
			signal,
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ ...body, transparent, response_format: "url" }),
		});
	} catch (error: any) {
		if (signal?.aborted) throw error;
		throw new Error(`image server unreachable at ${BASE_URL} (is image-server running?): ${error?.message ?? error}`);
	}
	const result: any = await response.json().catch(() => ({}));
	if (!response.ok) {
		const detail = typeof result.detail === "string" ? result.detail : JSON.stringify(result.detail ?? result);
		if (response.status === 503) {
			// This must end with the user, not with the agent freeing memory on a shared machine.
			throw new Error(`image server is out of memory (HTTP 503): ${detail} Report this to the user and wait. Never stop Splash, Ornith or any other process yourself.`);
		}
		throw new Error(`image server returned HTTP ${response.status}: ${detail}`);
	}
	const item = result.data?.[0];
	if (!item?.url) throw new Error("image server response had no image");
	const png = await fetch(item.url, { signal });
	if (!png.ok) throw new Error(`could not download ${item.url}: HTTP ${png.status}`);
	await mkdir(dirname(target), { recursive: true });
	await writeFile(target, new Uint8Array(await png.arrayBuffer()));

	const path = relative(workspace, target) || target;
	const pct = Math.round(100 * (item.transparent_fraction ?? 0));
	const text =
		`Saved a ${item.width}x${item.height}${transparent ? " transparent (RGBA)" : ""} image to ${path} ` +
		`(${result.model ?? "unknown"}${result.lora ? ` + LoRA ${result.lora.name}` : ""}, seed ${item.seed}, ` +
		`${result.steps ?? "?"} steps, ${result.generate_seconds ?? 0}s` +
		(result.load_seconds > 1 ? `, incl. ${result.load_seconds}s model load` : "") + ").\n" +
		(transparent ? `Measured alpha: ${pct}% of pixels fully transparent.\n` : "") +
		`Use the read tool on ${path} to look at it and check it matches the request.`;
	return { content: [{ type: "text" as const, text }], details: { path, seed: item.seed, url: item.url } };
}

const common = {
	model: Type.Optional(Type.Union([Type.Literal("turbo"), Type.Literal("base")], { description: "turbo: 8 fixed steps, fast (~17 s at 1024x1024), drafts. base: 40 steps, better detail, ~5x slower; for finals. Default: server default (base)." })),
	seed: Type.Optional(Type.Integer({ description: "Seed for reproducible output. Omit for random." })),
	transparent: Type.Optional(Type.Boolean({ description: "Transparent-background PNG (stickers, icons, cut-outs). Default false." })),
	negative_prompt: Type.Optional(Type.String({ description: "Things to avoid. Only takes effect with guidance > 1." })),
	guidance: Type.Optional(Type.Number({ minimum: 1, maximum: 10, description: "Classifier-free guidance, 1-10. Default 1." })),
	theme: Type.Optional(Type.String({ description: "Folder for this batch, kebab-case. Images go to generated-images/<today>/<theme>/. Default misc." })),
	title: Type.Optional(Type.String({ description: "Short kebab-case name for the image. Default: from the prompt." })),
	filename: Type.Optional(Type.String({ description: "Explicit output path relative to the cwd, overriding theme/title." })),
	lora: Type.Optional(Type.String({ pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$", description: "LoRA name (character or style). Put its trigger phrase in the prompt. An unknown name fails with the list." })),
	lora_scale: Type.Optional(Type.Number({ minimum: 0, maximum: 2, description: "LoRA strength 0-2. Default from the LoRA." })),
	steps: Type.Optional(Type.Integer({ minimum: 10, maximum: 60, description: "Denoising steps for the base model, 10-60. Turbo ignores it." })),
};

const extras = (a: any) => ({
	...(a.seed !== undefined && { seed: a.seed }),
	...(a.negative_prompt && { negative_prompt: a.negative_prompt }),
	...(a.guidance !== undefined && { guidance: a.guidance }),
	...(a.model && { model: a.model }),
	...(a.lora && { lora: a.lora }),
	...(a.lora_scale !== undefined && { lora_scale: a.lora_scale }),
});

const generateImage = defineTool({
	name: "generate_image",
	label: "Generate image",
	description:
		"Generate an image from a text prompt with a local Qwen-Image 2.1 model and save it as a PNG. " +
		"Set transparent for stickers or cut-outs. For a close variation of an existing image pass init_image (and strength); " +
		"to change, restyle or combine images by instruction use edit_image. Slow: allow 1-3 minutes. " +
		"Write a detailed visual prompt (subject, setting, style, lighting, composition).",
	parameters: Type.Object({
		prompt: Type.String({ description: "Detailed description of the image." }),
		size: Type.Optional(Type.Union(SIZES.map((s) => Type.Literal(s)), { description: "Width x height. Default 1024x1024." })),
		init_image: Type.Optional(Type.String({ description: "Image path to start from, for a variation that keeps its layout." })),
		strength: Type.Optional(Type.Number({ minimum: 0.05, maximum: 0.95, description: "With init_image: how much to change it. Default 0.6." })),
		...common,
	}),
	async execute(_id, a, signal, _onUpdate, ctx) {
		const workspace = ctx?.cwd ?? process.cwd();
		if (a.strength !== undefined && !a.init_image) throw new Error("strength only applies together with init_image");
		const target = await outputPath(workspace, a);
		const init = a.init_image ? { image: await readInput(workspace, a.init_image), ...(a.strength !== undefined && { strength: a.strength }) } : {};
		return run(workspace, "/v1/images/generations",
			{ prompt: a.prompt, size: a.size ?? "1024x1024", steps: a.steps ?? 40, ...init, ...extras(a) },
			target, Boolean(a.transparent), signal);
	},
});

const editImage = defineTool({
	name: "edit_image",
	label: "Edit image",
	description:
		"Edit or combine existing images by instruction with a local Qwen-Image 2.1 model and save the result as a PNG. " +
		'Pass 1-10 images; refer to them in the prompt as "image 1", "image 2", ... in order. Examples: ' +
		'"Change the jacket in image 1 to dark green, keep the face and pose"; "Place the subject from image 1 in the setting of image 2"; ' +
		'"Repaint image 1 as a watercolor painting". Without size, the output follows the last image\'s aspect ratio. Slow: allow 1-3 minutes.',
	parameters: Type.Object({
		images: Type.Array(Type.String(), { minItems: 1, maxItems: 10, description: "Paths of 1-10 PNG/JPEG/WebP images, in prompt order." }),
		prompt: Type.String({ description: 'The edit instruction naming "image 1", "image 2", ...; say what to keep as well as what to change.' }),
		size: Type.Optional(Type.Union(SIZES.map((s) => Type.Literal(s)), { description: "Output size. Default: follow the last image." })),
		detail: Type.Optional(Type.Union([Type.Literal("low"), Type.Literal("medium"), Type.Literal("high")], { description: "Resolution budget: low 512, medium 768, high 1024 (default). Lower is faster." })),
		...common,
	}),
	async execute(_id, a, signal, _onUpdate, ctx) {
		const workspace = ctx?.cwd ?? process.cwd();
		const target = await outputPath(workspace, a);
		const refs = await Promise.all(a.images.map((p: string) => readInput(workspace, p)));
		return run(workspace, "/v1/images/edits", {
			prompt: a.prompt, images: refs, output_resolution: DETAIL[a.detail ?? "high"], steps: a.steps ?? 30,
			...(a.size && { size: a.size }), ...extras(a),
		}, target, Boolean(a.transparent), signal);
	},
});

export default function (pi: ExtensionAPI) {
	pi.registerTool(generateImage);
	pi.registerTool(editImage);
}
