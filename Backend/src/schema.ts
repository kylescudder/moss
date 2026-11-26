import { sql } from 'drizzle-orm'
import {
  check,
  boolean,
  bigint,
  index,
  integer,
  uuid,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex
} from 'drizzle-orm/pg-core'

// Separate, additive tables: auth changes never require removing auth data.
import { authUser } from './auth-schema'
export * from './auth-schema'

const dates = () => ({
  created_at: timestamp('created_at', { withTimezone: true })
    .notNull()
    .defaultNow(),
  updated_at: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .defaultNow(),
  deleted_at: timestamp('deleted_at', { withTimezone: true })
})

export const profiles = pgTable('profiles', {
  id: uuid('id')
    .primaryKey()
    .references(() => authUser.id, { onDelete: 'cascade' }),
  username: text('username').unique(),
  display_name: text('display_name'),
  is_premium_account: boolean('is_premium_account').notNull().default(false),
  ...dates()
})
export const trips = pgTable(
  'trips',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    owner_id: uuid('owner_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    title: text('title').notNull(),
    destination: text('destination').notNull(),
    starts_at: timestamp('starts_at', { withTimezone: true }),
    ends_at: timestamp('ends_at', { withTimezone: true }),
    notes: text('notes'),
    ...dates()
  },
  (t) => [index('trips_owner_updated_idx').on(t.owner_id, t.updated_at)]
)
export const itineraryItems = pgTable(
  'itinerary_items',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    owner_id: uuid('owner_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    trip_id: uuid('trip_id')
      .notNull()
      .references(() => trips.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull().default('activity'),
    title: text('title').notNull(),
    location_name: text('location_name'),
    destination_name: text('destination_name'),
    transport_mode: text('transport_mode'),
    starts_at: timestamp('starts_at', { withTimezone: true }),
    ends_at: timestamp('ends_at', { withTimezone: true }),
    notes: text('notes'),
    photos_json: text('photos_json'),
    visited_at: timestamp('visited_at', { withTimezone: true }),
    sort_order: integer('sort_order').notNull().default(0),
    ...dates()
  },
  (t) => [
    check(
      'itinerary_items_photos_size_check',
      sql`${t.photos_json} is null or octet_length(${t.photos_json}) <= 500000`
    ),
    check(
      'itinerary_items_kind_check',
      sql`${t.kind} in ('flight','lodging','food','activity','transport','note')`
    ),
    check(
      'itinerary_items_transport_mode_check',
      sql`${t.transport_mode} in ('transit','driving','walking','cycling')`
    ),
    index('itinerary_items_trip_sort_idx').on(t.trip_id, t.sort_order),
    index('itinerary_items_owner_updated_idx').on(t.owner_id, t.updated_at)
  ]
)
// Sharing. A trip is shared through trip_members; "all my trips" is shared
// through library_members, whose library_id is the owner's profile ID, so a
// member sees every trip that account owns, now and later. Each space has an
// owner row. Invites to emails without a verified account wait in the
// *_pending_invites tables until that email is verified.
const shareRole = (name: string) => text(name).notNull().default('editor')
const membership = () => ({
  user_id: uuid('user_id')
    .notNull()
    .references(() => profiles.id, { onDelete: 'cascade' }),
  role: shareRole('role'),
  invited_by: uuid('invited_by').references(() => profiles.id, {
    onDelete: 'set null'
  }),
  joined_at: timestamp('joined_at', { withTimezone: true })
    .notNull()
    .defaultNow()
})
const invitation = () => ({
  id: uuid('id').primaryKey().defaultRandom(),
  email: text('email').notNull(),
  role: shareRole('role'),
  invited_by: uuid('invited_by')
    .notNull()
    .references(() => profiles.id, { onDelete: 'cascade' }),
  created_at: timestamp('created_at', { withTimezone: true })
    .notNull()
    .defaultNow(),
  accepted_at: timestamp('accepted_at', { withTimezone: true })
})
export const tripMembers = pgTable(
  'trip_members',
  {
    trip_id: uuid('trip_id')
      .notNull()
      .references(() => trips.id, { onDelete: 'cascade' }),
    ...membership()
  },
  (t) => [
    primaryKey({ columns: [t.trip_id, t.user_id] }),
    index('trip_members_user_idx').on(t.user_id),
    check(
      'trip_members_role_check',
      sql`${t.role} in ('owner','editor','viewer')`
    )
  ]
)
export const tripPendingInvites = pgTable(
  'trip_pending_invites',
  {
    trip_id: uuid('trip_id')
      .notNull()
      .references(() => trips.id, { onDelete: 'cascade' }),
    ...invitation()
  },
  (t) => [
    uniqueIndex('trip_pending_invites_trip_email_idx').on(t.trip_id, t.email),
    index('trip_pending_invites_email_idx').on(t.email),
    check(
      'trip_pending_invites_role_check',
      sql`${t.role} in ('editor','viewer')`
    ),
    check(
      'trip_pending_invites_email_check',
      sql`${t.email} = lower(${t.email})`
    )
  ]
)
export const libraryMembers = pgTable(
  'library_members',
  {
    library_id: uuid('library_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    ...membership()
  },
  (t) => [
    primaryKey({ columns: [t.library_id, t.user_id] }),
    index('library_members_user_idx').on(t.user_id),
    check(
      'library_members_role_check',
      sql`${t.role} in ('owner','editor','viewer')`
    )
  ]
)
export const libraryPendingInvites = pgTable(
  'library_pending_invites',
  {
    library_id: uuid('library_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    ...invitation()
  },
  (t) => [
    uniqueIndex('library_pending_invites_library_email_idx').on(
      t.library_id,
      t.email
    ),
    index('library_pending_invites_email_idx').on(t.email),
    check(
      'library_pending_invites_role_check',
      sql`${t.role} in ('editor','viewer')`
    ),
    check(
      'library_pending_invites_email_check',
      sql`${t.email} = lower(${t.email})`
    )
  ]
)
export const deviceTokens = pgTable(
  'device_tokens',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    user_id: uuid('user_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    apns_token: text('apns_token').notNull(),
    device_name: text('device_name'),
    bundle_id: text('bundle_id').notNull(),
    environment: text('environment').notNull(),
    ...dates()
  },
  (t) => [
    uniqueIndex('device_tokens_user_token_idx').on(t.user_id, t.apns_token),
    check(
      'device_tokens_environment_check',
      sql`${t.environment} in ('sandbox','production')`
    )
  ]
)
export const tripQuotas = pgTable(
  'trip_creation_quotas',
  {
    user_id: uuid('user_id')
      .primaryKey()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    lifetime_count: bigint('lifetime_count', { mode: 'number' })
      .notNull()
      .default(0),
    updated_at: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
  },
  (t) => [
    check('trip_creation_quotas_count_check', sql`${t.lifetime_count} >= 0`)
  ]
)
export const tripEvents = pgTable(
  'trip_creation_events',
  {
    trip_id: uuid('trip_id').primaryKey(),
    user_id: uuid('user_id')
      .notNull()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    created_at: timestamp('created_at', { withTimezone: true })
      .notNull()
      .defaultNow()
  },
  (t) => [index('trip_creation_events_user_idx').on(t.user_id)]
)
export const iapEntitlements = pgTable(
  'iap_entitlements',
  {
    user_id: uuid('user_id')
      .primaryKey()
      .references(() => profiles.id, { onDelete: 'cascade' }),
    product_id: text('product_id').notNull(),
    original_transaction_id: text('original_transaction_id'),
    transaction_id: text('transaction_id'),
    bundle_id: text('bundle_id'),
    status: text('status').notNull(),
    expires_at: timestamp('expires_at', { withTimezone: true }),
    revoked_at: timestamp('revoked_at', { withTimezone: true }),
    environment: text('environment'),
    signed_at: timestamp('signed_at', { withTimezone: true }),
    verified_at: timestamp('verified_at', { withTimezone: true }),
    verification_source: text('verification_source'),
    updated_at: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
  },
  (t) => [
    check(
      'iap_entitlements_status_check',
      sql`${t.status} in ('active','expired','revoked','unknown')`
    ),
    check(
      'iap_entitlements_environment_check',
      sql`${t.environment} in ('Production','Sandbox')`
    ),
    check(
      'iap_entitlements_source_check',
      sql`${t.verification_source} in ('device','notification')`
    )
  ]
)

// Published only by the backup verifier, never by the API runtime.
export const recoveryLease = pgTable('recovery_lease', {
  id: integer('id').primaryKey(),
  snapshotStartedAt: timestamp('snapshot_started_at', {
    withTimezone: true
  }).notNull(),
  verifiedAt: timestamp('verified_at', { withTimezone: true }).notNull(),
  snapshotID: text('snapshot_id').notNull()
})
export const notificationInbox = pgTable('notification_inbox', {
  id: text('id').primaryKey(),
  signedPayload: text('signed_payload').notNull(),
  receivedAt: timestamp('received_at', { withTimezone: true })
    .notNull()
    .defaultNow(),
  processedAt: timestamp('processed_at', { withTimezone: true })
})
export const nativeCodes = pgTable('native_codes', {
  id: text('id').primaryKey(),
  challenge: text('challenge').notNull(),
  sessionToken: text('session_token').notNull(),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull()
})
