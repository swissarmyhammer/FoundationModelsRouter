/// The one way this target builds the join that names the fixture a running
/// sample is measuring.
extension Sequence {
    /// Keys every element by `key`, keeping the FIRST element of any collision.
    ///
    /// Both gated eval tiers need this join, and each needs it twice over: once
    /// while a run is still going, so a progress line can name the fixture a
    /// sample is driving, and once after it ends, so a recorded sample can be
    /// classified against the fixture it ran. The two readers of one tier must
    /// never disagree about which fixture a sample ran, which is why each tier
    /// builds its join in exactly one place —
    /// ``CompactionEvalSeed/keyedByQuestion(_:)`` and
    /// ``CompactionContinuitySeed/keyedByFinalInstruction(_:)`` — and why those
    /// two now share this one body rather than each spelling it out.
    ///
    /// Keeping the first of a collision is what both tiers have always taken. A
    /// tier whose dataset states one join key twice has a fixture defect, and
    /// each tier pins its own key as unique in a test of its own; resolving a
    /// collision here would hide that defect rather than report it.
    ///
    /// - Parameter key: The join key to read off each element.
    /// - Returns: One entry for each distinct key.
    func keyedByFirst<Key: Hashable>(_ key: (Element) -> Key) -> [Key: Element] {
        Dictionary(map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }
}
