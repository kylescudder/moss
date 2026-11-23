import { expect, test } from 'bun:test'
import { renderEmail } from '../src/email'

test('confirmation/reset mail escapes links and refuses an unexpected origin', () => {
  expect(
    renderEmail(
      'verify',
      'https://api.example.test/api/auth/verify-email?token=x&callbackURL=moss%3A%2F%2Fauth-callback',
      'https://api.example.test'
    ).htmlContent
  ).toContain('&amp;callbackURL=')
  expect(
    renderEmail(
      'reset',
      'https://api.example.test/api/auth/reset-password/secret',
      'https://api.example.test'
    ).subject
  ).toBe('Reset your Moss password')
  expect(() =>
    renderEmail(
      'reset',
      'https://evil.test/api/auth/reset-password/secret',
      'https://api.example.test'
    )
  ).toThrow('Invalid email link')
})
