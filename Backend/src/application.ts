import { isPublicAuthPath } from './auth-routes'
import { NativeAuthError } from './auth-error'
import { VerificationException } from '@apple/app-store-server-library'
import type { Pool, PoolClient } from 'pg'
import type { Auth } from './auth'
import { z } from 'zod'
import { RequestError, uploadChange, writableTable } from './data'
import { nativeOAuth } from './native-oauth'
import { processNotification, syncTransaction } from './iap'
import type { NotificationSpool } from './notification-spool'
import {
  verifySubscriptionNotification,
  ApplePayloadValidationError
} from './apple-verification'

export async function transaction<T>(
  pool: Pool,
  perform: (client: PoolClient) => Promise<T>,
  userID?: string
) {
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query('set local role moss_api')
    await client.query("set local statement_timeout = '55s'")
    await client.query("set local idle_in_transaction_session_timeout = '55s'")
    if (userID)
      await client.query("select set_config('moss.user_id', $1, true)", [
        userID
      ])
    const result = await perform(client)
    await client.query('select public.require_recovery_lease()')
    await client.query('commit')
    return result
  } catch (error) {
    await client.query('rollback')
    throw error
  } finally {
    client.release()
  }
}

export function createApplication({
  auth,
  pool,
  origin = 'http://localhost:3147',
  appleEnvironments = ['Sandbox'],
  spool
}: {
  auth: Auth
  pool: Pool
  origin?: string
  appleEnvironments?: string[]
  spool?: NotificationSpool
}) {
  return async (request: Request): Promise<Response> => {
    try {
      const url = new URL(request.url)
      if (url.pathname === '/health/live') return Response.json({ ok: true })
      // A JWKS read must remain available while fenced; it does not authorize writes.
      if (url.pathname === '/api/auth/jwks' && request.method === 'GET')
        return auth.handler(request)
      if (
        url.pathname === '/api/iap/notifications' &&
        request.method === 'POST' &&
        spool
      ) {
        const body = z
          .object({ signedPayload: z.string().min(1).max(100_000) })
          .parse(await request.clone().json())
        await verifySubscriptionNotification(body.signedPayload)
        await spool.retain(body.signedPayload)
      }
      await pool.query('select public.require_recovery_lease()')
      if (url.pathname === '/health/ready') {
        await pool.query('select 1')
        return Response.json({ ok: true })
      }
      if (url.pathname.startsWith('/api/auth/')) {
        const path = url.pathname.slice('/api/auth/'.length)
        if (!isPublicAuthPath(path)) return new Response(null, { status: 404 })
        return auth.handler(request)
      }
      const native = await nativeOAuth(request, auth, pool, origin)
      if (native) return native
      if (
        url.pathname === '/api/iap/notifications' &&
        request.method === 'POST'
      ) {
        const input = z
          .object({ signedPayload: z.string().min(1).max(100_000) })
          .parse(await request.json())
        await transaction(pool, (c) =>
          processNotification(c, input.signedPayload, appleEnvironments)
        )
        return Response.json({ accepted: true })
      }
      const session = await auth.api.getSession({ headers: request.headers })
      if (!session?.user.emailVerified)
        throw new RequestError('MX002', 401, 'Sign in with a verified account.')
      const response = await transaction(
        pool,
        async (client) => {
          const userID = session.user.id
          if (url.pathname === '/api/me' && request.method === 'GET') {
            const row = (
              await client.query('select * from profiles where id = $1', [
                userID
              ])
            ).rows[0]
            if (!row)
              throw new RequestError(
                'MX004',
                409,
                'Account import is incomplete.'
              )
            return Response.json(row)
          }
          if (url.pathname === '/api/account' && request.method === 'DELETE') {
            // Cascades remove all owner data. The client clears its local DB only on success.
            await client.query('delete from auth_user where id = $1', [userID])
            return Response.json({ deleted: true })
          }
          if (
            url.pathname === '/api/profile/name' &&
            request.method === 'POST'
          ) {
            const body = z
              .object({ name: z.string().trim().min(1).max(200) })
              .parse(await request.json())
            await client.query(
              "update profiles set display_name = $2 where id = $1 and coalesce(trim(display_name), '') = ''",
              [userID, body.name]
            )
            return Response.json({ accepted: true })
          }
          if (
            url.pathname === '/api/trips/status' &&
            request.method === 'GET'
          ) {
            const row = (
              await client.query(
                'select * from public.get_trip_creation_status()'
              )
            ).rows[0]
            return Response.json({
              ...row,
              lifetime_count: Number(row.lifetime_count)
            })
          }
          if (
            url.pathname === '/api/sync/upload' &&
            request.method === 'POST'
          ) {
            await uploadChange(client, userID, await request.json())
            return Response.json({ accepted: true })
          }
          if (
            url.pathname === '/api/iap/transactions' &&
            request.method === 'POST'
          ) {
            const body = z
              .object({ signedTransactionInfo: z.string().min(1).max(100_000) })
              .parse(await request.json())
            return Response.json(
              await syncTransaction(
                client,
                body.signedTransactionInfo,
                userID,
                appleEnvironments
              )
            )
          }
          if (url.pathname === '/api/devices' && request.method === 'DELETE') {
            const body = z
              .object({ apns_token: z.string().regex(/^[0-9a-f]{32,256}$/) })
              .parse(await request.json())
            await client.query(
              'delete from device_tokens where user_id=$1 and apns_token=$2',
              [userID, body.apns_token]
            )
            return Response.json({ accepted: true })
          }
          if (url.pathname === '/api/devices' && request.method === 'POST') {
            const body = z
              .object({
                apns_token: z.string().regex(/^[0-9a-f]{32,256}$/),
                device_name: z.string().max(200),
                bundle_id: z.literal('app.getmoss.moss'),
                environment: z.enum(['sandbox', 'production'])
              })
              .parse(await request.json())
            await client.query(
              'insert into device_tokens (user_id,apns_token,device_name,bundle_id,environment) values ($1,$2,$3,$4,$5) on conflict (user_id,apns_token) do update set device_name=excluded.device_name,environment=excluded.environment',
              [
                userID,
                body.apns_token,
                body.device_name,
                body.bundle_id,
                body.environment
              ]
            )
            return Response.json({ accepted: true })
          }
          if (
            url.pathname.startsWith('/api/data/') &&
            request.method === 'GET'
          ) {
            const [, , , name, rowID] = url.pathname.split('/')
            const table = writableTable.safeParse(name),
              id = z.uuid().safeParse(rowID)
            if (!table.success || !id.success)
              throw new RequestError('not_found', 404, 'Not found.')
            const row = (
              await client.query(`select * from ${table.data} where id = $1`, [
                id.data
              ])
            ).rows[0]
            if (!row) throw new RequestError('not_found', 404, 'Not found.')
            return Response.json(row)
          }
          return Response.json(
            { code: 'not_found', message: 'Not found.' },
            { status: 404 }
          )
        },
        session.user.id
      )
      response.headers.set('cache-control', 'no-store')
      return response
    } catch (error) {
      if (error instanceof NativeAuthError)
        return Response.json(
          { code: error.code, message: error.message },
          { status: error.status }
        )
      if (error instanceof RequestError)
        return Response.json(
          { code: error.code, message: error.message },
          { status: error.status }
        )
      if (error instanceof SyntaxError || error instanceof z.ZodError)
        return Response.json(
          { code: 'invalid_request', message: 'Invalid request.' },
          { status: 400 }
        )
      if (
        error instanceof ApplePayloadValidationError ||
        error instanceof VerificationException
      )
        return Response.json(
          {
            code: 'invalid_transaction',
            message: 'Apple verification failed.'
          },
          { status: 422 }
        )
      const code =
        error && typeof error === 'object' && 'code' in error
          ? String(error.code)
          : ''
      if (
        [
          'MX001',
          'MX003',
          'MX004',
          'MX005',
          '23502',
          '23503',
          '23505',
          '23514',
          '22P02',
          '22007',
          '22008',
          '22003'
        ].includes(code)
      )
        return Response.json(
          {
            code,
            message:
              code === 'MX001'
                ? 'Free trip limit reached.'
                : 'Record validation failed.'
          },
          { status: 422 }
        )
      // Provider/SQL error details can contain credentials or user data.
      return Response.json(
        { code: 'temporarily_unavailable', message: 'Please retry shortly.' },
        { status: 503, headers: { 'retry-after': '60' } }
      )
    }
  }
}
