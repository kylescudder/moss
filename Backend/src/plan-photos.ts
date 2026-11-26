import { z } from 'zod'

const photos = z
  .array(
    z
      .object({
        id: z.uuid(),
        jpeg: z
          .string()
          .max(160_000)
          .regex(/^[A-Za-z0-9+/]+={0,2}$/)
          .refine((value) => {
            const bytes = Buffer.from(value, 'base64')
            return (
              bytes.length > 4 &&
              bytes.length <= 120_000 &&
              bytes.toString('base64') === value &&
              bytes[0] === 0xff &&
              bytes[1] === 0xd8 &&
              bytes[bytes.length - 2] === 0xff &&
              bytes[bytes.length - 1] === 0xd9
            )
          })
      })
      .strict()
  )
  .max(3)
  .refine(
    (items) =>
      new Set(items.map((item) => item.id.toLowerCase())).size === items.length
  )

export function validatePlanPhotos(value: unknown): boolean {
  if (value === null) return true
  if (typeof value !== 'string' || Buffer.byteLength(value) > 500_000)
    return false
  try {
    return photos.safeParse(JSON.parse(value)).success
  } catch {
    return false
  }
}
