import type { PoolClient } from 'pg'
import {
  verifySubscriptionNotification,
  verifySubscriptionTransaction,
  ApplePayloadValidationError,
  type VerifiedSubscriptionTransaction
} from './apple-verification'

export async function recordEntitlement(
  client: PoolClient,
  tx: VerifiedSubscriptionTransaction,
  source: 'device' | 'notification',
  environments: string[]
) {
  if (!environments.includes(tx.environment))
    throw new ApplePayloadValidationError('Unexpected environment')
  await client.query(
    'select public.record_verified_iap_entitlement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',
    [
      tx.userID,
      tx.productID,
      tx.bundleID,
      tx.originalTransactionID,
      tx.transactionID,
      tx.status,
      tx.expiresAt,
      tx.revokedAt,
      tx.environment,
      tx.signedAt,
      source
    ]
  )
}
export async function syncTransaction(
  client: PoolClient,
  signedTransaction: string,
  userID: string,
  environments: string[]
) {
  const tx = await verifySubscriptionTransaction(signedTransaction, userID)
  await recordEntitlement(client, tx, 'device', environments)
  const active = (
    await client.query(
      'select public.has_verified_supporter_entitlement($1) as active',
      [userID]
    )
  ).rows[0].active as boolean
  return { verified: true, active }
}
export async function processNotification(
  client: PoolClient,
  signedPayload: string,
  environments: string[]
) {
  const verified = await verifySubscriptionNotification(signedPayload)
  const id = new Bun.CryptoHasher('sha256').update(signedPayload).digest('hex')
  await client.query(
    'insert into notification_inbox(id,signed_payload) values ($1,$2) on conflict do nothing',
    [id, signedPayload]
  )
  await recordEntitlement(
    client,
    verified.transaction,
    'notification',
    environments
  )
  await client.query(
    'update notification_inbox set processed_at = clock_timestamp() where id = $1',
    [id]
  )
}
