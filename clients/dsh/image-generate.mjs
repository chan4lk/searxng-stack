// Image tools for DeepSeek Harness, backed by this repo's image-server
// (Qwen-Image 2.1 via mflux):
//
//   generate_image  text-to-image; transparent (RGBA) output; or a variation of
//                   an existing workspace image (init_image + strength)
//   edit_image      instruction edits over 1-10 workspace images: change one,
//                   restyle it, or combine/merge several into one picture
//
// Results are saved as PNGs in the session's workspace (generated-images/
// unless a filename is given). Input and output paths must stay inside it.
// Endpoint: $IMAGE_SERVER_URL, else the loader entry's `config.url`, else localhost.
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { dirname, extname, isAbsolute, join, normalize, relative, resolve, sep } from 'node:path'
import { pathToFileURL } from 'node:url'

// Plugins under ~/.dsh/plugins sit outside dsh's node_modules, so a bare
// import can't see dsh's own packages. Resolve them from the profiles dir.
const profiles = join(process.env.DSH_HOME ?? join(homedir(), '.dsh'), 'profiles', 'package.json')
const { defineTool } = await import(pathToFileURL(createRequire(profiles).resolve('@deepseek-ai/dsh-tools')).href)

export const name = 'image-generate'
export const inject = ['tools']

const DEFAULT_URL = 'http://127.0.0.1:8890'
// The server needs multiples of 32.
const SIZES = ['512x512', '768x768', '1024x1024', '1024x768', '768x1024', '1344x768', '768x1344', '1536x1024', '1024x1536']
const DETAIL = { low: 512, medium: 768, high: 1024 }
const INPUT_TYPES = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp' }
const MAX_INPUT_BYTES = 25 * 1024 * 1024
// First use loads the model (can take minutes); a 1024² image is then ~1-2 minutes.
const TIMEOUT_MS = 15 * 60 * 1000

// Same test read_image applies: does the model serving this session accept images?
async function routeAcceptsImages(ctx, exec) {
  try {
    const routed = exec.agent?.session.requestHeader()?.config
    const provider = routed?.provider ?? exec.agent?.options.provider
    const model = routed?.model ?? exec.agent?.options.model
    const llm = ctx.get('llm')
    if (!provider || !model || !llm) return false
    const info = await llm.resolveModelInfo(provider, model, exec.signal)
    return Boolean(info.inputModalities?.includes('image'))
  } catch {
    return false
  }
}

function slug(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'image'
}

// Resolve a path inside the workspace; refuse anything that escapes it.
function insideWorkspace(workspace, path, what) {
  if (isAbsolute(path)) {
    const back = relative(workspace, path)
    if (back.startsWith('..') || isAbsolute(back)) throw new Error(`${what} must be inside the workspace`)
    return path
  }
  const target = resolve(workspace, normalize(path))
  const back = relative(workspace, target)
  if (back.startsWith('..') || back.split(sep).includes('..')) throw new Error(`${what} must stay inside the workspace`)
  return target
}

function outputPath(workspace, filename, prompt) {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '-')
  const rel = filename || join('generated-images', `${stamp}-${slug(prompt)}.png`)
  if (isAbsolute(rel)) throw new Error('filename must be relative to the workspace')
  return insideWorkspace(workspace, rel.endsWith('.png') ? rel : `${rel}.png`, 'filename')
}

// Read a workspace image as a data URL for the server.
async function readInput(workspace, path) {
  const file = insideWorkspace(workspace, path, `image "${path}"`)
  const type = INPUT_TYPES[extname(file).toLowerCase()]
  if (!type) throw new Error(`"${path}" must be a PNG, JPEG or WebP file`)
  const info = await stat(file).catch(() => null)
  if (!info?.isFile()) throw new Error(`"${path}" does not exist in the workspace`)
  if (info.size > MAX_INPUT_BYTES) throw new Error(`"${path}" is larger than 25 MB`)
  return `data:${type};base64,${(await readFile(file)).toString('base64')}`
}

function workspaceOf(exec) {
  return exec.agent?.session.header.cwd ?? process.cwd()
}

const OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    path: { type: 'string', required: true },
    url: { type: 'string', required: true },
    size: { type: 'string', required: true },
    seed: { type: 'integer', required: true },
    steps: { type: 'integer', required: true },
    seconds: { type: 'number', required: true },
    model_load_seconds: { type: 'number', required: true },
    transparent: { type: 'boolean', required: true },
    transparent_percent: { type: 'integer', required: true },
    show_with_read_image: { type: 'boolean', required: true },
  },
}

// The chat UI draws inline images only on read_image's own card, so the
// result asks the agent to open the file with read_image when it can.
function renderResult(verb) {
  return (_args, v) => [{
    type: 'text',
    text: `${verb} a ${v.size}${v.transparent ? ' transparent (RGBA)' : ''} image and saved it to ${v.path} ` +
      `(seed ${v.seed}, ${v.steps} steps, ${v.seconds}s` +
      (v.model_load_seconds > 1 ? `, incl. ${v.model_load_seconds}s model load` : '') +
      `). Server copy: ${v.url}` +
      (v.transparent
        ? `\nMeasured alpha: ${v.transparent_percent}% of pixels are fully transparent` +
          (v.transparent_percent >= 10
            ? ' — the transparent background worked. read_image may render transparent areas as a solid color; that is a display artifact, so do not regenerate because of it.'
            : ' — little or no transparency came out; retry once with a prompt that describes the subject isolated on a transparent background.')
        : '') +
      (v.show_with_read_image
        ? `\nNow call read_image with file_path "${v.path}" so the image is shown to the user in the chat and you can check it matches the request.`
        : ''),
  }]
}

export function apply(ctx, config = {}) {
  const BASE_URL = (process.env.IMAGE_SERVER_URL ?? config.url ?? DEFAULT_URL).replace(/\/+$/, '')

  // POST to image-server, download the result into the workspace, and build the tool value.
  async function run(exec, endpoint, body, { target, steps, transparent }) {
    let response
    try {
      response = await fetch(`${BASE_URL}${endpoint}`, {
        method: 'POST',
        signal: exec.signal,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ ...body, steps, transparent, response_format: 'url' }),
      })
    } catch (error) {
      if (exec.signal?.aborted) throw error
      throw new Error(`image server unreachable at ${BASE_URL} (is image-server running? ./image-server.sh status): ${error?.message ?? error}`)
    }
    const result = await response.json().catch(() => ({}))
    if (!response.ok) {
      const detail = typeof result.detail === 'string' ? result.detail : JSON.stringify(result.detail ?? result)
      if (response.status === 503) {
        // Memory guard: this must end with the user, not with the agent freeing memory on a shared machine.
        throw new Error(`image server is out of memory (HTTP 503): ${detail} ` +
          'Report this to the user and wait for their decision. Never stop Splash or any other process yourself.')
      }
      throw new Error(`image server returned HTTP ${response.status}: ${detail}`)
    }
    const item = result.data?.[0]
    if (!item?.url) throw new Error('image server response had no image')

    const png = await fetch(item.url, { signal: exec.signal })
    if (!png.ok) throw new Error(`could not download ${item.url}: HTTP ${png.status}`)
    await mkdir(dirname(target), { recursive: true })
    await writeFile(target, new Uint8Array(await png.arrayBuffer()))

    const workspace = workspaceOf(exec)
    return {
      path: relative(workspace, target) || target,
      url: item.url,
      size: `${item.width}x${item.height}`,
      seed: item.seed,
      steps,
      seconds: result.generate_seconds ?? 0,
      model_load_seconds: result.load_seconds ?? 0,
      transparent,
      transparent_percent: Math.round(100 * (item.transparent_fraction ?? 0)),
      show_with_read_image: Boolean(ctx.tools.get('read_image')) && (await routeAcceptsImages(ctx, exec)),
    }
  }

  function checkSteps(steps) {
    if (!Number.isInteger(steps) || steps < 10 || steps > 60) throw new Error('steps must be an integer from 10 to 60')
  }

  const common = {
    seed: { type: 'integer', description: 'Seed for reproducible output. Omit for a random seed.' },
    transparent: { type: 'boolean', description: 'Produce a transparent-background PNG (stickers, icons, cut-outs). Default false.' },
    negative_prompt: { type: 'string', description: 'Things to avoid. Only takes effect together with guidance > 1.' },
    guidance: { type: 'number', description: 'Classifier-free guidance, 1-10. Default 1 (the model is tuned for no guidance).' },
    filename: { type: 'string', description: 'Output path relative to the workspace, e.g. assets/hero.png. Default generated-images/<time>-<prompt>.png.' },
  }
  const extras = (args) => ({
    ...(args.seed !== undefined && { seed: args.seed }),
    ...(args.negative_prompt && { negative_prompt: args.negative_prompt }),
    ...(args.guidance !== undefined && { guidance: args.guidance }),
  })

  ctx.tools.register(defineTool({
    name: 'generate_image',
    description:
      'Generate an image from a text prompt with a local Qwen-Image 2.1 model and save it as a PNG in the workspace. ' +
      'Set transparent for stickers, icons or cut-outs. To make a close variation of an existing image, pass init_image ' +
      '(and strength); to change, restyle or combine existing images by instruction, use edit_image instead. ' +
      'Returns the saved path; follow up with read_image on it to show the result in the chat. ' +
      'Slow: allow 1-3 minutes (longer on first use while the model loads). ' +
      'Write a detailed visual prompt (subject, setting, style, lighting, composition).',
    parameters: {
      prompt: { type: 'string', required: true, description: 'Detailed description of the image to generate.' },
      size: { type: 'string', enum: SIZES, description: 'Width x height in pixels. Default 1024x1024.' },
      steps: { type: 'integer', description: 'Denoising steps, 10-60. Default 40; ~20 for quick drafts.' },
      init_image: { type: 'string', description: 'Optional workspace image to start from, for a variation that keeps its layout.' },
      strength: { type: 'number', description: 'With init_image: how much to change it, 0.05 (barely) to 0.95 (almost fully redrawn). Default 0.6.' },
      ...common,
    },
    output: { schema: OUTPUT_SCHEMA, render: renderResult('Generated'), presentationMeta: (_args, v) => ({ path: v.path }) },
    timeoutMs: TIMEOUT_MS,
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      const size = args.size ?? '1024x1024'
      const steps = args.steps ?? 40
      if (!SIZES.includes(size)) throw new Error(`size must be one of ${SIZES.join(', ')}`)
      checkSteps(steps)
      if (args.strength !== undefined && !args.init_image) throw new Error('strength only applies together with init_image')
      const workspace = workspaceOf(exec)
      const target = outputPath(workspace, args.filename, args.prompt)
      const init = args.init_image ? { image: await readInput(workspace, args.init_image), ...(args.strength !== undefined && { strength: args.strength }) } : {}
      return run(exec, '/v1/images/generations', { prompt: args.prompt, size, ...init, ...extras(args) },
        { target, steps, transparent: Boolean(args.transparent) })
    },
  }))

  ctx.tools.register(defineTool({
    name: 'edit_image',
    description:
      'Edit or combine existing workspace images by instruction with a local Qwen-Image 2.1 model, and save the result as a PNG. ' +
      'Pass 1-10 images; refer to them in the prompt as "image 1", "image 2", ... in the order given. Examples: ' +
      '"Change the jacket in image 1 to dark green, keep the face and pose"; "Place the subject from image 1 in the setting of image 2"; ' +
      '"Repaint image 1 as a watercolor painting, keep the composition"; "Put the logo from image 2 on the mug in image 1". ' +
      'Without size, the output follows the last image\'s aspect ratio. Returns the saved path; follow up with read_image on it. ' +
      'Slow: allow 1-3 minutes.',
    parameters: {
      images: { type: 'array', required: true, items: { type: 'string' }, description: 'Workspace paths of 1-10 PNG/JPEG/WebP images, in the order the prompt refers to them.' },
      prompt: { type: 'string', required: true, description: 'The edit instruction, naming images as "image 1", "image 2", ...; say what to keep as well as what to change.' },
      size: { type: 'string', enum: SIZES, description: 'Output size. Default: follow the last image\'s aspect ratio.' },
      detail: { type: 'string', enum: Object.keys(DETAIL), description: 'Resolution budget for inputs and automatic output size: low 512, medium 768, high 1024 (default). Lower is faster.' },
      steps: { type: 'integer', description: 'Denoising steps, 10-60. Default 30.' },
      ...common,
    },
    output: { schema: OUTPUT_SCHEMA, render: renderResult('Edited'), presentationMeta: (_args, v) => ({ path: v.path }) },
    timeoutMs: TIMEOUT_MS,
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      const images = Array.isArray(args.images) ? args.images : []
      if (images.length < 1 || images.length > 10) throw new Error('images must list 1 to 10 workspace paths')
      if (args.size && !SIZES.includes(args.size)) throw new Error(`size must be one of ${SIZES.join(', ')}`)
      const detail = args.detail ?? 'high'
      if (!(detail in DETAIL)) throw new Error('detail must be low, medium or high')
      const steps = args.steps ?? 30
      checkSteps(steps)
      const workspace = workspaceOf(exec)
      const target = outputPath(workspace, args.filename, args.prompt)
      const refs = await Promise.all(images.map((p) => readInput(workspace, p)))
      return run(exec, '/v1/images/edits', {
        prompt: args.prompt, images: refs, output_resolution: DETAIL[detail],
        ...(args.size && { size: args.size }), ...extras(args),
      }, { target, steps, transparent: Boolean(args.transparent) })
    },
  }))
}
