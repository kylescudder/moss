import type { PoolClient } from 'pg'
import { z } from 'zod'
import { RequestError } from './data'

// The sharing contract the app's shared sharing core calls
// (Moss/Sharing/SharingAppConfiguration.swift):
//   POST /api/sharing/<space>/<action>
// where <space> is `trip` (one trip) or `library` (every trip an account
// owns; the space ID is the owner's profile ID). The SQL functions check
// ownership, membership and the invitee's verified email themselves.
const space = z.enum(['trip', 'library'])
const id = z.uuid()

/** An invite to email once the transaction has committed. */
export type Invitation = { email: string; inviter: string; target: string }

type Result = { body: unknown; invitation?: Invitation }
type Action = {
  input: z.ZodObject
  run: (client: PoolClient, space: string, body: never) => Promise<Result>
}

const scalar = async (
  client: PoolClient,
  sql: string,
  values: unknown[]
): Promise<unknown> => (await client.query(sql, values)).rows[0]?.result

const actions: Record<string, Action> = {
  invite: {
    input: z.object({
      space_id: id,
      email: z.string().max(320),
      role: z.string().max(20)
    }),
    run: async (
      client,
      s,
      body: { space_id: string; email: string; role: string }
    ) => {
      const result = (await scalar(
        client,
        'select public.share_invite($1, $2, $3, $4) as result',
        [s, body.space_id, body.email, body.role]
      )) as { status: string } & Invitation
      return {
        body: { status: result.status },
        invitation: {
          email: result.email,
          inviter: result.inviter,
          target: result.target
        }
      }
    }
  },
  remove_member: {
    input: z.object({ space_id: id, user_id: id }),
    run: async (client, s, body: { space_id: string; user_id: string }) => {
      await client.query('select public.share_remove_member($1, $2, $3)', [
        s,
        body.space_id,
        body.user_id
      ])
      return { body: { removed: true } }
    }
  },
  revoke_invite: {
    input: z.object({ invite_id: id }),
    run: async (client, s, body: { invite_id: string }) => {
      await client.query('select public.share_revoke_invite($1, $2)', [
        s,
        body.invite_id
      ])
      return { body: { revoked: true } }
    }
  },
  member_profiles: {
    input: z.object({ space_id: id }),
    run: async (client, s, body: { space_id: string }) => ({
      body: (
        await client.query(
          'select id, display_name from public.share_member_profiles($1, $2)',
          [s, body.space_id]
        )
      ).rows
    })
  },
  incoming: {
    input: z.object({}),
    run: async (client, s) => ({
      body: (
        await client.query(
          'select id, space_id, space_name, inviter_name, role, created_at from public.share_incoming($1)',
          [s]
        )
      ).rows
    })
  },
  accept: {
    input: z.object({ invite_id: id }),
    run: async (client, s, body: { invite_id: string }) => ({
      body: await scalar(
        client,
        'select public.share_accept($1, $2) as result',
        [s, body.invite_id]
      )
    })
  },
  decline: {
    input: z.object({ invite_id: id }),
    run: async (client, s, body: { invite_id: string }) => {
      await client.query('select public.share_decline($1, $2)', [
        s,
        body.invite_id
      ])
      return { body: { declined: true } }
    }
  }
}

export async function sharingAction(
  client: PoolClient,
  path: string,
  input: unknown
): Promise<Result> {
  const [rawSpace, rawAction, ...rest] = path.split('/')
  const parsedSpace = space.safeParse(rawSpace)
  if (
    !parsedSpace.success ||
    rest.length ||
    !rawAction ||
    !Object.hasOwn(actions, rawAction)
  )
    throw new RequestError('not_found', 404, 'Not found.')
  const action = actions[rawAction]!
  const body = action.input.strict().parse(input)
  return action.run(client, parsedSpace.data, body as never)
}
