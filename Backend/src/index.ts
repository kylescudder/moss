import { connectDatabase } from './database'
import { createAuth } from './auth'
import { createApplication, transaction } from './application'
import { createEmailSender } from './email'
import { loadSettings } from './settings'
import { NotificationSpool } from './notification-spool'
import { processNotification } from './iap'

const settings = loadSettings()
const { db, pool } = connectDatabase(settings.DATABASE_URL)
const spool = new NotificationSpool(settings.NOTIFICATION_SPOOL)
const sendEmail = createEmailSender(pool, {
  key: settings.BREVO_API_KEY,
  from: settings.AUTH_EMAIL_FROM,
  dailyLimit: settings.AUTH_EMAIL_DAILY_LIMIT,
  origin: new URL(settings.BETTER_AUTH_URL).origin
})
const auth = createAuth(db, {
  baseURL: settings.BETTER_AUTH_URL,
  secret: settings.BETTER_AUTH_SECRET,
  powerSyncURL: settings.POWERSYNC_URL,
  google: {
    clientId: settings.GOOGLE_CLIENT_ID,
    clientSecret: settings.GOOGLE_CLIENT_SECRET
  },
  apple: {
    clientId: settings.APPLE_CLIENT_ID,
    clientSecret: settings.APPLE_CLIENT_SECRET,
    appBundleIdentifier: 'app.getmoss.moss'
  },
  sendEmail
})
const app = createApplication({
  auth,
  pool,
  origin: settings.BETTER_AUTH_URL,
  appleEnvironments: settings.APPLE_ENVIRONMENTS,
  spool,
  sendEmail
})
const server = Bun.serve({
  port: settings.PORT,
  hostname: '0.0.0.0',
  maxRequestBodySize: 128 * 1024,
  idleTimeout: 60,
  fetch: app
})
let replaying = false
const timer = setInterval(async () => {
  if (replaying) return
  replaying = true
  try {
    await spool.replay((payload) =>
      transaction(pool, (c) =>
        processNotification(c, payload, settings.APPLE_ENVIRONMENTS)
      )
    )
  } catch {
    /* Retained bytes retry after recovery/identity import completes. */
  } finally {
    replaying = false
  }
}, 30_000)
process.on('SIGTERM', async () => {
  clearInterval(timer)
  await server.stop()
  await pool.end()
})
