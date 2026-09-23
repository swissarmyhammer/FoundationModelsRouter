/// The one way the compaction eval builds the join that names the fixture a
/// running sample measures.
extension Sequence {
    /// Keys every element by `key`, keeping the FIRST element of any collision.
    ///
    /// The gated continuity tier needs this join two times. It needs it while a
    /// run continues, so that a progress line can name the fixture that a
    /// sample drives. It needs it again after the run ends, so that it can
    /// classify a recorded sample against the fixture that it ran. These two
    /// readers must always agree about which fixture a sample ran. Thus the
    /// tier builds its join in one place only:
    /// ``CompactionContinuitySeed/keyedByFinalInstruction(_:)``, which uses
    /// this body.
    ///
    /// The tier always keeps the first element of a collision. When a dataset
    /// states one join key two times, the fixture has a defect. The tier has a
    /// test of its own that makes sure that each key is unique. If this method
    /// resolved a collision, it would hide that defect and not report it.
    ///
    /// - Parameter key: The join key to read off each element.
    /// - Returns: One entry for each distinct key.
    func keyedByFirst<Key: Hashable>(_ key: (Element) -> Key) -> [Key: Element] {
        Dictionary(map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }
}
