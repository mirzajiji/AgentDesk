import Foundation

/// Forward-only, transactional migrations. A failed or future schema is never reset.
enum OperationalMigrations {
    static let applicationID = 1_095_189_579 // "AGDK"
    static let currentVersion = 5
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

    static let versionThree = [
        "ALTER TABLE run_events ADD COLUMN event_kind TEXT NOT NULL DEFAULT 'runState' CHECK (event_kind IN ('runState','progress'))",
        "ALTER TABLE run_events ADD COLUMN progress_json TEXT",
        """
        CREATE TABLE run_progress (
            workspace_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            plan_json TEXT NOT NULL,
            PRIMARY KEY (workspace_id, project_id, run_id),
            FOREIGN KEY (workspace_id, project_id, run_id) REFERENCES runs(workspace_id, project_id, run_id)
        )
        """
    ]

    static let versionFour = [
        """
        CREATE TABLE approvals (
            workspace_id TEXT NOT NULL, project_id TEXT NOT NULL, environment_id TEXT NOT NULL,
            approval_id TEXT NOT NULL, action_id TEXT NOT NULL, action_json TEXT NOT NULL,
            requester_id TEXT NOT NULL, policy_fingerprint TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('pending','approved','rejected','modified','expired','consumed')),
            sequence INTEGER NOT NULL CHECK (sequence > 0),
            created_at REAL NOT NULL, expires_at REAL NOT NULL, updated_at REAL NOT NULL, reviewer_id TEXT, reviewer_revision TEXT,
            PRIMARY KEY (workspace_id, project_id, environment_id, approval_id),
            UNIQUE (workspace_id, project_id, environment_id, action_id)
        )
        """,
        """
        CREATE TABLE approval_events (
            workspace_id TEXT NOT NULL, project_id TEXT NOT NULL, environment_id TEXT NOT NULL,
            approval_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK (sequence > 0),
            state TEXT NOT NULL CHECK (state IN ('pending','approved','rejected','modified','expired','consumed')),
            recorded_at REAL NOT NULL, reviewer_id TEXT, reviewer_revision TEXT,
            PRIMARY KEY (workspace_id, project_id, environment_id, approval_id, sequence),
            FOREIGN KEY (workspace_id, project_id, environment_id, approval_id)
                REFERENCES approvals(workspace_id, project_id, environment_id, approval_id)
        )
        """
    ]

    static let versionFive = [
        """
        CREATE TABLE evidence_runs (
            workspace_id TEXT NOT NULL, project_id TEXT NOT NULL, run_id TEXT NOT NULL,
            environment_id TEXT NOT NULL, binding_json TEXT NOT NULL,
            PRIMARY KEY (workspace_id, project_id, run_id),
            UNIQUE (workspace_id, project_id, run_id, environment_id),
            FOREIGN KEY (workspace_id, project_id, run_id) REFERENCES runs(workspace_id, project_id, run_id)
        )
        """,
        """
        CREATE TABLE evidence_items (
            workspace_id TEXT NOT NULL, project_id TEXT NOT NULL, run_id TEXT NOT NULL, environment_id TEXT NOT NULL,
            evidence_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK (sequence > 0),
            metadata_json TEXT NOT NULL, body TEXT,
            PRIMARY KEY (workspace_id, project_id, run_id, environment_id, evidence_id),
            UNIQUE (workspace_id, project_id, run_id, environment_id, sequence),
            FOREIGN KEY (workspace_id, project_id, run_id, environment_id)
                REFERENCES evidence_runs(workspace_id, project_id, run_id, environment_id)
        )
        """
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
            if version < 3 {
                for statement in versionThree { try database.execute(statement) }
                try database.execute("PRAGMA user_version = 3")
            }
            if version < 4 {
                for statement in versionFour { try database.execute(statement) }
                try database.execute("PRAGMA user_version = 4")
            }
            if version < 5 {
                for statement in versionFive { try database.execute(statement) }
                try database.execute("PRAGMA user_version = 5")
            }
            // Verify required columns even when the database already claims the latest schema.
            _ = try database.query("SELECT workspace_id, project_id, run_id, state, created_at FROM runs LIMIT 0") { _ in 0 }
            _ = try database.query("SELECT workspace_id, project_id, run_id, sequence, state, recorded_at, event_kind, progress_json FROM run_events LIMIT 0") { _ in 0 }
            _ = try database.query("SELECT workspace_id, project_id, run_id, plan_json FROM run_progress LIMIT 0") { _ in 0 }
            _ = try database.query("SELECT workspace_id, project_id, environment_id, approval_id, action_id, action_json, requester_id, policy_fingerprint, state, sequence, created_at, expires_at, updated_at, reviewer_id, reviewer_revision FROM approvals LIMIT 0") { _ in 0 }
            _ = try database.query("SELECT workspace_id, project_id, environment_id, approval_id, sequence, state, recorded_at, reviewer_id, reviewer_revision FROM approval_events LIMIT 0") { _ in 0 }
            _ = try database.query("SELECT workspace_id, project_id, run_id, environment_id, binding_json FROM evidence_runs LIMIT 0") { _ in 0 }
            _ = try database.query("SELECT workspace_id, project_id, run_id, environment_id, evidence_id, sequence, metadata_json, body FROM evidence_items LIMIT 0") { _ in 0 }
            guard try database.integer("PRAGMA foreign_keys") == 1 else { throw OperationalStoreError.invalidDatabase }
        }
    }
}
