import Foundation

/// Forward-only, transactional migrations. A failed or future schema is never reset.
enum OperationalMigrations {
    static let applicationID = 1_095_189_579 // "AGDK"
    static let currentVersion = 2
    static let versionOne = [
        """
        CREATE TABLE runs (
            workspace_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('queued','running','waitingForApproval','paused','completed','failed','cancelled')),
            PRIMARY KEY (workspace_id, project_id, run_id)
        )
        """
    ]
    static let versionTwo = [
        """
        CREATE TABLE run_events (
            workspace_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK (sequence > 0),
            state TEXT NOT NULL CHECK (state IN ('queued','running','waitingForApproval','paused','completed','failed','cancelled')),
            recorded_at REAL NOT NULL,
            PRIMARY KEY (workspace_id, project_id, run_id, sequence),
            FOREIGN KEY (workspace_id, project_id, run_id) REFERENCES runs(workspace_id, project_id, run_id)
        )
        """,
        "INSERT INTO run_events SELECT workspace_id, project_id, run_id, 1, state, created_at FROM runs",
        "CREATE INDEX runs_project_date ON runs(workspace_id, project_id, created_at DESC, run_id)"
    ]

    static func apply(to database: SQLiteConnection) throws {
        try database.execute("PRAGMA foreign_keys = ON")
        try database.transaction {
            let version = try database.integer("PRAGMA user_version")
            let application = try database.integer("PRAGMA application_id")
            guard version <= currentVersion else { throw OperationalStoreError.unsupportedSchema }
            if version == 0 {
                let tables = try database.integer("SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
                guard application == 0, tables == 0 else { throw OperationalStoreError.invalidDatabase }
                for statement in versionOne { try database.execute(statement) }
                try database.execute("PRAGMA application_id = \(applicationID)")
                try database.execute("PRAGMA user_version = 1")
            } else {
                guard application == applicationID else { throw OperationalStoreError.invalidDatabase }
            }
            if version < 2 {
                for statement in versionTwo { try database.execute(statement) }
                try database.execute("PRAGMA user_version = 2")
            }
            // Verify required columns even when the database already claims the latest schema.
            _ = try database.query("SELECT workspace_id, project_id, run_id, state, created_at FROM runs LIMIT 0") { _ in 0 }
            _ = try database.query("SELECT workspace_id, project_id, run_id, sequence, state, recorded_at FROM run_events LIMIT 0") { _ in 0 }
            guard try database.integer("PRAGMA foreign_keys") == 1 else { throw OperationalStoreError.invalidDatabase }
        }
    }
}
