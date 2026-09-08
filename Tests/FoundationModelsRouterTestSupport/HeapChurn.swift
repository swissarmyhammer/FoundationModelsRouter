/// Reads one value again and again with a new heap allocation kept alive
/// between the reads, so a read whose bytes depend on where its temporary
/// storage lands shows that dependence.
///
/// Swift seeds a `Dictionary`'s iteration order with the address of its
/// storage. An encoder that iterates a dictionary therefore writes the same
/// value in a different key order when the dictionary is built at a
/// different address. Two reads in a tight loop usually reuse one address
/// and agree by accident. A block of a new size retained between the reads
/// moves the next allocation, which is what a real session does between two
/// readings of one transcript entry.
public enum HeapChurn {
    /// The number of readings that makes an address-dependent read
    /// near-certain to disagree with itself at least once.
    public static let readingCount = 128

    /// The element count added to each successive retained block.
    private static let blockCountStep = 37

    /// The bound the retained block's element count wraps at, so the block
    /// sizes cycle through many size classes instead of growing without end.
    private static let blockCountLimit = 4096

    /// Reads `read` `count` times, retaining one block of a new size before
    /// each read. Every block stays alive until the last read returns.
    ///
    /// - Parameters:
    ///   - count: The number of reads.
    ///   - read: The read to repeat.
    /// - Returns: The readings, in read order.
    /// - Throws: What `read` throws.
    public static func readings<Reading>(count: Int, _ read: () throws -> Reading) rethrows -> [Reading] {
        let retained = try (0..<count).map { index -> (block: [Int], reading: Reading) in
            let block = [Int](repeating: index, count: (index * blockCountStep) % blockCountLimit + 1)
            return (block, try read())
        }
        return retained.map(\.reading)
    }
}
