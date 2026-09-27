// Guard for DeepSeek Harness: denies tool calls that would stop, kill or
// restart processes on the shared server (the Mac running Splash, SearXNG and
// image-server). An agent once freed memory for an image job by running
// `ssh <server> "pkill -f splash"`, taking down the model every client uses.
// Read-only checks (health, status, logs, ps) stay allowed.
//
// Loader entry config:
//   hosts: [100.x.y.z, mac-studio, mac-studio.tailXXXX.ts.net]   names that mean "the server"
export const name = 'studio-guard'
export const inject = ['tools']

// A command reaches the server if it goes through ssh/scp/mosh/tailscale ssh
// to one of the hosts, or through the mac-studio skill's helper.
const REMOTE_TOOLS = /\b(ssh|scp|sftp|mosh|rsync|tailscale\s+ssh)\b/
const HELPER = /\bstudio\.sh\s+run\b/

// Verbs that stop, kill, restart or remove things. Kept broad on purpose: a
// false positive costs the agent one "ask the user", a miss costs an outage.
const DESTRUCTIVE = [
  /\b(pkill|killall|kill)\b/,
  /\blaunchctl\s+(bootout|unload|stop|kill|remove|disable)\b/,
  /\b(shutdown|reboot|halt)\b/,
  /\bbrew\s+services\s+(stop|restart|kill)\b/,
  /\bcolima\s+(stop|delete|restart)\b/,
  /\bdocker\b[^\n]*\b(stop|kill|rm|down|restart|pause)\b/,
  /\bimage-server\.sh\s+(stop|restart|install|uninstall|unload)\b/,
  /\bmusic-server\.sh\s+(stop|restart|install|uninstall|unload)\b/,
  /\bacestep-api\b[^\n]*\b(stop|kill)\b/,
  /\bsearxng\.sh\s+(down|restart|unserve)\b/,
  /\btailscale\s+(down|logout)\b/,
  /\btailscale\s+serve\b[^\n]*\boff\b/,
  /\bsplash\b[^\n]*\b(stop|kill|quit)\b/,
  /\brm\s+-[a-z]*r[a-z]*f?\b/,
  /\/v1\/unload\b/,
]

// Every string inside the arguments, so bash `command`, terminal `input`, and
// run_code `code` are all covered without knowing each tool's schema.
function strings(value, out = []) {
  if (typeof value === 'string') out.push(value)
  else if (Array.isArray(value)) value.forEach((v) => strings(v, out))
  else if (value && typeof value === 'object') Object.values(value).forEach((v) => strings(v, out))
  return out
}

export function blockedReason(text, hosts) {
  const targetsServer = HELPER.test(text) ||
    (REMOTE_TOOLS.test(text) && hosts.some((h) => text.includes(h)))
  if (!targetsServer) return undefined
  const verb = DESTRUCTIVE.find((re) => re.test(text))
  if (!verb) return undefined
  return 'Blocked by studio-guard: this command would stop, kill, restart or remove something on the shared ' +
    'server (Splash, image-server, music-server, SearXNG, Colima or the user\'s own jobs). Agents may not do that. ' +
    'Do not try another way. Tell the user what you wanted to do and why, and let them decide.'
}

export function apply(ctx, config = {}) {
  const hosts = (config.hosts ?? []).filter((h) => typeof h === 'string' && h.length > 0)
  if (hosts.length === 0) return // nothing to guard until hosts are configured
  ctx.on('tools/pre-execute', async (exec, next) => {
    const text = strings(exec.arguments).join('\n')
    const reason = blockedReason(text, hosts)
    if (reason) return { kind: 'deny', reason }
    return next()
  })
}
