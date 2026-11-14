import Foundation
import FoundationModelsRouter
import Logging

// Standard output carries the report, so each log line goes to standard
// error. The router logs each span at info, which buries the progress lines,
// so only warnings and errors print. This runs one time, before any log call.
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = .warning
    return handler
}

/// # Benchmark: generation speed of the `standard` model
///
/// Resolves a profile with the model under test in its `standard` slot, then
/// times that model through ``RoutedSession/streamEvents(to:maxTokens:)``. Each run
/// opens a new session and sends two messages:
///
/// - **cold**: a prompt of `--prompt-tokens` tokens that opens with a unique
///   nonce, so no prompt cache holds any of it. This times the prefill of the
///   whole prompt.
/// - **warm**: a short follow-up on the same session, whose earlier turn the
///   prompt cache of the session holds. This times the reuse of that prefix.
///
/// The numbers come from ``SessionEvent/generationCall(_:)``, which the
/// session measures around each generation call: the fed and the cached
/// tokens, the time to the first token (the prefill) and the decode time. The
/// benchmark also times its own wait from the send to the first streamed
/// fragment, which adds the session's queueing to the prefill.
///
/// With `--drafter`, the model decodes speculatively, and each sample records
/// how many drafted tokens the model accepted. With `--compare`, the program
/// loads no model: it reads the JSON files of earlier runs and prints their
/// medians side by side.
///
/// Run with `swift run -c release --package-path Benchmarks RouterBenchmark --help`.

// MARK: - Options

/// The command line of the benchmark.
struct Options {
    /// The model under test, in the `standard` slot.
    var model = ModelRef("mlx-community/Qwen2.5-3B-Instruct-4bit")

    /// The drafter of the model under test, or `nil` for plain decode: an MTP
    /// checkpoint for an MLX model, a GGUF drafter (DFlash or a draft model)
    /// for a GGUF model.
    var drafter: ModelRef?

    /// Whether a GGUF model may decode speculatively: with the MTP layers of
    /// its file, or with ``drafter``. `false` times plain decode of a GGUF
    /// file that holds MTP layers.
    var speculativeDecoding = true

    /// The name of the run in the JSON file and in `--compare`, or `nil` for
    /// the model reference.
    var label: String?

    /// The JSON files to compare. Not empty only in the compare mode.
    var compare: [String] = []

    /// The model of the `flash` and the `decision` slots. The router requires
    /// a `flash` model that differs from the `standard` one, so this is a
    /// small model that costs little memory. The benchmark never sends to it.
    var flash = ModelRef("mlx-community/SmolLM-135M-Instruct-4bit")

    /// The tokens of the cold prompt, before the chat template of the model.
    var promptTokens = 1024

    /// The token ceiling of each answer.
    var maxTokens = 256

    /// The measured runs.
    var runs = 3

    /// The runs before the measured runs, which the report leaves out. The
    /// first generation of a model compiles its kernels.
    var warmup = 1

    /// Where to write the samples as JSON, or `nil` for no file.
    var jsonPath: String?

    /// Whether to echo each answer, reasoning included, to standard error as it
    /// streams: a check that the model answers coherently before it is timed.
    var showText = false

    static let usage = """
        usage: RouterBenchmark [options]

          --model <ref>          The model to time. A Hub repo, a repo/file.gguf, or a local
                                 folder (~/..., ./..., /...). Default: \(Options().model.stringValue)
          --drafter <ref>        Decode speculatively with this drafter: an MTP checkpoint for an
                                 MLX model, a DFlash or draft GGUF for a GGUF model. Default: none
          --no-speculation       Turn speculative decoding off for a GGUF model, also when its
                                 file holds MTP layers.
          --flash <ref>          The flash slot model, which must differ from --model and is not
                                 timed. Default: \(Options().flash.stringValue)
          --prompt-tokens <n>    Tokens in the cold prompt. Default: \(Options().promptTokens)
          --max-tokens <n>       Token ceiling of each answer. Default: \(Options().maxTokens)
          --runs <n>             Measured runs. Default: \(Options().runs)
          --warmup <n>           Unmeasured runs first. Default: \(Options().warmup)
          --json <path>          Also write every sample to this JSON file.
          --show-text            Echo each answer, reasoning included, to standard error.
          --label <name>         The name of the run in the JSON file. Default: the model ref
          --help                 Print this text.

        usage: RouterBenchmark --compare <file.json>...

          Prints the medians of the JSON files of earlier runs side by side. Loads no model.
        """

    /// Parses `arguments`, which hold no program name.
    ///
    /// - Parameter arguments: The arguments of the process after its name.
    /// - Returns: The options, or `nil` when the caller asked for the help.
    /// - Throws: ``OptionError`` for an unknown flag or a bad value.
    static func parse(_ arguments: [String]) throws -> Options? {
        var options = Options()
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            if flag == "--help" || flag == "-h" { return nil }
            if flag == "--compare" {
                guard !rest.isEmpty else { throw OptionError.missingValue(flag) }
                options.compare = Array(rest)
                return options
            }
            if flag == "--no-speculation" {
                options.speculativeDecoding = false
                continue
            }
            if flag == "--show-text" {
                options.showText = true
                continue
            }
            guard let value = rest.popFirst() else { throw OptionError.missingValue(flag) }
            switch flag {
            case "--model": options.model = ModelRef(value)
            case "--drafter": options.drafter = ModelRef(value)
            case "--flash": options.flash = ModelRef(value)
            case "--label": options.label = value
            case "--prompt-tokens": options.promptTokens = try positive(value, flag)
            case "--max-tokens": options.maxTokens = try positive(value, flag)
            case "--runs": options.runs = try positive(value, flag)
            case "--warmup": options.warmup = try nonNegative(value, flag)
            case "--json": options.jsonPath = value
            default: throw OptionError.unknown(flag)
            }
        }
        return options
    }

    /// The model under test with its drafter, when there is one.
    var target: ModelRef {
        guard let drafter else { return model }
        return ModelRef(repo: model.repo, path: model.path, revision: model.revision, drafter: drafter)
    }

    private static func positive(_ value: String, _ flag: String) throws -> Int {
        guard let number = Int(value), number > 0 else { throw OptionError.badValue(flag, value) }
        return number
    }

    private static func nonNegative(_ value: String, _ flag: String) throws -> Int {
        guard let number = Int(value), number >= 0 else { throw OptionError.badValue(flag, value) }
        return number
    }
}

/// Why the command line did not parse.
enum OptionError: Error, CustomStringConvertible {
    case unknown(String)
    case missingValue(String)
    case badValue(String, String)

    var description: String {
        switch self {
        case .unknown(let flag): "unknown option \(flag)"
        case .missingValue(let flag): "\(flag) needs a value"
        case .badValue(let flag, let value): "\(flag) takes a number, not \(value)"
        }
    }
}

/// Why a benchmark run failed.
enum BenchmarkError: Error, CustomStringConvertible {
    /// The backend of the model reported no usage for a message.
    case noUsage(Phase)

    var description: String {
        switch self {
        case .noUsage(let phase):
            "the \(phase.rawValue) message reported no generation call; the backend measures no usage"
        }
    }
}

// MARK: - Samples

/// Which message of a run a sample times.
enum Phase: String, Codable, CaseIterable {
    case cold
    case warm
}

/// The measurement of one generation call.
struct Call: Codable {
    let tokensIn: Int
    let tokensCached: Int?
    let tokensOut: Int
    /// From the start of the call to its first output token.
    let timeToFirstToken: Double?
    /// From the first output token to the end of the call.
    let decodeSeconds: Double?
    /// The whole time of the call.
    let seconds: Double?
    /// Whether the output of the call reached the session in one event, so
    /// its first token cannot be seen and it has no split of its time.
    let outputBuffered: Bool
    let finishReason: String
    /// What speculative decoding did, or `nil` when the model has no drafter
    /// and no MTP layers.
    let speculation: Speculation?

    init(_ usage: GenerationCallUsage) {
        tokensIn = usage.tokensIn
        tokensCached = usage.tokensCached
        tokensOut = usage.tokensOut
        timeToFirstToken = usage.timeToFirstToken?.seconds
        decodeSeconds = usage.decodeTime?.seconds
        seconds = usage.callDuration?.seconds
        outputBuffered = usage.outputBuffered
        finishReason = "\(usage.finishReason)"
        speculation = usage.speculativeDecoding.map(Speculation.init)
    }
}

/// The measurement of one message: each generation call of its answer.
///
/// A thinking model can take more than one call for one message: when its
/// reasoning reaches the token ceiling, the session continues the answer in a
/// new call, which reuses the cache of the first. So the prefill of the
/// message is the prefill of its first call, and its decode rate is over the
/// decode of every call.
struct Sample: Codable {
    let run: Int
    let phase: Phase
    let calls: [Call]
    /// From the send to the first streamed fragment, as the caller sees it.
    let clientTimeToFirstToken: Double?

    /// The first call: the one that prefilled the message.
    var first: Call { calls[0] }

    var tokensIn: Int { first.tokensIn }
    var tokensCached: Int? { first.tokensCached }

    /// The tokens the first call prefilled: the fed tokens the cache did not
    /// hold.
    var tokensPrefilled: Int { first.tokensIn - (first.tokensCached ?? 0) }

    /// The tokens of every call.
    var tokensOut: Int { calls.map(\.tokensOut).reduce(0, +) }

    var timeToFirstToken: Double? { first.timeToFirstToken }

    var prefillTokensPerSecond: Double? {
        timeToFirstToken.flatMap { $0 > 0 ? Double(tokensPrefilled) / $0 : nil }
    }

    /// The tokens over the decode time of the calls that have one. A buffered
    /// call has no decode time, so its tokens are left out.
    var decodeTokensPerSecond: Double? {
        let timed = calls.filter { $0.decodeSeconds != nil }
        let seconds = timed.compactMap(\.decodeSeconds).reduce(0, +)
        guard seconds > 0 else { return nil }
        return Double(timed.map(\.tokensOut).reduce(0, +)) / seconds
    }

    var speculations: [Speculation] { calls.compactMap(\.speculation) }
    var finishReasons: [String] { calls.map(\.finishReason) }
}

/// What speculative decoding did in one call: the
/// ``SpeculativeDecodingOutcome`` of the call.
struct Speculation: Codable {
    let speculated: Bool
    let fallbackReason: String?
    let acceptedDraftTokens: Int
    let draftedTokens: Int

    init(_ outcome: SpeculativeDecodingOutcome) {
        speculated = outcome.speculated
        fallbackReason = outcome.fallbackReason
        acceptedDraftTokens = outcome.acceptedDraftTokenCount
        draftedTokens = outcome.draftedTokenCount
    }
}

/// The whole report, as `--json` writes it.
struct Report: Codable {
    let label: String
    let model: String
    let drafter: String?
    let speculativeDecoding: Bool
    let promptTokens: Int
    let maxTokens: Int
    let contextTokens: Int
    let samples: [Sample]
}

extension Duration {
    /// This duration in seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

// MARK: - Prompts

/// The system instructions of every benchmark session.
let instructions = "You are a careful technical writer. Answer in plain prose."

/// Text that the cold prompt repeats to reach its size. It is varied prose, so
/// it tokenizes like a real document rather than like one repeated word.
let fillerParagraph = """
    The storage service keeps each tenant's records in a separate partition. A write lands in \
    the journal first, then a background compactor folds the journal into sorted segments. Reads \
    consult the newest segment before older ones, and a bloom filter skips segments that cannot \
    hold the key. When a node fails, its partitions move to the replicas that hold the most \
    recent journal offset, and clients retry with exponential backoff capped at eight seconds.

    """

/// The cold prompt of one run: a unique nonce, filler up to `tokens` tokens as
/// `counter` counts them, and the task.
///
/// - Parameters:
///   - tokens: The size of the prompt in tokens.
///   - counter: The token counter of the model under test.
/// - Returns: The prompt text.
func coldPrompt(tokens: Int, counter: any TokenCounter) -> String {
    let nonce = "Reference \(UUID().uuidString).\n\n"
    let task = "\n\nSummarize the design above in detail, section by section."
    let fillerBudget = max(0, tokens - counter.count(nonce) - counter.count(task))
    let paragraphTokens = max(1, counter.count(fillerParagraph))
    let filler = String(repeating: fillerParagraph, count: fillerBudget / paragraphTokens + 1)
    return nonce + counter.prefix(of: filler, tokens: fillerBudget) + task
}

/// The warm prompt of each run: short, so its time is the reuse of the cached
/// earlier turn.
let warmPrompt = "Now list three risks of that design, with one paragraph for each."

// MARK: - One message

/// Sends `prompt` and measures its answer.
///
/// - Parameters:
///   - prompt: The message.
///   - session: The session that answers.
///   - maxTokens: The token ceiling of the answer.
///   - run: The number of the run, for the sample.
///   - phase: Which message of the run this is.
///   - showText: Whether to echo the answer to standard error as it streams.
/// - Returns: The sample of every generation call of the answer.
/// - Throws: Whatever the answer throws, or ``BenchmarkError/noUsage(_:)``.
func measure(
    _ prompt: String, on session: any RoutedSession, maxTokens: Int, run: Int, phase: Phase, showText: Bool
) async throws -> Sample {
    let clock = ContinuousClock()
    let sentAt = clock.now
    var firstFragmentAt: ContinuousClock.Instant?
    var calls: [Call] = []
    var echoedReasoning: Bool?

    for try await event in await session.streamEvents(to: prompt, maxTokens: maxTokens) {
        switch event {
        case .textDelta(let fragment), .reasoningDelta(let fragment):
            if firstFragmentAt == nil {
                firstFragmentAt = clock.now
                if showText { note("--- run \(run) \(phase.rawValue)") }
            }
            if showText {
                let reasoning: Bool
                if case .reasoningDelta = event { reasoning = true } else { reasoning = false }
                if echoedReasoning != reasoning {
                    note(echoedReasoning == nil ? "" : "\n")
                    note(reasoning ? "[reasoning]" : "[answer]")
                    echoedReasoning = reasoning
                }
                echo(fragment)
            }
        case .generationCall(let usage):
            calls.append(Call(usage))
        default:
            break
        }
    }

    if showText, firstFragmentAt != nil { note("") }
    guard !calls.isEmpty else { throw BenchmarkError.noUsage(phase) }
    return Sample(
        run: run, phase: phase, calls: calls,
        clientTimeToFirstToken: firstFragmentAt.map { ($0 - sentAt).seconds })
}

// MARK: - Report

/// The median of `values`, or `nil` when there are none.
func median(_ values: [Double]) -> Double? {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return nil }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

/// `value` with `format`, or a dash when there is no value.
func cell(_ value: Double?, _ format: String) -> String {
    value.map { String(format: format, $0) } ?? "-"
}

/// `text` padded on the left to `width`.
func pad(_ text: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - text.count)) + text
}

/// The speculation of `samples`: the share of the drafted tokens that the
/// model accepted, the fallback reason when the model decoded plain, or a dash
/// when it has no drafting at all.
///
/// - Parameter samples: The samples of one phase, or one sample.
/// - Returns: The text of the cell.
func speculationCell(_ samples: [Sample]) -> String {
    let speculations = samples.flatMap(\.speculations)
    guard !speculations.isEmpty else { return "-" }
    if let reason = speculations.lazy.compactMap(\.fallbackReason).first { return "off: \(reason)" }
    let drafted = speculations.map(\.draftedTokens).reduce(0, +)
    guard drafted > 0 else { return "0 drafted" }
    let accepted = speculations.map(\.acceptedDraftTokens).reduce(0, +)
    return String(format: "%.0f%%", 100 * Double(accepted) / Double(drafted))
}

/// The columns of the tables.
let headers = [
    "run", "phase", "calls", "in", "cached", "prefill", "out", "ttft s", "client s", "prefill t/s", "decode t/s",
    "accepted",
]
let widths = [3, 5, 5, 6, 6, 7, 5, 8, 8, 11, 10, 8]

/// One table row: each cell padded to its column.
func row(_ cells: [String], widths: [Int] = widths) -> String {
    zip(cells, widths).map { pad($0, $1) }.joined(separator: "  ")
}

/// The cells of one sample.
func cells(of sample: Sample) -> [String] {
    [
        "\(sample.run)", sample.phase.rawValue, "\(sample.calls.count)", "\(sample.tokensIn)",
        sample.tokensCached.map(String.init) ?? "-", "\(sample.tokensPrefilled)", "\(sample.tokensOut)",
        cell(sample.timeToFirstToken, "%.3f"), cell(sample.clientTimeToFirstToken, "%.3f"),
        cell(sample.prefillTokensPerSecond, "%.1f"), cell(sample.decodeTokensPerSecond, "%.1f"),
        speculationCell([sample]),
    ]
}

/// The medians of the samples of one phase, as the cells of a row whose
/// first cell is `first`.
func medianCells(of group: [Sample], first: String) -> [String] {
    [
        first, group.first?.phase.rawValue ?? "",
        cell(median(group.map { Double($0.calls.count) }), "%.0f"),
        cell(median(group.map { Double($0.tokensIn) }), "%.0f"),
        cell(median(group.compactMap { $0.tokensCached.map(Double.init) }), "%.0f"),
        cell(median(group.map { Double($0.tokensPrefilled) }), "%.0f"),
        cell(median(group.map { Double($0.tokensOut) }), "%.0f"),
        cell(median(group.compactMap(\.timeToFirstToken)), "%.3f"),
        cell(median(group.compactMap(\.clientTimeToFirstToken)), "%.3f"),
        cell(median(group.compactMap(\.prefillTokensPerSecond)), "%.1f"),
        cell(median(group.compactMap(\.decodeTokensPerSecond)), "%.1f"),
        speculationCell(group),
    ]
}

/// The samples of each phase that has any, in the order of ``Phase``.
func phases(of samples: [Sample]) -> [[Sample]] {
    Phase.allCases.map { phase in samples.filter { $0.phase == phase } }.filter { !$0.isEmpty }
}

/// Prints one row per sample, then the median of each phase.
///
/// - Parameter samples: The measured samples.
func printReport(_ samples: [Sample]) {
    print(row(headers))
    for sample in samples {
        print(row(cells(of: sample)))
    }
    print("\nmedian over \(Set(samples.map(\.run)).count) runs")
    for group in phases(of: samples) {
        print(row(medianCells(of: group, first: "")))
    }
    let stops = Set(samples.flatMap(\.finishReasons)).sorted().joined(separator: ", ")
    print("finish reasons: \(stops)")
    let buffered = samples.filter { $0.first.outputBuffered }.count
    if buffered > 0 {
        print("\(buffered) messages had a buffered first call, so they have no ttft and no prefill rate")
    }
}

/// Prints the medians of each report, one row per phase, and the decode rate
/// of each against the first report.
///
/// - Parameter reports: The reports, the first one the baseline.
func printComparison(_ reports: [Report]) {
    let labelWidth = max(5, reports.map(\.label.count).max() ?? 0)
    let compareHeaders = ["label"] + headers.dropFirst() + ["vs first"]
    let compareWidths = [labelWidth] + widths.dropFirst() + [8]
    print(row(compareHeaders, widths: compareWidths))

    let baseline = reports.first.map { decodeRates(of: $0) } ?? [:]
    for report in reports {
        let rates = decodeRates(of: report)
        for group in phases(of: report.samples) {
            let phase = group[0].phase
            let speedup = zip(rates[phase], baseline[phase]).map { $0 / $1 }
            print(row(medianCells(of: group, first: report.label) + [cell(speedup, "%.2fx")], widths: compareWidths))
        }
    }
    print("")
    for report in reports {
        let speculation = report.speculativeDecoding ? "" : " (speculation off)"
        print("\(report.label): \(report.model)\(report.drafter.map { " + \($0)" } ?? "")\(speculation)")
    }
}

/// The median decode rate of each phase of `report`.
func decodeRates(of report: Report) -> [Phase: Double] {
    var rates: [Phase: Double] = [:]
    for group in phases(of: report.samples) {
        rates[group[0].phase] = median(group.compactMap(\.decodeTokensPerSecond))
    }
    return rates
}

/// The pair of two optionals, or `nil` when either is `nil`.
func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Writes `message` to standard error.
func note(_ message: String) {
    echo(message + "\n")
}

/// Writes `fragment` to standard error, with no line break.
func echo(_ fragment: String) {
    FileHandle.standardError.write(Data(fragment.utf8))
}

// MARK: - Main

let options: Options
do {
    guard let parsed = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
        print(Options.usage)
        exit(0)
    }
    options = parsed
} catch {
    note("error: \(error)\n\n\(Options.usage)")
    exit(2)
}

if !options.compare.isEmpty {
    let decoder = JSONDecoder()
    let reports = try options.compare.map {
        try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
    }
    printComparison(reports)
    exit(0)
}

let recordingsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("RouterBenchmark-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: recordingsDir) }

let router = Router(
    recordingsDir: recordingsDir,
    loader: LiveModelLoader(reporting: { _ in }, speculativeDecoding: options.speculativeDecoding))

// The model under test is the `standard` slot. The router requires a
// different `flash` model, and the `decision` slot names that one too, so the
// pool shares one resident copy between them. The embedding slot keeps the
// small default ANE model.
let definition = ProfileDefinition(
    name: "benchmark",
    description: "The model under test in the standard slot.",
    standard: [options.target],
    flash: [options.flash],
    embedding: ["erjigit17/embeddinggemma-300m-ane-coreml"],
    decision: [options.flash]
)

note("resolving \(options.target.stringValue)\(options.drafter.map { " with drafter \($0.stringValue)" } ?? "")")
let progress = ResolutionProgress()
async let resolvedProfile = router.resolve(profile: definition, reporting: progress)
for await transition in progress.phases {
    note("  \(transition.phase) \(Int((transition.fraction * 100).rounded()))%")
}
let profile = try await resolvedProfile
let model = profile.standard

print("model    \(model.chosen.stringValue)")
print("drafter  \(options.drafter?.stringValue ?? "none")")
print("speculative decoding \(options.speculativeDecoding ? "on when the model can" : "off")")
print("context  \(model.contextTokens) tokens")
print("prompt   \(options.promptTokens) tokens, max \(options.maxTokens) out, \(options.runs) runs + \(options.warmup) warmup\n")

var samples: [Sample] = []
for run in 1...(options.warmup + options.runs) {
    let measured = run > options.warmup
    let number = run - options.warmup
    note(measured ? "run \(number)/\(options.runs)" : "warmup \(run)/\(options.warmup)")

    let session = model.makeSession(instructions: instructions)
    let prompt = coldPrompt(tokens: options.promptTokens, counter: model.tokenCounter)
    let cold = try await measure(prompt, on: session, maxTokens: options.maxTokens, run: number, phase: .cold,
        showText: options.showText)
    let warm = try await measure(warmPrompt, on: session, maxTokens: options.maxTokens, run: number, phase: .warm,
        showText: options.showText)
    await session.close()

    if measured { samples += [cold, warm] }
}

printReport(samples)

if let jsonPath = options.jsonPath {
    let report = Report(
        label: options.label ?? options.model.stringValue, model: model.chosen.stringValue,
        drafter: options.drafter?.stringValue, speculativeDecoding: options.speculativeDecoding,
        promptTokens: options.promptTokens, maxTokens: options.maxTokens,
        contextTokens: model.contextTokens, samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: jsonPath))
    note("wrote \(jsonPath)")
}
