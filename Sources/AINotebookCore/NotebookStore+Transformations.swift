import Foundation
import GRDB

extension NotebookStore {

    @discardableResult
    public func createTransformation(
        name: String,
        promptTemplate: String,
        scope: TransformationScope,
        isBuiltin: Bool = false
    ) throws -> Transformation {
        var t = Transformation(
            name: name,
            promptTemplate: promptTemplate,
            scope: scope,
            isBuiltin: isBuiltin
        )
        try runOnDatabase { db in
            try t.insert(db)
        }
        return t
    }

    public func transformations() throws -> [Transformation] {
        try runOnDatabase { db in
            try Transformation
                .order(
                    Transformation.Columns.isBuiltin.column.desc,
                    Transformation.Columns.name.column.asc
                )
                .fetchAll(db)
        }
    }

    public func updateTransformation(
        id: Int64,
        name: String,
        promptTemplate: String
    ) throws {
        try runOnDatabase { db in
            guard var t = try Transformation.fetchOne(db, key: id) else { return }
            t.name = name
            t.promptTemplate = promptTemplate
            try t.update(db)
        }
    }

    public func deleteTransformation(id: Int64) throws {
        try runOnDatabase { db in
            _ = try Transformation.deleteOne(db, key: id)
        }
    }

    @discardableResult
    public func recordTransformationRun(
        transformationId: Int64,
        sourceId: Int64?,
        resultNoteId: Int64?
    ) throws -> TransformationRun {
        var run = TransformationRun(
            transformationId: transformationId,
            sourceId: sourceId,
            resultNoteId: resultNoteId
        )
        try runOnDatabase { db in
            try run.insert(db)
        }
        return run
    }

    public func transformationRuns() throws -> [TransformationRun] {
        try runOnDatabase { db in
            try TransformationRun
                .order(TransformationRun.Columns.ranAt.column.desc)
                .fetchAll(db)
        }
    }
}
