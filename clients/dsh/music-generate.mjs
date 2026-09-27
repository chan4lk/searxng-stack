// `generate_music` tool for DeepSeek Harness, backed by this repo's
// music-server (ACE-Step 1.5, MIT-licensed, commercial use allowed).
// The audio is saved in the session's workspace (generated-music/ unless a
// filename is given); paths outside the workspace are refused.
// Endpoint: $MUSIC_SERVER_URL, else the loader entry's `config.url`, else localhost.
import { mkdir, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join, normalize, relative, resolve, sep } from 'node:path'
import { pathToFileURL } from 'node:url'

// Plugins under ~/.dsh/plugins sit outside dsh's node_modules, so a bare
// import can't see dsh's own packages. Resolve them from the profiles dir.
const profiles = join(process.env.DSH_HOME ?? join(homedir(), '.dsh'), 'profiles', 'package.json')
const { defineTool } = await import(pathToFileURL(createRequire(profiles).resolve('@deepseek-ai/dsh-tools')).href)

export const name = 'music-generate'
export const inject = ['tools']

const DEFAULT_URL = 'http://127.0.0.1:8891'
const FORMATS = ['mp3', 'wav', 'flac']
// First use starts ACE-Step (and on a fresh install downloads ~10 GB of models).
const TIMEOUT_MS = 30 * 60 * 1000

// Local models sometimes emit malformed tool calls that fuse a key and its
// value ("filename audio/x.mp3": 20). Reject unknown keys loudly so the model
// retries with proper arguments instead of silently getting defaults.
function rejectUnknownArgs(args, allowed) {
  const unknown = Object.keys(args ?? {}).filter((k) => !allowed.includes(k))
  if (unknown.length) {
    throw new Error(`unknown argument(s): ${unknown.map((k) => JSON.stringify(k)).join(', ')}. ` +
      `Valid arguments are: ${allowed.join(', ')}. Pass each as its own JSON field, e.g. {"filename": "audio/track.mp3", "duration": 20}.`)
  }
}

function slug(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'track'
}

function outputPath(workspace, filename, prompt, format) {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '-')
  let rel = filename || join('generated-music', `${stamp}-${slug(prompt)}.${format}`)
  if (isAbsolute(rel)) throw new Error('filename must be relative to the workspace')
  if (!rel.toLowerCase().endsWith(`.${format}`)) rel = `${rel}.${format}`
  const target = resolve(workspace, normalize(rel))
  const back = relative(workspace, target)
  if (back.startsWith('..') || back.split(sep).includes('..')) throw new Error('filename must stay inside the workspace')
  return target
}

export function apply(ctx, config = {}) {
  const BASE_URL = (process.env.MUSIC_SERVER_URL ?? config.url ?? DEFAULT_URL).replace(/\/+$/, '')

  ctx.tools.register(defineTool({
    name: 'generate_music',
    description:
      'Generate an original music track with a local ACE-Step 1.5 model (commercially licensed) and save it in the workspace. ' +
      'Good for background music, jingles and short-form video soundtracks; can also sing provided lyrics. ' +
      'Describe genre, mood, instruments, tempo and use (e.g. "upbeat corporate pop, bright synths, punchy drums, for a 30s product reel"). ' +
      'Set instrumental for background music. Lyrics use section tags like [Verse], [Chorus], [Bridge]. ' +
      'Returns the saved path. Slow on first use (the model starts up); then roughly a minute per track.',
    parameters: {
      prompt: { type: 'string', required: true, description: 'Style, mood, instruments, tempo feel and purpose of the track.' },
      lyrics: { type: 'string', description: 'Song lyrics with [Verse]/[Chorus] tags. Omit for instrumental.' },
      instrumental: { type: 'boolean', description: 'No vocals. Default true when no lyrics are given.' },
      duration: { type: 'number', description: 'Length in seconds, 10-600. Default 30 (short-form video).' },
      bpm: { type: 'integer', description: 'Tempo, 30-300. Omit to let the model choose.' },
      key: { type: 'string', description: 'Key/scale, e.g. "C Major" or "Am". Omit to let the model choose.' },
      language: { type: 'string', description: 'Vocal language code, e.g. en, zh, ja, es. Default en.' },
      seed: { type: 'integer', description: 'Seed for reproducible output. Omit for random.' },
      format: { type: 'string', enum: FORMATS, description: 'Audio format. Default mp3.' },
      filename: { type: 'string', description: 'Output path relative to the workspace, e.g. audio/reel-bgm.mp3. Default generated-music/<time>-<prompt>.<format>.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          path: { type: 'string', required: true },
          url: { type: 'string', required: true },
          duration: { type: 'number', required: true },
          seed: { type: 'integer', required: true },
          seconds: { type: 'number', required: true },
          startup_seconds: { type: 'number', required: true },
          metas: { type: 'string', required: true },
        },
      },
      render: (_args, v) => [{
        type: 'text',
        text: `Generated a ${v.duration}s track and saved it to ${v.path} (seed ${v.seed}, ${v.seconds}s` +
          (v.startup_seconds > 1 ? `, incl. ${v.startup_seconds}s model startup` : '') +
          `). Model's metadata: ${v.metas}. Server copy: ${v.url}`,
      }],
      presentationMeta: (_args, v) => ({ path: v.path }),
    },
    timeoutMs: TIMEOUT_MS,
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      rejectUnknownArgs(args, ['prompt', 'lyrics', 'instrumental', 'duration', 'bpm', 'key', 'language', 'seed', 'format', 'filename'])
      const format = args.format ?? 'mp3'
      if (!FORMATS.includes(format)) throw new Error(`format must be one of ${FORMATS.join(', ')}`)
      const duration = args.duration ?? 30
      if (typeof duration !== 'number' || duration < 10 || duration > 600) throw new Error('duration must be 10-600 seconds')
      const lyrics = (args.lyrics ?? '').trim()
      const instrumental = args.instrumental ?? !lyrics
      const workspace = exec.agent?.session.header.cwd ?? process.cwd()
      const target = outputPath(workspace, args.filename, args.prompt, format)

      let response
      try {
        response = await fetch(`${BASE_URL}/v1/music/generations`, {
          method: 'POST',
          signal: exec.signal,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            prompt: args.prompt, instrumental, duration, format,
            ...(lyrics && !instrumental && { lyrics }),
            ...(args.bpm !== undefined && { bpm: args.bpm }),
            ...(args.key && { key: args.key }),
            ...(args.language && { language: args.language }),
            ...(args.seed !== undefined && { seed: args.seed }),
          }),
        })
      } catch (error) {
        if (exec.signal?.aborted) throw error
        throw new Error(`music server unreachable at ${BASE_URL} (is music-server running? ./music-server.sh status): ${error?.message ?? error}`)
      }
      const result = await response.json().catch(() => ({}))
      if (!response.ok) {
        const detail = typeof result.detail === 'string' ? result.detail : JSON.stringify(result.detail ?? result)
        throw new Error(`music server returned HTTP ${response.status}: ${detail}. ` +
          'Report this to the user; never stop or restart services on the server yourself.')
      }
      const audio = await fetch(result.url, { signal: exec.signal })
      if (!audio.ok) throw new Error(`could not download ${result.url}: HTTP ${audio.status}`)
      await mkdir(dirname(target), { recursive: true })
      await writeFile(target, new Uint8Array(await audio.arrayBuffer()))

      return {
        path: relative(workspace, target) || target,
        url: result.url,
        duration,
        seed: result.seed,
        seconds: result.seconds ?? 0,
        startup_seconds: result.startup_seconds ?? 0,
        metas: JSON.stringify(result.metas ?? {}),
      }
    },
  }))
}
