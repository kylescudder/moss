import type { PoolClient } from 'pg'
import { z } from 'zod'

export class RequestError extends Error {
  constructor(
    public code: string,
    public status: number,
    message: string
  ) {
    super(message)
  }
}

const columns = {
  profiles: ['username', 'display_name', 'deleted_at'],
  trips: [
    'title',
    'destination',
    'starts_at',
    'ends_at',
    'notes',
    'deleted_at'
  ],
  itinerary_items: [
    'trip_id',
    'kind',
    'title',
    'location_name',
    'starts_at',
    'ends_at',
    'notes',
    'sort_order',
    'deleted_at'
  ]
} as const

export const writableTable = z.enum(['profiles', 'trips', 'itinerary_items'])
const upload = z
  .object({
    table: writableTable,
    id: z.uuid(),
    op: z.enum(['put', 'patch', 'delete']),
    data: z
      .record(z.string(), z.union([z.string(), z.number(), z.null()]))
      .default({})
  })
  .strict()

// Every statement uses the restricted runtime role and transaction-local user ID.
// RLS protects reads and mutations even if a future query omits its owner filter.
export async function uploadChange(
  client: PoolClient,
  userID: string,
  input: unknown
) {
  const parsed = upload.safeParse(input)
  if (!parsed.success)
    throw new RequestError('invalid_request', 422, 'Invalid sync change.')
  const { table, id, op, data } = parsed.data
  if (table === 'trips' && op === 'put') {
    // Serialize the existence check with the transactional lifetime ledger.
    await client.query('select id from profiles where id = $1 for update', [
      userID
    ])
  }
  if (
    (data.owner_id !== undefined && data.owner_id !== userID) ||
    (table === 'profiles' && id !== userID)
  ) {
    throw new RequestError(
      'MX003',
      403,
      'Record owner does not match the signed-in account.'
    )
  }
  const allowed = new Set<string>(columns[table])
  const ignored = new Set(['id', 'owner_id', 'created_at', 'updated_at'])
  if (Object.keys(data).some((key) => !allowed.has(key) && !ignored.has(key))) {
    throw new RequestError('invalid_request', 422, 'Unexpected record field.')
  }
  const existing = await client.query(`select id from ${table} where id = $1`, [
    id
  ])
  if (op !== 'put' && existing.rowCount !== 1)
    throw new RequestError('MX003', 403, 'Record is unavailable.')
  if (op === 'delete') {
    if (table === 'profiles')
      throw new RequestError(
        'MX003',
        403,
        'Use account deletion to remove a profile.'
      )
    await client.query(
      `update ${table} set deleted_at = coalesce(deleted_at, statement_timestamp()) where id = $1`,
      [id]
    )
    return
  }
  // An earlier batch may have inserted the trip before a later item failed.
  // A replay succeeds only for a currently existing row visible to this owner.
  if (table === 'trips' && op === 'put' && existing.rowCount === 1) return
  const keys = Object.keys(data).filter((key) => allowed.has(key))
  const values: unknown[] = keys.map((key) => data[key])
  if (existing.rowCount === 1) {
    if (!keys.length) return
    await client.query(
      `update ${table} set ${keys.map((key, i) => `"${key}" = $${i + 2}`).join(', ')} where id = $1`,
      [id, ...values]
    )
  } else {
    const names = ['id', ...(table === 'profiles' ? [] : ['owner_id']), ...keys]
    const params = [id, ...(table === 'profiles' ? [] : [userID]), ...values]
    await client.query(
      `insert into ${table} (${names.map((n) => `"${n}"`).join(',')}) values (${params.map((_, i) => '$' + (i + 1)).join(',')})`,
      params
    )
  }
}
