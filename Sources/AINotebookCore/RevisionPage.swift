/// A page's half-open Unicode scalar interval in its immutable revision text.
/// Empty pages have equal start and end offsets.
public struct PageBoundary: Equatable, Sendable {
    public let page: Int
    public let start: Int
    public let end: Int

    public init(page: Int, start: Int, end: Int) {
        self.page = page
        self.start = start
        self.end = end
    }
}
