/**
 * Vercel Services preserve the public /api prefix when forwarding to Fastify.
 * Existing API routes remain unprefixed for the standalone Docker deployment.
 * Do not rewrite other paths or treat /apix as /api.
 */
export function normalizeApiPath(rawUrl: string, isVercel: boolean): string {
  if (!isVercel) return rawUrl
  if (!/^\/api(?=\/|\?|$)/.test(rawUrl)) return rawUrl
  const stripped = rawUrl.slice(4)
  return stripped === '' || stripped.startsWith('?') ? '/' + stripped : stripped
}
