import { afterAll, beforeAll, expect, test } from 'bun:test'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import { connectDatabase } from '../src/database'
import { createAuth } from '../src/auth'

const url = process.env.TEST_DATABASE_URL
if (!url)
  throw new Error(
    'TEST_DATABASE_URL must point to a disposable PostgreSQL database'
  )
const { db, pool } = connectDatabase(url)
const sent: { email: string; url: string }[] = []
const auth = createAuth(db, {
  baseURL: 'http://localhost:3147',
  secret: 'moss-local-integration-test-secret-123456789',
  powerSyncURL: 'http://localhost:8080',
  sendEmail: async (email: string, _kind: string, url: string) => {
    sent.push({ email, url })
  }
})

beforeAll(async () => {
  await migrate(db, { migrationsFolder: './drizzle' })
  await pool.query(
    "insert into recovery_lease values (1, clock_timestamp(), clock_timestamp(), 'test-snapshot') on conflict (id) do update set snapshot_started_at = excluded.snapshot_started_at, verified_at = excluded.verified_at"
  )
  await pool.query(
    'truncate auth_user, auth_session, auth_account, auth_verification, auth_rate_limit cascade'
  )
})
afterAll(() => pool.end())

let requestNumber = 0
function request(path: string, body?: unknown, token?: string) {
  return new Request('http://localhost:3147/api/auth/' + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      'cf-connecting-ip': '192.0.2.' + ((++requestNumber % 250) + 1),
      'content-type': 'application/json',
      origin: 'http://localhost:3147',
      ...(token ? { authorization: 'Bearer ' + token } : {})
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
}

test('a verified email/password account can sign in using a native bearer session', async () => {
  const signup = await auth.handler(
    request('sign-up/email', {
      email: 'native@example.test',
      password: 'travel-password-123',
      name: 'Native',
      callbackURL: 'moss://auth-callback'
    })
  )
  expect(signup.status).toBe(200)
  expect(sent).toHaveLength(1)
  const verify = await auth.handler(new Request(sent[0]!.url))
  expect([200, 302]).toContain(verify.status)
  const signin = await auth.handler(
    request('sign-in/email', {
      email: 'native@example.test',
      password: 'travel-password-123'
    })
  )
  expect(signin.status).toBe(200)
  const token = signin.headers.get('set-auth-token')
  expect(token).toBeTruthy()
  const session = await auth.api.getSession({
    headers: new Headers({ authorization: 'Bearer ' + token })
  })
  expect(session?.user.email).toBe('native@example.test')
  expect(session?.user.id).toMatch(/^[0-9a-f-]{36}$/)
})

test('application data requires authentication', async () => {
  const { createApplication } = await import('../src/application')
  const app = createApplication({ auth, pool })
  const response = await app(new Request('http://localhost:3147/api/me'))
  expect(response.status).toBe(401)
})

async function nativeAccount(email: string) {
  const signup = await auth.handler(
    request('sign-up/email', {
      email,
      password: 'travel-password-123',
      name: 'Test',
      callbackURL: 'moss://auth-callback'
    })
  )
  expect(signup.status).toBe(200)
  const mail = sent.findLast((m) => m.email === email)!
  await auth.handler(new Request(mail.url))
  const signin = await auth.handler(
    request('sign-in/email', { email, password: 'travel-password-123' })
  )
  const token = signin.headers.get('set-auth-token')!
  const session = await auth.api.getSession({
    headers: new Headers({ authorization: 'Bearer ' + token })
  })
  return { token, id: session!.user.id }
}

async function dataRequest(path: string, token: string, body?: unknown) {
  const { createApplication } = await import('../src/application')
  return createApplication({ auth, pool })(
    new Request('http://localhost:3147' + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {
        authorization: 'Bearer ' + token,
        'content-type': 'application/json'
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    })
  )
}

test('an owner can upload and read a trip but another account cannot read or change it', async () => {
  const owner = await nativeAccount('owner@example.test')
  const other = await nativeAccount('other@example.test')
  const id = crypto.randomUUID()
  const inserted = await dataRequest('/api/sync/upload', owner.token, {
    table: 'trips',
    id,
    op: 'put',
    data: { owner_id: owner.id, title: 'Test trip', destination: 'Lisbon' }
  })
  expect(inserted.status).toBe(200)
  const read = await dataRequest('/api/data/trips/' + id, owner.token)
  expect((await read.json()).title).toBe('Test trip')
  const forbiddenRead = await dataRequest('/api/data/trips/' + id, other.token)
  expect(forbiddenRead.status).toBe(404)
  const forbiddenWrite = await dataRequest('/api/sync/upload', other.token, {
    table: 'trips',
    id,
    op: 'patch',
    data: { title: 'Stolen' }
  })
  expect(forbiddenWrite.status).toBe(403)
  const forbiddenDelete = await dataRequest('/api/sync/upload', other.token, {
    table: 'trips',
    id,
    op: 'delete'
  })
  expect(forbiddenDelete.status).toBe(403)
  const unchanged = await dataRequest('/api/data/trips/' + id, owner.token)
  const body = await unchanged.json()
  expect(body.title).toBe('Test trip')
  expect(body.deleted_at).toBeNull()
})

test('itinerary items belong to a trip the uploader owns', async () => {
  const owner = await nativeAccount('itinerary-owner@example.test')
  const other = await nativeAccount('itinerary-other@example.test')
  const tripID = crypto.randomUUID()
  expect(
    (
      await dataRequest('/api/sync/upload', owner.token, {
        table: 'trips',
        id: tripID,
        op: 'put',
        data: { title: 'Owned trip', destination: 'Kyoto' }
      })
    ).status
  ).toBe(200)
  const itemID = crypto.randomUUID()
  const item = {
    table: 'itinerary_items',
    id: itemID,
    op: 'put',
    data: {
      trip_id: tripID,
      kind: 'transport',
      title: 'Train',
      location_name: 'Kyoto',
      destination_name: 'Osaka',
      transport_mode: 'transit',
      starts_at: '2026-12-01T19:00:00Z',
      sort_order: 3
    }
  }
  expect(
    (await dataRequest('/api/sync/upload', owner.token, item)).status
  ).toBe(200)
  const read = await (
    await dataRequest('/api/data/itinerary_items/' + itemID, owner.token)
  ).json()
  expect(read).toMatchObject({
    owner_id: owner.id,
    trip_id: tripID,
    kind: 'transport',
    sort_order: 3,
    location_name: 'Kyoto',
    destination_name: 'Osaka',
    transport_mode: 'transit'
  })
  for (const destination of ['Nara', null]) {
    expect(
      (
        await dataRequest('/api/sync/upload', owner.token, {
          table: 'itinerary_items',
          id: itemID,
          op: 'patch',
          data: { destination_name: destination }
        })
      ).status
    ).toBe(200)
    expect(
      await (
        await dataRequest('/api/data/itinerary_items/' + itemID, owner.token)
      ).json()
    ).toMatchObject({ location_name: 'Kyoto', destination_name: destination })
  }
  for (const mode of ['driving', 'walking', 'cycling', null]) {
    expect(
      (
        await dataRequest('/api/sync/upload', owner.token, {
          table: 'itinerary_items',
          id: itemID,
          op: 'patch',
          data: { transport_mode: mode }
        })
      ).status
    ).toBe(200)
    expect(
      await (
        await dataRequest('/api/data/itinerary_items/' + itemID, owner.token)
      ).json()
    ).toMatchObject({ transport_mode: mode })
  }
  expect(
    (
      await dataRequest('/api/sync/upload', owner.token, {
        table: 'itinerary_items',
        id: itemID,
        op: 'patch',
        data: { transport_mode: 'teleport' }
      })
    ).status
  ).toBe(422)
  // Another account cannot attach items to, read, or edit this trip's items.
  const foreign = await dataRequest('/api/sync/upload', other.token, {
    ...item,
    id: crypto.randomUUID()
  })
  expect(foreign.status).toBe(422)
  expect((await foreign.json()).code).toBe('MX003')
  expect(
    (await dataRequest('/api/data/itinerary_items/' + itemID, other.token))
      .status
  ).toBe(404)
  expect(
    (
      await dataRequest('/api/sync/upload', other.token, {
        table: 'itinerary_items',
        id: itemID,
        op: 'patch',
        data: { title: 'Stolen' }
      })
    ).status
  ).toBe(403)
  // An owner cannot move an item onto a trip that does not exist.
  const moved = await dataRequest('/api/sync/upload', owner.token, {
    table: 'itinerary_items',
    id: itemID,
    op: 'patch',
    data: { trip_id: crypto.randomUUID() }
  })
  expect(moved.status).toBe(422)
  const invalidKind = await dataRequest('/api/sync/upload', owner.token, {
    ...item,
    id: crypto.randomUUID(),
    data: { ...item.data, kind: 'cruise' }
  })
  expect(invalidKind.status).toBe(422)
  expect((await invalidKind.json()).code).toBe('23514')
  // Item creation never consumes the trip allowance.
  expect(
    (await (await dataRequest('/api/trips/status', owner.token)).json())
      .lifetime_count
  ).toBe(1)
})

test('sync upload accepts only the writable tables and their columns', async () => {
  const account = await nativeAccount('allowlist@example.test')
  const tripID = crypto.randomUUID()
  for (const change of [
    { table: 'trip_creation_quotas', id: account.id, op: 'patch', data: {} },
    { table: 'iap_entitlements', id: account.id, op: 'put', data: {} },
    { table: 'device_tokens', id: crypto.randomUUID(), op: 'put', data: {} },
    {
      table: 'trips',
      id: tripID,
      op: 'put',
      data: { title: 'Trip', destination: 'Rome', created_by: 'x' }
    },
    { table: 'trips', id: 'not-a-uuid', op: 'put', data: {} },
    { table: 'trips', id: tripID, op: 'upsert', data: {} },
    { table: 'trips', id: tripID, op: 'put', data: {}, extra: true }
  ]) {
    const response = await dataRequest(
      '/api/sync/upload',
      account.token,
      change
    )
    expect(response.status).toBe(422)
    expect((await response.json()).code).toBe('invalid_request')
  }
  const otherOwner = await dataRequest('/api/sync/upload', account.token, {
    table: 'trips',
    id: tripID,
    op: 'put',
    data: { owner_id: crypto.randomUUID(), title: 'Trip', destination: 'Rome' }
  })
  expect(otherOwner.status).toBe(403)
  expect((await otherOwner.json()).code).toBe('MX003')
  const otherProfile = await dataRequest('/api/sync/upload', account.token, {
    table: 'profiles',
    id: crypto.randomUUID(),
    op: 'patch',
    data: { display_name: 'Not me' }
  })
  expect(otherProfile.status).toBe(403)
  const profileDelete = await dataRequest('/api/sync/upload', account.token, {
    table: 'profiles',
    id: account.id,
    op: 'delete'
  })
  expect(profileDelete.status).toBe(403)
  const rename = await dataRequest('/api/sync/upload', account.token, {
    table: 'profiles',
    id: account.id,
    op: 'patch',
    data: { display_name: 'Traveller' }
  })
  expect(rename.status).toBe(200)
  expect(
    (await (await dataRequest('/api/me', account.token)).json()).display_name
  ).toBe('Traveller')
  expect(
    (await (await dataRequest('/api/trips/status', account.token)).json())
      .lifetime_count
  ).toBe(0)
})

test('concurrent new trips enforce two lifetime creations and duplicate replay consumes no allowance', async () => {
  const owner = await nativeAccount('quota@example.test')
  const trips = Array.from({ length: 8 }, () => ({
    table: 'trips',
    id: crypto.randomUUID(),
    op: 'put',
    data: {
      owner_id: owner.id,
      title: 'Weekend away',
      destination: 'Porto'
    }
  }))
  const results = await Promise.all(
    trips.map(async (trip) => ({
      trip,
      response: await dataRequest('/api/sync/upload', owner.token, trip)
    }))
  )
  const accepted = results.filter((r) => r.response.status === 200)
  expect(accepted).toHaveLength(2)
  const rejected = results.filter((r) => r.response.status !== 200)
  expect(
    await Promise.all(
      rejected.map((r) => r.response.json().then((b) => b.code))
    )
  ).toEqual(Array(6).fill('MX001'))
  const replay = await Promise.all(
    Array.from({ length: 3 }, () =>
      dataRequest('/api/sync/upload', owner.token, accepted[0]!.trip)
    )
  )
  expect(replay.map((r) => r.status)).toEqual([200, 200, 200])
  const status = await dataRequest('/api/trips/status', owner.token)
  expect(await status.json()).toEqual({
    lifetime_count: 2,
    free_limit: 2,
    has_verified_entitlement: false
  })
  const deleted = await dataRequest('/api/sync/upload', owner.token, {
    table: 'trips',
    id: accepted[0]!.trip.id,
    op: 'delete'
  })
  expect(deleted.status).toBe(200)
  const recreate = await dataRequest(
    '/api/sync/upload',
    owner.token,
    accepted[0]!.trip
  )
  expect(recreate.status).toBe(200)
  const tombstone = await dataRequest(
    '/api/data/trips/' + accepted[0]!.trip.id,
    owner.token
  )
  expect((await tombstone.json()).deleted_at).toBeTruthy()
  // Deleting a trip never restores the allowance.
  const afterDelete = await dataRequest('/api/sync/upload', owner.token, {
    ...accepted[0]!.trip,
    id: crypto.randomUUID()
  })
  expect(afterDelete.status).toBe(422)
  expect((await afterDelete.json()).code).toBe('MX001')
  // Historical hard-deleted IDs must still be rejected.
  await pool.query('delete from trips where id = $1', [accepted[0]!.trip.id])
  const hardDeletedReplay = await dataRequest(
    '/api/sync/upload',
    owner.token,
    accepted[0]!.trip
  )
  expect(hardDeletedReplay.status).toBe(422)
  const finalStatus = await dataRequest('/api/trips/status', owner.token)
  expect((await finalStatus.json()).lifetime_count).toBe(2)
})

test('a verified supporter entitlement lifts the free trip limit', async () => {
  const account = await nativeAccount('supporter@example.test')
  const create = () =>
    dataRequest('/api/sync/upload', account.token, {
      table: 'trips',
      id: crypto.randomUUID(),
      op: 'put',
      data: { title: 'Trip', destination: 'Oslo' }
    })
  expect((await create()).status).toBe(200)
  expect((await create()).status).toBe(200)
  expect((await create()).status).toBe(422)
  await pool.query(
    'select record_verified_iap_entitlement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',
    [
      account.id,
      'app.moss.supporter.monthly',
      'app.getmoss.moss',
      'original-supporter',
      'transaction-supporter',
      'active',
      new Date(Date.now() + 86_400_000),
      null,
      'Sandbox',
      new Date(),
      'device'
    ]
  )
  expect((await create()).status).toBe(200)
  expect(
    await (await dataRequest('/api/trips/status', account.token)).json()
  ).toEqual({
    lifetime_count: 3,
    free_limit: 2,
    has_verified_entitlement: true
  })
  await expect(
    pool.query(
      'select record_verified_iap_entitlement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',
      [
        account.id,
        'app.moss.other.product',
        'app.getmoss.moss',
        'o',
        't',
        'active',
        new Date(Date.now() + 86_400_000),
        null,
        'Sandbox',
        new Date(),
        'device'
      ]
    )
  ).rejects.toMatchObject({ code: 'MX005' })
})

test('missing recovery proof fails closed before signup and sync writes', async () => {
  await pool.query('delete from recovery_lease')
  try {
    const { createApplication } = await import('../src/application')
    const response = await createApplication({ auth, pool })(
      request('sign-up/email', {
        email: 'fenced@example.test',
        name: 'Fenced',
        password: 'travel-password-123'
      })
    )
    expect(response.status).toBe(503)
    const owner = await pool.query(
      "select id from auth_user where email = 'owner@example.test'"
    )
    const token = (
      await pool.query(
        'select token from auth_session where user_id = $1 limit 1',
        [owner.rows[0].id]
      )
    ).rows[0].token
    const upload = await dataRequest('/api/sync/upload', token, {
      table: 'trips',
      id: crypto.randomUUID(),
      op: 'put',
      data: { title: 'Fenced', destination: 'Test' }
    })
    expect(upload.status).toBe(503)
  } finally {
    await pool.query(
      "insert into recovery_lease values (1, clock_timestamp(), clock_timestamp(), 'test-snapshot')"
    )
  }
})

test('stale, future and failed backup proofs block writes and cannot be forged by the API role', async () => {
  for (const interval of ["interval '601 seconds'", "interval '-5 seconds'"]) {
    await pool.query(
      `update recovery_lease set snapshot_started_at = clock_timestamp() - ${interval}`
    )
    const response = await dataRequest('/api/sync/upload', 'invalid', {})
    expect(response.status).toBe(503)
  }
  await pool.query(
    "update recovery_lease set snapshot_started_at=clock_timestamp(), verified_at=clock_timestamp() - interval '1 minute'"
  )
  expect((await dataRequest('/api/sync/upload', 'invalid', {})).status).toBe(
    503
  )
  await pool.query(
    'update recovery_lease set snapshot_started_at=clock_timestamp(), verified_at=clock_timestamp()'
  )
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query('set local role moss_api')
    await expect(
      client.query(
        'update recovery_lease set snapshot_started_at=clock_timestamp()'
      )
    ).rejects.toMatchObject({ code: '42501' })
  } finally {
    await client.query('rollback')
    client.release()
  }
})

test('a write whose proof expires before COMMIT is rolled back', async () => {
  const client = await pool.connect()
  await pool.query(
    'update recovery_lease set snapshot_started_at=clock_timestamp(), verified_at=clock_timestamp()'
  )
  try {
    await client.query('begin')
    await client.query(
      "insert into auth_email_limit values ('commit-boundary',1,clock_timestamp())"
    )
    await pool.query(
      "update recovery_lease set snapshot_started_at=clock_timestamp() - interval '601 seconds'"
    )
    await expect(client.query('commit')).rejects.toMatchObject({
      code: 'DX006'
    })
  } finally {
    await client.query('rollback')
    client.release()
    await pool.query(
      'update recovery_lease set snapshot_started_at=clock_timestamp(), verified_at=clock_timestamp()'
    )
  }
  expect(
    (
      await pool.query(
        "select count(*)::int as count from auth_email_limit where key='commit-boundary'"
      )
    ).rows[0].count
  ).toBe(0)
})

test('password reset links are single-use and bcrypt password hashes remain supported', async () => {
  const account = await nativeAccount('reset@example.test')
  const hash = await Bun.password.hash('bcrypt-password-123', {
    algorithm: 'bcrypt',
    cost: 4
  })
  await pool.query(
    "update auth_account set password=$1 where user_id=$2 and provider_id='credential'",
    [hash, account.id]
  )
  const signin = await auth.handler(
    request('sign-in/email', {
      email: 'reset@example.test',
      password: 'bcrypt-password-123'
    })
  )
  expect(signin.status).toBe(200)
  const reset = await auth.handler(
    request('request-password-reset', {
      email: 'reset@example.test',
      redirectTo: 'moss://auth-callback?type=recovery'
    })
  )
  expect(reset.status).toBe(200)
  const mail = sent.findLast((m) => m.email === 'reset@example.test')!
  const redirect = await auth.handler(new Request(mail.url))
  const token = new URL(redirect.headers.get('location')!).searchParams.get(
    'token'
  )!
  expect(token).toBeTruthy()
  const change = () =>
    auth.handler(
      request('reset-password', { token, newPassword: 'new-password-123' })
    )
  expect((await change()).status).toBe(200)
  expect((await change()).status).toBe(400)
  expect(
    (
      await auth.handler(
        request('sign-in/email', {
          email: 'reset@example.test',
          password: 'new-password-123'
        })
      )
    ).status
  ).toBe(200)
})

test('off-site and malformed callback targets cannot receive auth links', async () => {
  for (const callbackURL of [
    'https://evil.test',
    '//evil.test',
    '/.//evil.test',
    '/\t/evil.test',
    '/\\evil.test',
    'moss://evil.test'
  ]) {
    const response = await auth.handler(
      request('sign-up/email', {
        email: 'redirect@example.test',
        password: 'travel-password-123',
        name: 'Test',
        callbackURL
      })
    )
    expect(response.status).toBe(400)
  }
})

test('JWKS and PowerSync JWT bind the authenticated original UUID, issuer and audience', async () => {
  const account = await nativeAccount('jwt@example.test')
  const response = await auth.handler(
    request('token', undefined, account.token)
  )
  expect(response.status).toBe(200)
  const { token } = await response.json()
  const jwks = await (await auth.handler(request('jwks'))).json()
  const { jwtVerify, createLocalJWKSet } = await import('jose')
  const { payload } = await jwtVerify(token, createLocalJWKSet(jwks), {
    issuer: 'http://localhost:3147',
    audience: 'http://localhost:8080'
  })
  expect(payload.sub).toBe(account.id)
  expect(payload.exp! - payload.iat!).toBe(300)
})

test('native Google codes require the original proof key and cannot be replayed', async () => {
  const { hash } = await import('../src/native-oauth')
  const account = await nativeAccount('pkce@example.test')
  const verifier = 'a'.repeat(64),
    code = 'only-this-code'
  await pool.query(
    "insert into native_codes values ($1,$2,$3,clock_timestamp()+interval '2 minutes')",
    [hash(code), hash(verifier), account.token]
  )
  expect(
    (
      await dataRequest('/api/native/exchange', '', {
        code,
        verifier: 'b'.repeat(64)
      })
    ).status
  ).toBe(401)
  const valid = await dataRequest('/api/native/exchange', '', {
    code,
    verifier
  })
  expect((await valid.json()).token).toBe(account.token)
  expect(
    (await dataRequest('/api/native/exchange', '', { code, verifier })).status
  ).toBe(401)
})

test('forged Apple transactions and notifications never create entitlement access', async () => {
  const account = await nativeAccount('forged@example.test')
  const encode = (value: unknown) =>
    Buffer.from(JSON.stringify(value)).toString('base64url')
  const forged =
    encode({ alg: 'none' }) +
    '.' +
    encode({
      environment: 'Sandbox',
      appAccountToken: account.id,
      productId: 'app.moss.supporter.monthly',
      bundleId: 'app.getmoss.moss'
    }) +
    '.forged'
  expect(
    (
      await dataRequest('/api/iap/transactions', account.token, {
        signedTransactionInfo: forged
      })
    ).status
  ).not.toBe(200)
  expect(
    (await dataRequest('/api/iap/notifications', '', { signedPayload: forged }))
      .status
  ).not.toBe(200)
  expect(
    (await (await dataRequest('/api/trips/status', account.token)).json())
      .has_verified_entitlement
  ).toBe(false)
})

test('the runtime cannot alter quota, verification evidence, or another account during deletion', async () => {
  const account = await nativeAccount('delete@example.test')
  const other = await nativeAccount('delete-other@example.test')
  const client = await pool.connect()
  for (const sql of [
    'update trip_creation_quotas set lifetime_count=0',
    'delete from trip_creation_events',
    "update iap_entitlements set status='active'",
    'select * from recovery_lease'
  ]) {
    try {
      await client.query('begin')
      await client.query('set local role moss_api')
      await expect(client.query(sql)).rejects.toMatchObject({ code: '42501' })
    } finally {
      await client.query('rollback')
    }
  }
  client.release()
  const { createApplication } = await import('../src/application')
  const app = createApplication({ auth, pool })
  expect(
    (
      await app(
        new Request('http://localhost:3147/api/account', {
          method: 'DELETE',
          headers: { authorization: 'Bearer ' + account.token }
        })
      )
    ).status
  ).toBe(200)
  expect((await dataRequest('/api/me', account.token)).status).toBe(401)
  expect((await dataRequest('/api/me', other.token)).status).toBe(200)
})

test('email budgets count delivered mail, keep recipient cooldown silent, and cap the app total', async () => {
  const { createEmailSender } = await import('../src/email')
  await pool.query('truncate auth_email_limit')
  let attempts = 0
  const send = (async () => {
    attempts++
    return new Response(null, { status: attempts === 1 ? 503 : 201 })
  }) as unknown as typeof fetch
  const sender = createEmailSender(
    pool,
    {
      key: 'test-only',
      from: 'hello@example.test',
      origin: 'https://api.example.test',
      dailyLimit: 1
    },
    send
  )
  const link = 'https://api.example.test/api/auth/verify-email?token=fixture'
  await expect(sender('first@example.test', 'verify', link)).rejects.toThrow(
    'Email delivery unavailable'
  )
  await sender('first@example.test', 'verify', link)
  // With a larger app budget, the recipient-specific limit is a silent no-send.
  const cooldown = createEmailSender(
    pool,
    {
      key: 'test-only',
      from: 'hello@example.test',
      origin: 'https://api.example.test',
      dailyLimit: 40
    },
    send
  )
  await cooldown('first@example.test', 'verify', link)
  expect(attempts).toBe(2)
  await expect(sender('second@example.test', 'verify', link)).rejects.toThrow(
    'Daily email budget exhausted'
  )
})

test('the verified-entitlement SQL boundary preserves revocation/event ordering and current expiry', async () => {
  const account = await nativeAccount('ordered-entitlement@example.test')
  const now = Date.now()
  const record = async (
    status: string,
    signed: number,
    expires = now + 86_400_000
  ) =>
    pool.query(
      'select record_verified_iap_entitlement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',
      [
        account.id,
        'app.moss.supporter.monthly',
        'app.getmoss.moss',
        'original',
        'transaction',
        status,
        new Date(expires),
        status === 'revoked' ? new Date(now) : null,
        'Sandbox',
        new Date(signed),
        'notification'
      ]
    )
  const active = async () =>
    (await (await dataRequest('/api/trips/status', account.token)).json())
      .has_verified_entitlement
  await record('active', now)
  expect(await active()).toBe(true)
  await record('revoked', now + 1000)
  await record('active', now)
  expect(await active()).toBe(false)
  await record('active', now + 1000)
  expect(await active()).toBe(false)
  await record('active', now + 2000)
  expect(await active()).toBe(true)
  await record('active', now + 3000, now - 1000)
  expect(await active()).toBe(false)
})

test('device unregister removes only the authenticated owner token and is idempotent', async () => {
  const owner = await nativeAccount('device-owner@example.test')
  const other = await nativeAccount('device-other@example.test')
  const token = 'ab'.repeat(32)
  for (const account of [owner, other]) {
    expect(
      (
        await dataRequest('/api/devices', account.token, {
          apns_token: token,
          device_name: 'Test device',
          bundle_id: 'app.getmoss.moss',
          environment: 'sandbox'
        })
      ).status
    ).toBe(200)
  }
  const { createApplication } = await import('../src/application')
  const app = createApplication({ auth, pool })
  const unregister = (bearer: string, apnsToken = token) =>
    app(
      new Request('http://localhost:3147/api/devices', {
        method: 'DELETE',
        headers: {
          authorization: 'Bearer ' + bearer,
          'content-type': 'application/json'
        },
        body: JSON.stringify({ apns_token: apnsToken })
      })
    )
  expect((await unregister('')).status).toBe(401)
  expect((await unregister(owner.token, 'invalid')).status).toBe(400)
  expect((await unregister(owner.token)).status).toBe(200)
  expect((await unregister(owner.token)).status).toBe(200)
  const remaining = await pool.query(
    'select user_id from device_tokens where apns_token=$1',
    [token]
  )
  expect(remaining.rows).toEqual([{ user_id: other.id }])
})

test('admin premium access bypasses the cap and revocation restores it without resetting usage', async () => {
  const owner = await nativeAccount('premium-access@example.test')
  const other = await nativeAccount('premium-other@example.test')
  const status = async (token = owner.token) =>
    (await dataRequest('/api/trips/status', token)).json()
  const create = () =>
    dataRequest('/api/sync/upload', owner.token, {
      table: 'trips',
      id: crypto.randomUUID(),
      op: 'put',
      data: { title: 'Gifted trip', destination: 'Lisbon' }
    })
  expect((await status()).has_verified_entitlement).toBe(false)
  await pool.query(
    'update profiles set is_premium_account = true where id = $1',
    [owner.id]
  )
  expect((await status()).has_verified_entitlement).toBe(true)
  expect((await status(other.token)).has_verified_entitlement).toBe(false)
  for (let i = 0; i < 3; i++) expect((await create()).status).toBe(200)
  expect((await status()).lifetime_count).toBe(3)
  await pool.query(
    'update profiles set is_premium_account = false where id = $1',
    [owner.id]
  )
  expect((await status()).has_verified_entitlement).toBe(false)
  const rejected = await create()
  expect(rejected.status).toBe(422)
  expect((await rejected.json()).code).toBe('MX001')
  expect((await status()).lifetime_count).toBe(3)
})

test('premium access cannot be self-granted through sync or request-role SQL', async () => {
  const owner = await nativeAccount('premium-forgery@example.test')
  const forged = await dataRequest('/api/sync/upload', owner.token, {
    table: 'profiles',
    id: owner.id,
    op: 'patch',
    data: { is_premium_account: 1 }
  })
  expect(forged.status).toBe(422)
  const edit = await dataRequest('/api/sync/upload', owner.token, {
    table: 'profiles',
    id: owner.id,
    op: 'patch',
    data: { display_name: 'Still editable' }
  })
  expect(edit.status).toBe(200)
  const client = await pool.connect()
  try {
    for (const sql of [
      'update profiles set is_premium_account = true where id = $1',
      'insert into profiles (id, is_premium_account) values ($1, true)'
    ]) {
      await client.query('begin')
      await client.query('set local role moss_api')
      await client.query("select set_config('moss.user_id', $1, true)", [
        owner.id
      ])
      await expect(client.query(sql, [owner.id])).rejects.toMatchObject({
        code: '42501'
      })
      await client.query('rollback')
    }
  } finally {
    await client.query('rollback')
    client.release()
  }
})

test('all plan types persist photos, preserve them through older-client edits, and allow removal', async () => {
  const owner = await nativeAccount('photos-owner@example.test')
  const other = await nativeAccount('photos-other@example.test')
  const tripID = crypto.randomUUID()
  expect(
    (
      await dataRequest('/api/sync/upload', owner.token, {
        table: 'trips',
        id: tripID,
        op: 'put',
        data: { title: 'Photo trip', destination: 'Lisbon' }
      })
    ).status
  ).toBe(200)
  const photos = JSON.stringify([
    {
      id: crypto.randomUUID(),
      jpeg: Buffer.from([255, 216, 1, 255, 217]).toString('base64')
    }
  ])
  for (const kind of [
    'flight',
    'lodging',
    'food',
    'activity',
    'transport',
    'note'
  ]) {
    const id = crypto.randomUUID()
    const patch = (data: unknown, token = owner.token) =>
      dataRequest('/api/sync/upload', token, {
        table: 'itinerary_items',
        id,
        op: 'patch',
        data
      })
    const read = async () =>
      (await dataRequest('/api/data/itinerary_items/' + id, owner.token)).json()
    expect(
      (
        await dataRequest('/api/sync/upload', owner.token, {
          table: 'itinerary_items',
          id,
          op: 'put',
          data: { trip_id: tripID, title: 'Plan', kind, photos_json: photos }
        })
      ).status
    ).toBe(200)
    expect(await read()).toMatchObject({ kind, photos_json: photos })
    expect((await patch({ title: 'Updated title' })).status).toBe(200)
    expect(await read()).toMatchObject({ photos_json: photos })
    expect((await patch({ photos_json: '[]' }, other.token)).status).not.toBe(
      200
    )
    expect(
      (await dataRequest('/api/data/itinerary_items/' + id, other.token)).status
    ).not.toBe(200)
    expect((await patch({ photos_json: '[invalid]' })).status).toBe(422)
    expect(await read()).toMatchObject({ photos_json: photos })
    expect((await patch({ photos_json: '[]' })).status).toBe(200)
    expect(await read()).toMatchObject({ photos_json: '[]' })
  }
})
