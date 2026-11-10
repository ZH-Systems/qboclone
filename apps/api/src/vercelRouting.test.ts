import { describe, expect, it } from 'vitest'
import { normalizeApiPath } from './vercelRouting.js'

describe('Vercel Services API routing', () => {
  it('preserves existing paths when running the standalone Docker API', () => {
    expect(normalizeApiPath('/api/health', false)).toBe('/api/health')
    expect(normalizeApiPath('/health', false)).toBe('/health')
  })
  it('strips exactly one public /api prefix and preserves callback queries', () => {
    expect(normalizeApiPath('/api/health', true)).toBe('/health')
    expect(normalizeApiPath('/api/stripe/webhook', true)).toBe('/stripe/webhook')
    expect(normalizeApiPath('/api/qbo/connect/callback?code=secret&state=token', true))
      .toBe('/qbo/connect/callback?code=secret&state=token')
  })
  it('does not rewrite non-API paths or near-matching prefixes', () => {
    expect(normalizeApiPath('/apix/health', true)).toBe('/apix/health')
    expect(normalizeApiPath('/health', true)).toBe('/health')
    expect(normalizeApiPath('/api', true)).toBe('/')
    expect(normalizeApiPath('/api?x=1', true)).toBe('/?x=1')
  })
})
