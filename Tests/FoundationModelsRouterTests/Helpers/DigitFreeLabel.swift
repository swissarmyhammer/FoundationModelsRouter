/// Labels with no digit in them, for test lines that must differ in text and
/// not only in digits (task ^ez2g5gw). The repetition detector compares the
/// shape of a line, and two lines that differ only in their digits have the
/// same shape.
enum DigitFreeLabel {
    /// The letters that spell the decimal digits `0` to `9`, in order.
    private static let letters = Array("abcdefghij")

    /// `number` spelled with one letter of ``letters`` for each decimal digit.
    /// Two different numbers give two different labels.
    ///
    /// - Parameter number: A number that is not negative.
    /// - Returns: The label, with no digit in it.
    static func spelling(_ number: Int) -> String {
        String(String(number).compactMap { digit in digit.wholeNumberValue.map { letters[$0] } })
    }
}
