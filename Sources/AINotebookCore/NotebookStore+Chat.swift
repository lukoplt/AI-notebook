import Foundation
import GRDB

extension NotebookStore {

    @discardableResult
    public func createChatSession(notebookId: Int64, title: String) throws -> ChatSession {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "New chat" : trimmed
        var session = ChatSession(notebookId: notebookId, title: resolved)
        try runOnDatabase { db in
            try session.insert(db)
        }
        return session
    }

    public func chatSessions(notebookId: Int64) throws -> [ChatSession] {
        try runOnDatabase { db in
            try ChatSession
                .filter(ChatSession.Columns.notebookId.column == notebookId)
                .order(ChatSession.Columns.createdAt.column.desc)
                .fetchAll(db)
        }
    }

    public func deleteChatSession(id: Int64) throws {
        try runOnDatabase { db in
            _ = try ChatSession.deleteOne(db, key: id)
        }
    }

    public func appendMessage(_ message: ChatMessage) throws {
        var copy = message
        try runOnDatabase { db in
            try copy.insert(db)
        }
    }

    public func messages(sessionId: Int64) throws -> [ChatMessage] {
        try runOnDatabase { db in
            try ChatMessage
                .filter(ChatMessage.Columns.sessionId.column == sessionId)
                .order(ChatMessage.Columns.createdAt.column.asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public func appendAssistantMessage(
        sessionId: Int64,
        content: String,
        citations: [Citation],
        model: String? = nil
    ) throws -> Int64 {
        var message = ChatMessage(
            sessionId: sessionId,
            role: .assistant,
            content: content,
            citations: citations,
            model: model
        )
        try runOnDatabase { db in
            try message.insert(db)
        }
        return message.id ?? 0
    }

    // MARK: Edit + regenerate (FR-C3)

    /// Overwrites a message's text (used when the user edits their last
    /// message before resending).
    public func updateMessageContent(id: Int64, content: String) throws {
        try runOnDatabase { db in
            try db.execute(sql: "UPDATE messages SET content=? WHERE id=?", arguments: [content, id])
        }
    }

    public func deleteMessage(id: Int64) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM messages WHERE id=?", arguments: [id])
        }
    }

    /// Deletes every message in the session strictly after `messageId` (by row
    /// id, which is monotonic with insertion order). Used on edit-and-resend to
    /// drop the stale answer(s) that followed the edited user turn.
    public func deleteMessagesAfter(sessionId: Int64, messageId: Int64) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE session_id=? AND id>?",
                arguments: [sessionId, messageId]
            )
        }
    }
}
