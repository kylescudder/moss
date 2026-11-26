import { afterAll, beforeAll, expect, test } from 'bun:test'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import { connectDatabase } from '../src/database'
import { createAuth } from '../src/auth'
import { createApplication } from '../src/application'

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
const invites: {
  email: string
  url: string
  invite: { inviter: string; target: string; senderID: string }
}[] = []
let emailDown = false
const app = createApplication({
  auth,
  pool,
  sendEmail: async (email, _kind, url, invite) => {
    if (emailDown) throw new Error('Email delivery unavailable')
    invites.push({ email, url, invite })
  }
})

beforeAll(async () => {
  await migrate(db, { migrationsFolder: './drizzle' })
  await pool.query(
    "insert into recovery_lease values (1, clock_timestamp(), clock_timestamp(), 'test-snapshot') on conflict (id) do update set snapshot_started_at = excluded.snapshot_started_at, verified_at = excluded.verified_at"
  )
})
afterAll(() => pool.end())

let requestNumber = 0
function authRequest(path: string, body: unknown) {
  return new Request('http://localhost:3147/api/auth/' + path, {
    method: 'POST',
    headers: {
      'cf-connecting-ip': '198.51.100.' + ((++requestNumber % 250) + 1),
      'content-type': 'application/json',
      origin: 'http://localhost:3147'
    },
    body: JSON.stringify(body)
  })
}

const unique = () => crypto.randomUUID().slice(0, 8)

async function signUp(email: string, name: string) {
  const signup = await auth.handler(
    authRequest('sign-up/email', {
      email,
      password: 'travel-password-123',
      name,
      callbackURL: 'moss://auth-callback'
    })
  )
  expect(signup.status).toBe(200)
}

async function verifyAndSignIn(email: string) {
  const mail = sent.findLast((m) => m.email === email)!
  await auth.handler(new Request(mail.url))
  const signin = await auth.handler(
    authRequest('sign-in/email', { email, password: 'travel-password-123' })
  )
  const token = signin.headers.get('set-auth-token')!
  const session = await auth.api.getSession({
    headers: new Headers({ authorization: 'Bearer ' + token })
  })
  return { token, id: session!.user.id, email }
}

async function account(label: string) {
  const email = `${label}-${unique()}@example.test`
  await signUp(email, label)
  return verifyAndSignIn(email)
}

function call(path: string, token: string, body?: unknown) {
  return app(
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

const upload = (token: string, change: unknown) =>
  call('/api/sync/upload', token, change)
const share = (token: string, path: string, body: unknown) =>
  call('/api/sharing/' + path, token, body)

async function createTrip(token: string, title = 'Shared trip') {
  const id = crypto.randomUUID()
  const response = await upload(token, {
    table: 'trips',
    id,
    op: 'put',
    data: { title, destination: 'Porto' }
  })
  expect(response.status).toBe(200)
  return id
}

async function readTrip(token: string, id: string) {
  return call('/api/data/trips/' + id, token)
}

type Account = { token: string; id: string; email: string }
type Incoming = {
  id: string
  space_id: string
  space_name: string
  inviter_name: string
  role: string
}

async function incoming(invitee: Account, space: 'trip' | 'library') {
  const response = await share(invitee.token, space + '/incoming', {})
  expect(response.status).toBe(200)
  return (await response.json()) as Incoming[]
}

/** Invite someone, then accept it in their app. */
async function shareWith(
  owner: Account,
  invitee: Account,
  space: 'trip' | 'library',
  spaceID: string,
  role: 'editor' | 'viewer'
) {
  const invited = await share(owner.token, space + '/invite', {
    space_id: spaceID,
    email: invitee.email,
    role
  })
  expect(await invited.json()).toEqual({ status: 'pending' })
  const invite = (await incoming(invitee, space)).find(
    (i) => i.space_id === spaceID
  )!
  const accepted = await share(invitee.token, space + '/accept', {
    invite_id: invite.id
  })
  expect(accepted.status).toBe(200)
  expect(await accepted.json()).toEqual({
    status: 'accepted',
    space_id: spaceID
  })
  return invite
}

test('a trip shared with an editor can be read and planned but not deleted or re-shared', async () => {
  const owner = await account('owner')
  const editor = await account('editor')
  const stranger = await account('stranger')
  const tripID = await createTrip(owner.token)

  const invited = await share(owner.token, 'trip/invite', {
    space_id: tripID,
    email: editor.email.toUpperCase(),
    role: 'editor'
  })
  expect(invited.status).toBe(200)
  expect(await invited.json()).toEqual({ status: 'pending' })

  // Nobody is added until they accept; the invite is emailed to them.
  expect((await readTrip(editor.token, tripID)).status).toBe(404)
  expect(invites.findLast((m) => m.email === editor.email)).toEqual({
    email: editor.email,
    url: 'https://growmoss.app/invites',
    invite: {
      inviter: 'owner',
      target: 'the trip “Shared trip”',
      senderID: owner.id
    }
  })
  const [invite] = await incoming(editor, 'trip')
  expect(invite).toMatchObject({
    space_id: tripID,
    space_name: 'Shared trip',
    inviter_name: 'owner',
    role: 'editor'
  })
  expect(await incoming(stranger, 'trip')).toEqual([])
  // Someone else can't accept it, even with its ID.
  const stolen = await share(stranger.token, 'trip/accept', {
    invite_id: invite!.id
  })
  expect(stolen.status).toBe(422)
  expect((await stolen.json()).code).toBe('MX006')
  expect(
    (await share(editor.token, 'trip/accept', { invite_id: invite!.id })).status
  ).toBe(200)
  // An accepted invite can't be used again.
  expect(
    (await share(editor.token, 'trip/accept', { invite_id: invite!.id })).status
  ).toBe(422)

  expect((await readTrip(editor.token, tripID)).status).toBe(200)
  expect((await readTrip(stranger.token, tripID)).status).toBe(404)

  const renamed = await upload(editor.token, {
    table: 'trips',
    id: tripID,
    op: 'patch',
    data: { title: 'Renamed by editor' }
  })
  expect(renamed.status).toBe(200)
  expect((await (await readTrip(owner.token, tripID)).json()).title).toBe(
    'Renamed by editor'
  )

  // An item an editor adds belongs to the trip's owner, so it syncs to everyone.
  const itemID = crypto.randomUUID()
  const added = await upload(editor.token, {
    table: 'itinerary_items',
    id: itemID,
    op: 'put',
    data: {
      owner_id: owner.id,
      trip_id: tripID,
      kind: 'food',
      title: 'Lunch',
      photos_json: '[]'
    }
  })
  expect(added.status).toBe(200)
  const item = await (
    await call('/api/data/itinerary_items/' + itemID, owner.token)
  ).json()
  expect(item.owner_id).toBe(owner.id)
  expect(item.photos_json).toBe('[]')

  // The editor cannot claim the item for themselves.
  const claimed = await upload(editor.token, {
    table: 'itinerary_items',
    id: crypto.randomUUID(),
    op: 'put',
    data: { owner_id: editor.id, trip_id: tripID, kind: 'note', title: 'Mine' }
  })
  expect(claimed.status).toBe(403)

  const deleted = await upload(editor.token, {
    table: 'trips',
    id: tripID,
    op: 'delete'
  })
  expect(deleted.status).toBe(422)
  expect((await deleted.json()).code).toBe('MX003')
  expect((await (await readTrip(owner.token, tripID)).json()).deleted_at).toBe(
    null
  )

  const reshared = await share(editor.token, 'trip/invite', {
    space_id: tripID,
    email: stranger.email,
    role: 'viewer'
  })
  expect(reshared.status).toBe(403)
  expect((await reshared.json()).code).toBe('MX007')

  // Neither the stranger nor the editor's own allowance changes.
  expect(
    (await (await call('/api/trips/status', editor.token)).json())
      .lifetime_count
  ).toBe(0)
})

test('a viewer reads a shared trip and its plans but every change is refused', async () => {
  const owner = await account('owner')
  const viewer = await account('viewer')
  const tripID = await createTrip(owner.token)
  const itemID = crypto.randomUUID()
  expect(
    (
      await upload(owner.token, {
        table: 'itinerary_items',
        id: itemID,
        op: 'put',
        data: {
          trip_id: tripID,
          kind: 'activity',
          title: 'Tram 28',
          photos_json: '[]'
        }
      })
    ).status
  ).toBe(200)
  await shareWith(owner, viewer, 'trip', tripID, 'viewer')

  expect((await readTrip(viewer.token, tripID)).status).toBe(200)
  expect(
    (await call('/api/data/itinerary_items/' + itemID, viewer.token)).status
  ).toBe(200)

  const photoEdit = await upload(viewer.token, {
    table: 'itinerary_items',
    id: itemID,
    op: 'patch',
    data: { photos_json: null }
  })
  expect(photoEdit.status).toBe(403)
  expect(
    (
      await (
        await call('/api/data/itinerary_items/' + itemID, viewer.token)
      ).json()
    ).photos_json
  ).toBe('[]')

  const tripEdit = await upload(viewer.token, {
    table: 'trips',
    id: tripID,
    op: 'patch',
    data: { title: 'Viewer edit' }
  })
  expect(tripEdit.status).toBe(403)
  expect((await tripEdit.json()).code).toBe('MX003')
  const itemEdit = await upload(viewer.token, {
    table: 'itinerary_items',
    id: itemID,
    op: 'patch',
    data: { title: 'Viewer edit' }
  })
  expect(itemEdit.status).toBe(403)
  const itemAdd = await upload(viewer.token, {
    table: 'itinerary_items',
    id: crypto.randomUUID(),
    op: 'put',
    data: {
      owner_id: owner.id,
      trip_id: tripID,
      kind: 'note',
      title: 'Viewer'
    }
  })
  expect(itemAdd.status).toBe(422)
  expect((await itemAdd.json()).code).toBe('MX003')
  const itemDelete = await upload(viewer.token, {
    table: 'itinerary_items',
    id: itemID,
    op: 'delete'
  })
  expect(itemDelete.status).toBe(403)
  expect((await (await readTrip(owner.token, tripID)).json()).title).toBe(
    'Shared trip'
  )
})

test('sharing all trips covers trips created later, and removal ends access', async () => {
  const owner = await account('library-owner')
  const member = await account('library-member')
  const before = await createTrip(owner.token, 'Before')

  const invite = await shareWith(owner, member, 'library', owner.id, 'editor')
  expect(invite.space_name).toBe("All of library-owner's trips")
  expect(invites.findLast((m) => m.email === member.email)?.invite.target).toBe(
    'all their trips'
  )
  const after = await createTrip(owner.token, 'After')

  for (const id of [before, after])
    expect((await readTrip(member.token, id)).status).toBe(200)
  expect(
    (
      await upload(member.token, {
        table: 'trips',
        id: after,
        op: 'patch',
        data: { notes: 'Bring a jacket' }
      })
    ).status
  ).toBe(200)

  // Nobody else can share someone's library.
  const forged = await share(member.token, 'library/invite', {
    space_id: owner.id,
    email: 'someone@example.test',
    role: 'viewer'
  })
  expect(forged.status).toBe(403)

  const profiles = await (
    await share(member.token, 'library/member_profiles', {
      space_id: owner.id
    })
  ).json()
  expect(profiles.map((p: { display_name: string }) => p.display_name)).toEqual(
    ['library-owner', 'library-member']
  )

  // A member cannot remove someone else; the owner can.
  const otherMember = await account('library-other')
  await shareWith(owner, otherMember, 'library', owner.id, 'viewer')
  expect(
    (
      await share(member.token, 'library/remove_member', {
        space_id: owner.id,
        user_id: otherMember.id
      })
    ).status
  ).toBe(403)
  expect(
    (
      await share(owner.token, 'library/remove_member', {
        space_id: owner.id,
        user_id: member.id
      })
    ).status
  ).toBe(200)
  for (const id of [before, after])
    expect((await readTrip(member.token, id)).status).toBe(404)

  // A member can leave; the owner's own row cannot be removed.
  expect(
    (
      await share(otherMember.token, 'library/remove_member', {
        space_id: owner.id,
        user_id: otherMember.id
      })
    ).status
  ).toBe(200)
  expect((await readTrip(otherMember.token, before)).status).toBe(404)
  await share(owner.token, 'library/remove_member', {
    space_id: owner.id,
    user_id: owner.id
  })
  const ownerRow = await pool.query(
    'select role from library_members where library_id = $1 and user_id = $1',
    [owner.id]
  )
  expect(ownerRow.rows).toEqual([{ role: 'owner' }])
})

test('someone who signs up later accepts the invite in the app, never automatically', async () => {
  const owner = await account('pending-owner')
  const tripID = await createTrip(owner.token)
  const email = `later-${unique()}@example.test`

  for (const [space, id, role] of [
    ['trip', tripID, 'viewer'],
    ['library', owner.id, 'editor']
  ] as const) {
    const invited = await share(owner.token, space + '/invite', {
      space_id: id,
      email,
      role
    })
    expect(await invited.json()).toEqual({ status: 'pending' })
  }

  await signUp(email, 'Later')
  const invitee = await verifyAndSignIn(email)
  // Verifying the address no longer adds them to anything.
  const joined = await pool.query(
    'select 1 from trip_members where user_id = $1 union all select 1 from library_members where user_id = $1 and library_id <> $1',
    [invitee.id]
  )
  expect(joined.rowCount).toBe(0)
  expect((await readTrip(invitee.token, tripID)).status).toBe(404)

  const [tripInvite] = await incoming(invitee, 'trip')
  const [libraryInvite] = await incoming(invitee, 'library')
  expect(tripInvite).toMatchObject({ space_id: tripID, role: 'viewer' })
  expect(libraryInvite).toMatchObject({ space_id: owner.id, role: 'editor' })
  await share(invitee.token, 'trip/accept', { invite_id: tripInvite!.id })
  await share(invitee.token, 'library/accept', {
    invite_id: libraryInvite!.id
  })
  const trip = await pool.query(
    'select role from trip_members where trip_id = $1 and user_id = $2',
    [tripID, invitee.id]
  )
  expect(trip.rows).toEqual([{ role: 'viewer' }])
  const all = await pool.query(
    'select role from library_members where library_id = $1 and user_id = $2',
    [owner.id, invitee.id]
  )
  expect(all.rows).toEqual([{ role: 'editor' }])
  expect(await incoming(invitee, 'trip')).toEqual([])
  const open = await pool.query(
    'select count(*)::int as open from trip_pending_invites where email = $1 and accepted_at is null',
    [email]
  )
  expect(open.rows[0].open).toBe(0)
  expect((await readTrip(invitee.token, tripID)).status).toBe(200)
})

test('declining removes the invite, and a failed email still leaves it in the app', async () => {
  const owner = await account('decline-owner')
  const invitee = await account('decline-invitee')
  const tripID = await createTrip(owner.token)
  await share(owner.token, 'trip/invite', {
    space_id: tripID,
    email: invitee.email,
    role: 'editor'
  })
  const [invite] = await incoming(invitee, 'trip')
  expect(
    (await share(invitee.token, 'trip/decline', { invite_id: invite!.id }))
      .status
  ).toBe(200)
  expect(await incoming(invitee, 'trip')).toEqual([])
  expect(
    (await share(invitee.token, 'trip/accept', { invite_id: invite!.id }))
      .status
  ).toBe(422)
  expect((await readTrip(invitee.token, tripID)).status).toBe(404)

  emailDown = true
  try {
    const invited = await share(owner.token, 'trip/invite', {
      space_id: tripID,
      email: invitee.email,
      role: 'viewer'
    })
    expect(invited.status).toBe(200)
  } finally {
    emailDown = false
  }
  expect((await incoming(invitee, 'trip')).map((i) => i.role)).toEqual([
    'viewer'
  ])

  // Someone who already has access can't be invited again.
  await shareWith(owner, invitee, 'trip', tripID, 'viewer')
  const again = await share(owner.token, 'trip/invite', {
    space_id: tripID,
    email: invitee.email,
    role: 'editor'
  })
  expect(again.status).toBe(422)
  expect((await again.json()).message).toBe('They already have access.')
})

test('owners can revoke pending invites; others cannot', async () => {
  const owner = await account('revoke-owner')
  const other = await account('revoke-other')
  const tripID = await createTrip(owner.token)
  await share(owner.token, 'trip/invite', {
    space_id: tripID,
    email: `nobody-${unique()}@example.test`,
    role: 'editor'
  })
  const invite = (
    await pool.query('select id from trip_pending_invites where trip_id = $1', [
      tripID
    ])
  ).rows[0].id

  await share(other.token, 'trip/revoke_invite', { invite_id: invite })
  expect(
    (
      await pool.query('select 1 from trip_pending_invites where id = $1', [
        invite
      ])
    ).rowCount
  ).toBe(1)
  expect(
    (await share(owner.token, 'trip/revoke_invite', { invite_id: invite }))
      .status
  ).toBe(200)
  expect(
    (
      await pool.query('select 1 from trip_pending_invites where id = $1', [
        invite
      ])
    ).rowCount
  ).toBe(0)
})

test('invalid invites are refused with a message the app can show', async () => {
  const owner = await account('invalid-owner')
  const tripID = await createTrip(owner.token)
  for (const body of [
    { space_id: tripID, email: owner.email, role: 'editor' },
    { space_id: tripID, email: 'not-an-email', role: 'editor' },
    { space_id: tripID, email: 'friend@example.test', role: 'owner' }
  ]) {
    const response = await share(owner.token, 'trip/invite', body)
    expect(response.status).toBe(422)
    const error = await response.json()
    expect(error.code).toBe('MX006')
    expect(error.message.length).toBeGreaterThan(0)
  }
  expect(
    (
      await share(owner.token, 'album/invite', {
        space_id: tripID,
        email: 'friend@example.test',
        role: 'editor'
      })
    ).status
  ).toBe(404)
  expect(
    (
      await share(owner.token, 'trip/invite', {
        space_id: tripID,
        email: 'friend@example.test',
        role: 'editor',
        extra: true
      })
    ).status
  ).toBe(400)
  // Member names are only for members.
  const stranger = await account('invalid-stranger')
  expect(
    await (
      await share(stranger.token, 'trip/member_profiles', { space_id: tripID })
    ).json()
  ).toEqual([])
})

test('every trip and account has an owner row, and the API role cannot write memberships', async () => {
  const owner = await account('rows-owner')
  const tripID = await createTrip(owner.token)
  expect(
    (
      await pool.query(
        'select role from trip_members where trip_id = $1 and user_id = $2',
        [tripID, owner.id]
      )
    ).rows
  ).toEqual([{ role: 'owner' }])
  expect(
    (
      await pool.query(
        'select role from library_members where library_id = $1 and user_id = $1',
        [owner.id]
      )
    ).rows
  ).toEqual([{ role: 'owner' }])

  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query('set local role moss_api')
    await client.query("select set_config('moss.user_id', $1, true)", [
      owner.id
    ])
    await expect(
      client.query(
        "insert into library_members (library_id, user_id, role) values ($1, $1, 'editor')",
        [crypto.randomUUID()]
      )
    ).rejects.toThrow()
  } finally {
    await client.query('rollback')
    client.release()
  }
})
