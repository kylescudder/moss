import { expect, test } from 'bun:test'
import { validatePlanPhotos } from '../src/plan-photos'

test('plan photos accept bounded JPEG attachments and removal', () => {
  const photo = {
    id: crypto.randomUUID(),
    jpeg: Buffer.from([0xff, 0xd8, 1, 0xff, 0xd9]).toString('base64')
  }
  expect(validatePlanPhotos(JSON.stringify([photo]))).toBe(true)
  expect(validatePlanPhotos('[]')).toBe(true)
  expect(validatePlanPhotos(null)).toBe(true)
  for (const value of [
    42,
    '',
    '{}',
    '[',
    JSON.stringify([photo, photo]),
    JSON.stringify(
      Array.from({ length: 4 }, () => ({ ...photo, id: crypto.randomUUID() }))
    ),
    JSON.stringify([
      { ...photo, jpeg: Buffer.from('not a JPEG').toString('base64') }
    ]),
    JSON.stringify([{ ...photo, jpeg: 'A'.repeat(160_004) }])
  ]) {
    expect(validatePlanPhotos(value)).toBe(false)
  }
})
