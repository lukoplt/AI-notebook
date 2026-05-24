import GRDB

public func registerMigrationV4(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v4_chat_sessions_and_messages") { db in
        try db.create(table: "chat_sessions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("notebook_id", .integer)
                .notNull()
                .references("notebooks", onDelete: .cascade)
            t.column("title",      .text).notNull()
            t.column("created_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_chat_sessions_notebook",
            on: "chat_sessions",
            columns: ["notebook_id", "created_at"]
        )

        try db.create(table: "messages") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("session_id", .integer)
                .notNull()
                .references("chat_sessions", onDelete: .cascade)
            t.column("role",           .text).notNull()
            t.column("content",        .text).notNull()
            t.column("citations_json", .text)
            t.column("created_at",     .datetime).notNull()
        }
        try db.create(
            index: "idx_messages_session",
            on: "messages",
            columns: ["session_id", "created_at"]
        )
    }
}
