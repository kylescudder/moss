import type { PoolClient } from 'pg'
import { z } from 'zod'
import { RequestError } from './data'

// The sharing contract the app's shared sharing core calls
// (Moss/Sharing/SharingAppConfiguration.swift):
//   POST /api/sharing/<space>/<action>
// where <space> is `trip` (one trip) or `library` (every trip an account
// owns; the space ID is the owner's profile ID). The SQL functions check
// ownership and membership themselves.
const space = z.enum(['trip', 'library'])
const id = z.uuid()
const actions = {
  invite: {
    input: z.object({
      space_id: id,
      email: z.string().max(320),
      role: z.string().max(20)
    }),
    run: (
      client: PoolClient,
      s: string,
      body: { space_id: string; email: string; role: string }
    ) =>
      client
        .query('select public.share_invite($1, $2, $3, $4) as result', [
          s,
          body.space_id,
          body.email,
          body.role
        ])
        .then((r) => r.rows[0].result)
  },
  remove_member: {
    input: z.object({ space_id: id, user_id: id }),
    run: (
      client: PoolClient,
      s: string,
      body: { space_id: string; user_id: string }
    ) =>
      client
        .query('select public.share_remove_member($1, $2, $3)', [
          s,
          body.space_id,
          body.user_id
        ])
        .then(() => ({ removed: true }))
  },
  revoke_invite: {
    input: z.object({ invite_id: id }),
    run: (client: PoolClient, s: string, body: { invite_id: string }) =>
      client
        .query('select public.share_revoke_invite($1, $2)', [s, body.invite_id])
        .then(() => ({ revoked: true }))
  },
  member_profiles: {
    input: z.object({ space_id: id }),
    run: (client: PoolClient, s: string, body: { space_id: string }) =>
      client
        .query(
          'select id, display_name from public.share_member_profiles($1, $2)',
          [s, body.space_id]
        )
        .then((r) => r.rows)
  }
} as const

export async function sharingAction(
  client: PoolClient,
  path: string,
  input: unknown
) {
  const [rawSpace, rawAction, ...rest] = path.split('/')
  const parsedSpace = space.safeParse(rawSpace)
  if (
    !parsedSpace.success ||
    rest.length ||
    !rawAction ||
    !Object.hasOwn(actions, rawAction)
  )
    throw new RequestError('not_found', 404, 'Not found.')
  const action = actions[rawAction as keyof typeof actions]
  const body = action.input.strict().parse(input)
  return (
    action.run as (
      client: PoolClient,
      s: string,
      body: unknown
    ) => Promise<unknown>
  )(client, parsedSpace.data, body)
}
