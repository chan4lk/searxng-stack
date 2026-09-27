// web_search provider backed by a SearXNG instance (no API key).
// Point it at the stack: local http://127.0.0.1:8889 or the tailnet URL from searxng.sh.
// Endpoint: $SEARXNG_URL, else the loader entry's `config.url`, else localhost.
export const name = 'searxng-search'
export const inject = ['web']

const DEFAULT_URL = 'http://127.0.0.1:8889'

export function apply(ctx, config = {}) {
  const BASE_URL = (process.env.SEARXNG_URL ?? config.url ?? DEFAULT_URL).replace(/\/+$/, '')
  ctx.web.registerSearchProvider({
    id: 'searxng',
    available: () => true,
    async search({ query, maxResults }, signal) {
      const url = `${BASE_URL}/search?${new URLSearchParams({ q: query, format: 'json' })}`
      let response
      try {
        response = await fetch(url, { signal, headers: { accept: 'application/json' } })
      } catch (error) {
        if (signal?.aborted) throw error
        throw new Error(`SearXNG unreachable at ${BASE_URL} (is the stack up? ./searxng.sh status): ${error?.message ?? error}`)
      }
      if (!response.ok) throw new Error(`SearXNG returned HTTP ${response.status} for ${url}`)
      const data = await response.json()
      const seen = new Set()
      const sources = []
      for (const r of data.results ?? []) {
        if (!r.url || seen.has(r.url)) continue
        seen.add(r.url)
        sources.push({
          url: r.url,
          ...(r.title && { title: r.title }),
          ...(r.content && { snippet: r.content }),
          ...(r.publishedDate && { publishedAt: r.publishedDate }),
        })
        if (maxResults && sources.length >= maxResults) break
      }
      const answer = (data.answers ?? []).map((a) => (typeof a === 'string' ? a : a?.answer)).filter(Boolean).join('\n')
      return { ...(answer && { content: answer }), sources, truncated: false }
    },
  })
}
