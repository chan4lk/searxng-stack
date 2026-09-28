// Argument repair for the media tools (generate_image, edit_image,
// generate_music). Deep into long sessions the local model emits tool calls
// whose keys fuse a parameter name with its value or with other names —
// "formatmp3", "bpm85", "lyricsformatmp3", "transparent〉" — and each rejected
// call stays in context and gets imitated, so rejecting alone loops.
//
// Policy: repair what can be repaired and validate every value. The first
// malformed call in a session is rejected with the exact corrected JSON to
// resend; after that, calls proceed with the repaired arguments and a note of
// what was fixed or ignored, so the loop ends.

const strikes = new Map() // `${session}:${tool}` -> malformed calls seen

function sessionKey(exec, tool) {
  const s = exec.agent?.session
  return `${s?.header?.id ?? s?.id ?? s?.header?.cwd ?? 'default'}:${tool}`
}

// spec: { name: { type: 'string'|'number'|'integer'|'boolean'|'array', enum?, min?, max?, check?(v) } }
function coerce(value, rule) {
  if (value === undefined || value === null) return undefined
  switch (rule.type) {
    case 'boolean':
      if (typeof value === 'boolean') return value
      if (/^(true|yes|1)$/i.test(String(value).trim())) return true
      if (/^(false|no|0)$/i.test(String(value).trim())) return false
      return undefined
    case 'integer':
    case 'number': {
      const n = Number(String(value).trim())
      if (!Number.isFinite(n) || (rule.type === 'integer' && !Number.isInteger(n))) return undefined
      if ((rule.min !== undefined && n < rule.min) || (rule.max !== undefined && n > rule.max)) return undefined
      return n
    }
    case 'array':
      return Array.isArray(value) ? value : undefined
    default: {
      if (typeof value !== 'string' || !value.trim()) return undefined
      const v = value.trim()
      if (rule.enum && !rule.enum.includes(v)) return undefined
      if (rule.check && !rule.check(v)) return undefined
      return v
    }
  }
}

// Split a fused key into [name, inlineValue] segments using the known names.
function splitKey(key, names) {
  let s = key.toLowerCase().replace(/[^a-z0-9_ ./#-]/g, '')
  const out = []
  while (s.length) {
    s = s.replace(/^[\s_/.-]+/, '')
    if (!s) break
    let hit
    for (const n of names) {
      if (s.startsWith(n)) { hit = { n, len: n.length }; break }
      // truncated name, e.g. "lyric" for "lyrics"
      if (n.length > 4 && s.startsWith(n.slice(0, -1)) && !names.some((m) => s.startsWith(m))) { hit = { n, len: n.length - 1 }; break }
    }
    if (!hit) { if (out.length) out[out.length - 1][1] += s; break }
    s = s.slice(hit.len)
    const next = names.map((m) => s.indexOf(m)).filter((i) => i >= 0)
    const cut = next.length ? Math.min(...next) : s.length
    out.push([hit.n, s.slice(0, cut).trim()])
    s = s.slice(cut)
  }
  return out
}

/**
 * Returns the arguments to use. Throws (once per session and tool) with a
 * corrected payload when the call was malformed.
 */
export function normalizeArgs(tool, rawArgs, spec, exec) {
  const names = Object.keys(spec).sort((a, b) => b.length - a.length)
  const args = {}
  const notes = []
  const unknown = []
  for (const [k, v] of Object.entries(rawArgs ?? {})) {
    if (k in spec) {
      const c = coerce(v, spec[k])
      if (c !== undefined) args[k] = c
      else notes.push(`ignored invalid ${k}=${JSON.stringify(v).slice(0, 40)}`)
    } else unknown.push([k, v])
  }
  for (const [k, v] of unknown) {
    const segments = splitKey(k, names)
    const fixed = []
    for (const [n, inline] of segments) {
      if (n in args) continue
      const c = coerce(inline !== '' ? inline : v, spec[n]) ?? (inline !== '' ? coerce(v, spec[n]) : undefined)
      if (c !== undefined) { args[n] = c; fixed.push(`${n}=${JSON.stringify(c).slice(0, 40)}`) }
    }
    notes.push(fixed.length ? `repaired "${k.slice(0, 40)}" -> ${fixed.join(', ')}` : `ignored malformed argument "${k.slice(0, 40)}"`)
  }
  if (!unknown.length) return { args, notes }

  const key = sessionKey(exec, tool)
  const count = (strikes.get(key) ?? 0) + 1
  strikes.set(key, count)
  if (count === 1) {
    throw new Error(
      `malformed arguments (${unknown.map(([k]) => JSON.stringify(k.slice(0, 40))).join(', ')}): parameter names must be ` +
      `exact JSON keys with the value as a separate field. Valid parameters: ${Object.keys(spec).join(', ')}. ` +
      `Resend this corrected call, adding any fields that were lost: ${JSON.stringify(args)}`)
  }
  return { args, notes: [`proceeded with repaired arguments after a malformed call (${notes.join('; ')})`] }
}

// defineTool enforces declared JSON types before execute runs, so a string
// "20" for a number never reaches the repair above. Register a tool whose
// runtime validation also accepts strings for number/integer/boolean fields,
// while advertising the strict schema to the model unchanged.
function loosen(spec) {
  if (spec.type === 'number' || spec.type === 'integer' || spec.type === 'boolean') {
    const { required, description, ...rest } = spec
    return { oneOf: [rest, { type: 'string' }], ...(description && { description }), ...(required && { required }) }
  }
  return spec
}

export function registerLenient(ctx, defineTool, options) {
  const strict = defineTool(options)
  const lenient = defineTool({
    ...options,
    parameters: Object.fromEntries(Object.entries(options.parameters).map(([k, v]) => [k, loosen(v)])),
  })
  return ctx.tools.register({ ...lenient, parameters: strict.parameters })
}
