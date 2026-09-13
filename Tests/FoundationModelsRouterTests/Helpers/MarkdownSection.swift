import Foundation

/// One level-two section of a Markdown document the repository carries, for
/// a suite that pins the document's shape.
enum MarkdownSection {
    /// The prefix of each level-two heading. A heading starts one section
    /// and ends the section before it.
    static let headingPrefix = "## "

    /// The lines below the heading at `headingIndex`, up to the next
    /// level-two heading or the end of the document.
    ///
    /// - Parameters:
    ///   - headingIndex: The index of the section's heading line in `lines`.
    ///   - lines: The document's lines, in file order.
    /// - Returns: The body lines, in file order.
    static func body(below headingIndex: Int, in lines: [String]) -> [String] {
        Array(lines[(headingIndex + 1)...].prefix { !$0.hasPrefix(headingPrefix) })
    }
}
