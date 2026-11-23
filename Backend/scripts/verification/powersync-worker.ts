import { Database } from 'bun:sqlite'
import { startPowerSyncWorker } from '@powersync/node/worker.js'
if (process.platform === 'darwin') {
  if (!process.env.POWERSYNC_SQLITE_LIBRARY)
    throw new Error(
      'POWERSYNC_SQLITE_LIBRARY must point to a full SQLite dylib on macOS'
    )
  Database.setCustomSQLite(process.env.POWERSYNC_SQLITE_LIBRARY)
}
startPowerSyncWorker()
