import { z } from 'zod'
const https = z.url().refine((value) => new URL(value).protocol === 'https:')
export function loadSettings(
  env: Record<string, string | undefined> = process.env
) {
  const parsed = z
    .object({
      NODE_ENV: z
        .enum(['production', 'test', 'development'])
        .default('production'),
      DATABASE_URL: z.string().min(1),
      BETTER_AUTH_URL: z.url(),
      BETTER_AUTH_SECRET: z.string().min(32),
      POWERSYNC_URL: z.url(),
      BREVO_API_KEY: z.string().min(1),
      AUTH_EMAIL_FROM: z.email(),
      AUTH_EMAIL_DAILY_LIMIT: z.coerce
        .number()
        .int()
        .positive()
        .max(300)
        .default(40),
      APPLE_APP_ID: z.coerce.number().int().positive(),
      APPLE_ENVIRONMENTS: z
        .string()
        .transform((value) => value.split(',').map((v) => v.trim()))
        .pipe(z.array(z.enum(['Production', 'Sandbox'])).min(1)),
      APPLE_CLIENT_ID: z.string().min(1),
      APPLE_CLIENT_SECRET: z.string().min(1),
      GOOGLE_CLIENT_ID: z.string().min(1),
      GOOGLE_CLIENT_SECRET: z.string().min(1),
      NOTIFICATION_SPOOL: z.string().min(1),
      PORT: z.coerce.number().int().min(1024).max(65535).default(3147)
    })
    .safeParse(env)
  if (!parsed.success)
    throw new Error(
      'Invalid settings: ' +
        parsed.error.issues.map((i) => i.path.join('.')).join(', ')
    )
  const value = parsed.data
  if (
    value.NODE_ENV === 'production' &&
    (!https.safeParse(value.BETTER_AUTH_URL).success ||
      !https.safeParse(value.POWERSYNC_URL).success)
  )
    throw new Error('Production endpoints require HTTPS')
  return value
}
