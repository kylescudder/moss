import { Worker } from 'node:worker_threads'
import {
  PowerSyncDatabase,
  Schema,
  Table,
  column,
  type PowerSyncBackendConnector
} from '@powersync/node'
import { Pool } from 'pg'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Test fixtures only; never point this at the production database.
if (
  !process.env.TEST_DATABASE_URL ||
  !process.env.TEST_API_URL ||
  !process.env.TEST_SYNC_URL
)
  throw new Error('TEST_DATABASE_URL, TEST_API_URL, TEST_SYNC_URL are required')
const api = process.env.TEST_API_URL,
  endpoint = process.env.TEST_SYNC_URL
const pool = new Pool({
  connectionString: process.env.TEST_DATABASE_URL,
  max: 1
})
const directory = await mkdtemp(join(tmpdir(), 'moss-sync-'))
const schema = new Schema({
  profiles: new Table({ display_name: column.text }),
  trips: new Table({
    owner_id: column.text,
    title: column.text,
    destination: column.text,
    deleted_at: column.text
  })
})
const database = (name: string) =>
  new PowerSyncDatabase({
    schema,
    database: {
      dbFilename: join(directory, name),
      implementation: { type: 'node:sqlite' },
      openWorker: (_url, options) =>
        new Worker(new URL('./powersync-worker.ts', import.meta.url), options)
    }
  })
const offline = database('offline.sqlite'),
  fresh = database('fresh.sqlite'),
  other = database('other.sqlite')
try {
  const fixture = async (email: string) =>
    (
      await pool.query(
        'select u.id,s.token from auth_user u join auth_session s on s.user_id=u.id where u.email=$1 limit 1',
        [email]
      )
    ).rows[0] as { id: string; token: string }
  const owner = await fixture('owner@example.test'),
    stranger = await fixture('other@example.test')
  const request = async (path: string, token: string, body?: unknown) => {
    const response = await fetch(api + path, {
      method: body ? 'POST' : 'GET',
      headers: {
        authorization: 'Bearer ' + token,
        'content-type': 'application/json'
      },
      ...(body ? { body: JSON.stringify(body) } : {})
    })
    if (!response.ok)
      throw new Error(`Fixture API ${path} returned ${response.status}`)
    return response.json()
  }
  const connector = (account: {
    id: string
    token: string
  }): PowerSyncBackendConnector => ({
    fetchCredentials: async () => ({
      endpoint,
      token: (await request('/api/auth/token', account.token)).token
    }),
    uploadData: async (db) => {
      const batch = await db.getCrudBatch()
      if (!batch) return
      for (const entry of batch.crud)
        await request('/api/sync/upload', account.token, {
          table: entry.table,
          id: entry.id,
          op: entry.op.toLowerCase(),
          data: entry.opData ?? {}
        })
      await batch.complete()
    }
  })
  const id = crypto.randomUUID()
  // Start offline with a queued write.
  await offline.execute(
    'insert into trips(id,owner_id,title,destination) values(?,?,?,?)',
    [id, owner.id, 'Offline queue fixture', 'Test']
  )
  await offline.close()
  // A second process-like open retains the actual SQLite queue.
  const reopened = database('offline.sqlite')
  try {
    if (!(await reopened.getCrudBatch())?.crud.length)
      throw new Error('Offline queue was lost')
    await connector(owner).uploadData(reopened)
    if (await reopened.getCrudBatch())
      throw new Error('Accepted queue did not drain')
    await fresh.connect(connector(owner))
    await fresh.waitForFirstSync({ signal: AbortSignal.timeout(20_000) })
    if (!(await fresh.getOptional('select id from trips where id=?', [id])))
      throw new Error('Fresh service checkpoint omitted the queued write')
    await other.connect(connector(stranger))
    await other.waitForFirstSync({ signal: AbortSignal.timeout(20_000) })
    if (
      (await other.getAll('select id from trips where owner_id=?', [owner.id]))
        .length
    )
      throw new Error('Cross-account sync exposure')
    console.log(
      JSON.stringify({
        offlineQueue: true,
        freshCheckpoint: true,
        ownerIsolation: true
      })
    )
  } finally {
    await reopened.close()
  }
} finally {
  await offline.close()
  await fresh.close()
  await other.close()
  await pool.end()
  await rm(directory, { recursive: true, force: true })
}
