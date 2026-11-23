import type { PoolClient } from 'pg'
// Moss domain schema is entirely recorded in the existing Drizzle journal.
export async function migrateApplication(_client: PoolClient): Promise<void> {}
