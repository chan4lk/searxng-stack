// `ocr_document` tool for DeepSeek Harness, backed by this repo's ocr-server
// (Surya 2 OCR VLM via llama.cpp). Reads scanned or non-Latin PDFs and images,
// Sinhala and Tamil included, that a PDF text layer or a general LLM gets wrong.
// Long results are saved in the session's workspace (ocr/<name>.txt) and only
// the start is returned inline.
// Endpoint: $OCR_SERVER_URL, else the loader entry's `config.url`, else localhost.
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { basename, extname, join, relative, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { normalizeArgs, registerLenient } from './tool-args.mjs'

// Plugins under ~/.dsh/plugins sit outside dsh's node_modules, so a bare
// import can't see dsh's own packages. Resolve them from the profiles dir.
const profiles = join(process.env.DSH_HOME ?? join(homedir(), '.dsh'), 'profiles', 'package.json')
const { defineTool } = await import(pathToFileURL(createRequire(profiles).resolve('@deepseek-ai/dsh-tools')).href)

export const name = 'ocr-document'
export const inject = ['tools']

const DEFAULT_URL = 'http://127.0.0.1:8893'
const SPEC = {
  path: { type: 'string' },
  pages: { type: 'string', check: (v) => /^\d+(-\d+)?(\s*,\s*\d+(-\d+)?)*$/.test(v) },
  format: { type: 'string', enum: ['text', 'html'] },
}
const INLINE_CHARS = 40000
// ~10-20 s per page; 100 pages (the server's per-call limit) fits.
const TIMEOUT_MS = 60 * 60 * 1000

export function apply(ctx, config = {}) {
  const BASE_URL = (process.env.OCR_SERVER_URL ?? config.url ?? DEFAULT_URL).replace(/\/+$/, '')

  registerLenient(ctx, defineTool, {
    name: 'ocr_document',
    description:
      'OCR a PDF or image (PNG/JPEG/WebP) with the local Surya 2 OCR model and return its text page by page. ' +
      'Use it for scanned documents, photos of documents, and any Sinhala, Tamil or other non-Latin text: ' +
      'it reads the page image, so it works where PDF text extraction returns nothing or garbled characters. ' +
      'Set format "html" to keep table structure. Takes ~10-20 s per page; use pages to OCR only what you need. ' +
      `Results over ${INLINE_CHARS} characters are saved to ocr/<name>.txt in the workspace and only the start is returned.`,
    parameters: {
      path: { type: 'string', required: true, description: 'PDF or image file, relative to the workspace or absolute.' },
      pages: { type: 'string', description: '1-based PDF pages, e.g. "1-3,5". Default: all pages (max 100 per call).' },
      format: { type: 'string', enum: ['text', 'html'], description: 'text (default) or html (keeps tables).' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          text: { type: 'string', required: true },
          pages: { type: 'integer', required: true },
          seconds: { type: 'number', required: true },
          startup_seconds: { type: 'number', required: true },
          saved: { type: 'string', required: true },
          notes: { type: 'string', required: true },
        },
      },
      render: (args, v) => [{
        type: 'text',
        text: `OCR of ${args.path}: ${v.pages} page(s) in ${v.seconds}s` +
          (v.startup_seconds > 1 ? ` (incl. ${v.startup_seconds}s model startup)` : '') + '.' +
          (v.saved ? ` Full text saved to ${v.saved}; the first ${INLINE_CHARS} characters follow.` : '') +
          (v.notes ? `\nNote: ${v.notes}.` : '') + `\n\n${v.text}`,
      }],
    },
    timeoutMs: TIMEOUT_MS,
    isConcurrencySafe: () => false,
    async execute(rawArgs, exec) {
      const { args, notes } = normalizeArgs('ocr_document', rawArgs, SPEC, exec)
      if (!args.path) throw new Error('path is required: the PDF or image to OCR')
      const workspace = exec.agent?.session.header.cwd ?? process.cwd()
      const file = resolve(workspace, args.path)
      const data = await readFile(file)

      const query = new URLSearchParams({ filename: basename(file), format: args.format ?? 'text' })
      if (args.pages) query.set('pages', args.pages.replace(/\s+/g, ''))
      let response
      try {
        response = await fetch(`${BASE_URL}/v1/ocr?${query}`, {
          method: 'POST',
          signal: exec.signal,
          headers: { 'content-type': 'application/octet-stream' },
          body: data,
        })
      } catch (error) {
        if (exec.signal?.aborted) throw error
        throw new Error(`OCR server unreachable at ${BASE_URL} (is ocr-server running? ./ocr-server.sh status): ${error?.message ?? error}`)
      }
      const result = await response.json().catch(() => ({}))
      if (!response.ok) {
        const detail = typeof result.detail === 'string' ? result.detail : JSON.stringify(result.detail ?? result)
        throw new Error(`OCR server returned HTTP ${response.status}: ${detail}. ` +
          'Report this to the user; never stop or restart services on the server yourself.')
      }

      const text = result.pages.map((p) => `===== PAGE ${p.page} =====\n${p.text}`).join('\n\n')
      let saved = ''
      if (text.length > INLINE_CHARS) {
        const target = join(workspace, 'ocr', `${basename(file, extname(file))}.txt`)
        await mkdir(join(workspace, 'ocr'), { recursive: true })
        await writeFile(target, text)
        saved = relative(workspace, target)
      }
      return {
        text: saved ? text.slice(0, INLINE_CHARS) : text,
        pages: result.pages.length,
        seconds: result.seconds ?? 0,
        startup_seconds: result.startup_seconds ?? 0,
        saved,
        notes: notes.join('; '),
      }
    },
  })
}
