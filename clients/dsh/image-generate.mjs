// `generate_image` tool for DeepSeek Harness, backed by this repo's
// image-server (Qwen-Image 2.1 via mflux). The PNG is saved into the session's
// workspace (generated-images/ unless a filename is given) and the tool
// returns its path, so the agent can reference or post-process the file.
// Endpoint: $IMAGE_SERVER_URL, else the loader entry's `config.url`, else localhost.
import { mkdir, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join, normalize, relative, resolve, sep } from 'node:path'
import { pathToFileURL } from 'node:url'

// Plugins under ~/.dsh/plugins sit outside dsh's node_modules, so a bare
// import can't see dsh's own packages. Resolve them from the profiles dir.
const profiles = join(process.env.DSH_HOME ?? join(homedir(), '.dsh'), 'profiles', 'package.json')
const { defineTool } = await import(pathToFileURL(createRequire(profiles).resolve('@deepseek-ai/dsh-tools')).href)

export const name = 'image-generate'
export const inject = ['tools']

const DEFAULT_URL = 'http://127.0.0.1:8890'
const SIZES = ['512x512', '768x768', '1024x1024', '1024x768', '768x1024', '1280x720', '720x1280', '1536x1024', '1024x1536']
// First use loads the model (can take minutes), then 1024², 40 steps is ~80-130 s.
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

// Resolve the output file inside the workspace; refuse anything that escapes it.
function outputPath(workspace, filename, prompt) {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '-')
  const rel = filename ? normalize(filename) : join('generated-images', `${stamp}-${slug(prompt)}.png`)
  if (isAbsolute(rel)) throw new Error('filename must be relative to the workspace')
  const target = resolve(workspace, rel.endsWith('.png') ? rel : `${rel}.png`)
  const back = relative(workspace, target)
  if (back.startsWith('..') || back.split(sep).includes('..')) throw new Error('filename must stay inside the workspace')
  return target
}

export function apply(ctx, config = {}) {
  const BASE_URL = (process.env.IMAGE_SERVER_URL ?? config.url ?? DEFAULT_URL).replace(/\/+$/, '')
  ctx.tools.register(defineTool({
    name: 'generate_image',
    description:
      'Generate an image from a text prompt with a local Qwen-Image 2.1 model and save it as a PNG in the workspace. ' +
      'Returns the saved file path. To show the result in the chat, follow up with read_image on that path. ' +
      'Slow: allow 1-3 minutes per image (longer on first use while the model loads). ' +
      'Write a detailed visual prompt (subject, setting, style, lighting, composition).',
    parameters: {
      prompt: { type: 'string', required: true, description: 'Detailed description of the image to generate.' },
      size: { type: 'string', enum: SIZES, description: 'Width x height in pixels. Default 1024x1024.' },
      steps: { type: 'integer', description: 'Denoising steps, 10-60. Default 40; use ~20 for quick drafts.' },
      seed: { type: 'integer', description: 'Seed for reproducible output. Omit for a random seed.' },
      negative_prompt: { type: 'string', description: 'Things to avoid. Only takes effect together with guidance > 1.' },
      guidance: { type: 'number', description: 'Classifier-free guidance, 1-10. Default 1 (the model is tuned for no guidance).' },
      filename: { type: 'string', description: 'Optional path relative to the workspace, e.g. assets/hero.png. Default generated-images/<time>-<prompt>.png.' },
    },
    output: {
      schema: {
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
          show_with_read_image: { type: 'boolean', required: true },
        },
      },
      // The chat UI draws inline images only on read_image's own card, so the
      // result asks the agent to open the file with read_image when it can.
      render: (_args, v) => [{
        type: 'text',
        text: `Saved a ${v.size} image to ${v.path} (seed ${v.seed}, ${v.steps} steps, ${v.seconds}s` +
          (v.model_load_seconds > 1 ? `, incl. ${v.model_load_seconds}s model load` : '') +
          `). Server copy: ${v.url}` +
          (v.show_with_read_image
            ? `\nNow call read_image with file_path "${v.path}" so the image is shown to the user in the chat and you can check it matches the request.`
            : ''),
      }],
      presentationMeta: (_args, v) => ({ path: v.path }),
    },
    timeoutMs: TIMEOUT_MS,
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      const size = args.size ?? '1024x1024'
      const steps = args.steps ?? 40
      if (!SIZES.includes(size)) throw new Error(`size must be one of ${SIZES.join(', ')}`)
      if (!Number.isInteger(steps) || steps < 10 || steps > 60) throw new Error('steps must be an integer from 10 to 60')
      const workspace = exec.agent?.session.header.cwd ?? process.cwd()
      const target = outputPath(workspace, args.filename, args.prompt)

      let response
      try {
        response = await fetch(`${BASE_URL}/v1/images/generations`, {
          method: 'POST',
          signal: exec.signal,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            prompt: args.prompt,
            size,
            steps,
            response_format: 'url',
            ...(args.seed !== undefined && { seed: args.seed }),
            ...(args.negative_prompt && { negative_prompt: args.negative_prompt }),
            ...(args.guidance !== undefined && { guidance: args.guidance }),
          }),
        })
      } catch (error) {
        if (exec.signal?.aborted) throw error
        throw new Error(`image server unreachable at ${BASE_URL} (is image-server running? ./image-server.sh status): ${error?.message ?? error}`)
      }
      const body = await response.json().catch(() => ({}))
      if (!response.ok) {
        const detail = typeof body.detail === 'string' ? body.detail : JSON.stringify(body.detail ?? body)
        throw new Error(`image server returned HTTP ${response.status}: ${detail}`)
      }
      const item = body.data?.[0]
      if (!item?.url) throw new Error('image server response had no image')

      const png = await fetch(item.url, { signal: exec.signal })
      if (!png.ok) throw new Error(`could not download ${item.url}: HTTP ${png.status}`)
      const data = new Uint8Array(await png.arrayBuffer())
      await mkdir(dirname(target), { recursive: true })
      await writeFile(target, data)
      const showable = Boolean(ctx.tools.get('read_image')) && (await routeAcceptsImages(ctx, exec))

      return {
        path: relative(workspace, target) || target,
        url: item.url,
        size,
        seed: item.seed,
        steps,
        seconds: body.generate_seconds ?? 0,
        model_load_seconds: body.load_seconds ?? 0,
        show_with_read_image: showable,
      }
    },
  }))
}
