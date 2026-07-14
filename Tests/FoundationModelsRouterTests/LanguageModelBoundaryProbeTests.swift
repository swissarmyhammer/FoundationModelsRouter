#if canImport(FoundationModels)
    import Foundation
    import FoundationModels
    import Testing

    @testable import FoundationModelsRouter

    // MARK: - Recorders

    /// Records every transcript a probe model's executor observed on each
    /// call, so a test can assert on it once the (Sendable) executor call has
    /// returned.
    actor ProbeTranscriptRecorder {
        private(set) var transcripts: [Transcript] = []
        func record(_ transcript: Transcript) { transcripts.append(transcript) }
    }

    /// Records every response text a wrapper observed after delegating a call
    /// to its wrapped model — the evidence for fact 3 (a conforming wrapper
    /// can observe the response it emits): the wrapper reads this text back
    /// from a real, publicly readable `LanguageModelSession.Response.content`
    /// *before* re-emitting it, so this recorder proves the wrapper actually
    /// possessed the text, not merely relayed an opaque token it never saw.
    actor ProbeResponseRecorder {
        private(set) var responses: [String] = []
        func record(_ text: String) { responses.append(text) }
    }

    // MARK: - Innermost stub model

    /// The innermost stub `LanguageModel` conformance: always emits
    /// ``cannedResponseText`` regardless of prompt content, recording every
    /// transcript its executor observed into ``transcripts``.
    ///
    /// Stands in for `MLXFoundationModels.MLXLanguageModel` at the raw SDK
    /// protocol boundary — the plain, deterministic stub the acceptance
    /// criteria calls for, so ``PassthroughProbeModel`` below has a real
    /// (non-mock) model to wrap.
    struct ProbeStubModel: LanguageModel {
        let cannedResponseText: String
        let transcripts: ProbeTranscriptRecorder

        var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
        var executorConfiguration: Executor.Configuration {
            Executor.Configuration(cannedResponseText: cannedResponseText, transcripts: transcripts)
        }

        /// Executor conformance that records every request transcript it
        /// observes — via `configuration.transcripts` — into
        /// ``ProbeTranscriptRecorder``, so tests can assert on the
        /// transcripts this stub's boundary actually received.
        struct Executor: LanguageModelExecutor {
            struct Configuration: Sendable, Hashable {
                let cannedResponseText: String
                let transcripts: ProbeTranscriptRecorder

                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.cannedResponseText == rhs.cannedResponseText && lhs.transcripts === rhs.transcripts
                }

                func hash(into hasher: inout Hasher) {
                    hasher.combine(cannedResponseText)
                    hasher.combine(ObjectIdentifier(transcripts))
                }
            }

            typealias Model = ProbeStubModel

            private let configuration: Configuration

            init(configuration: Configuration) throws {
                self.configuration = configuration
            }

            /// Fact 1 in action: `request.transcript` is the full session
            /// transcript for *this* call, not a delta — recorded into
            /// `configuration.transcripts` so both this innermost boundary
            /// and (via ``PassthroughProbeModel``, wrapping this model) the
            /// wrapper boundary are independently inspectable by a test.
            /// Fact 2 in action: nothing on `self` or `configuration`
            /// accumulates state across calls; every call's answer depends
            /// only on this call's own `configuration` and `request`.
            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: ProbeStubModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                await configuration.transcripts.record(request.transcript)
                await channel.send(
                    .response(action: .appendText(configuration.cannedResponseText, tokenCount: 1))
                )
            }
        }
    }

    // MARK: - Passthrough wrapper model

    /// A passthrough `LanguageModel` wrapping ``ProbeStubModel``.
    ///
    /// Every call records the transcript this call received (fact 1/2, at the
    /// wrapper boundary), drives the wrapped model through a real, nested
    /// `LanguageModelSession` to obtain its response text, records that text
    /// (fact 3), then re-emits it as this wrapper's own response event.
    ///
    /// The nested session — rather than relaying the wrapped model's raw
    /// `Executor.respond` call over a second, hand-rolled
    /// `LanguageModelExecutorGenerationChannel` — is deliberate:
    /// `LanguageModelExecutorGenerationChannel.Event` is a write-only,
    /// static-constructor token with no public accessor to read a value back
    /// out of an event built by another executor. `LanguageModelSession.
    /// respond(to:)`'s return value, by contrast, is a plain, publicly
    /// readable `Response<String>` (`.content`) — the mechanism this wrapper
    /// (and the router's real ``MLXFoundationModelsSessionBackend``) actually
    /// uses to observe what a wrapped model produced.
    struct PassthroughProbeModel: LanguageModel {
        let wrapped: ProbeStubModel
        let transcripts: ProbeTranscriptRecorder
        let responses: ProbeResponseRecorder

        var capabilities: LanguageModelCapabilities { wrapped.capabilities }
        var executorConfiguration: Executor.Configuration {
            Executor.Configuration(wrapped: wrapped, transcripts: transcripts, responses: responses)
        }

        /// Executor that wraps ``ProbeStubModel``'s executor: it records the
        /// transcript this call observed and the response text it delegates
        /// to and re-emits, driving the wrapped model through a nested
        /// `LanguageModelSession` (see the type-level doc comment above for
        /// why a nested session is used instead of relaying the wrapped
        /// executor's raw channel).
        struct Executor: LanguageModelExecutor {
            /// Configuration for the passthrough executor.
            ///
            /// Includes `wrapped`'s own identifying field
            /// (`cannedResponseText`) and its recorder's identity, not just
            /// this wrapper's own recorders — the SDK caches executors
            /// keyed by `Configuration` equality (see
            /// `MLXLanguageModel.executorConfiguration`'s doc comment:
            /// "Configuration the framework uses to create and cache
            /// executors"), so omitting `wrapped` here would let two
            /// configurations that wrap *different* stub models collide
            /// in that cache and silently reuse the wrong executor.
            struct Configuration: Sendable, Hashable {
                let wrapped: ProbeStubModel
                let transcripts: ProbeTranscriptRecorder
                let responses: ProbeResponseRecorder

                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.transcripts === rhs.transcripts && lhs.responses === rhs.responses
                        && lhs.wrapped.cannedResponseText == rhs.wrapped.cannedResponseText
                        && lhs.wrapped.transcripts === rhs.wrapped.transcripts
                }

                func hash(into hasher: inout Hasher) {
                    hasher.combine(ObjectIdentifier(transcripts))
                    hasher.combine(ObjectIdentifier(responses))
                    hasher.combine(wrapped.cannedResponseText)
                    hasher.combine(ObjectIdentifier(wrapped.transcripts))
                }
            }

            typealias Model = PassthroughProbeModel

            private let configuration: Configuration

            init(configuration: Configuration) throws {
                self.configuration = configuration
            }

            /// Fact 1 in action: records the full transcript this call
            /// received via `configuration.transcripts`, mirroring
            /// ``ProbeStubModel/Executor/respond(to:model:streamingInto:)``.
            /// Fact 3 in action: drives the wrapped model through a nested
            /// `LanguageModelSession` to obtain its response text, records
            /// that text via `configuration.responses` — proving the
            /// wrapper actually possessed the text before re-emitting it as
            /// its own `.response` event, rather than merely relaying an
            /// opaque token from the wrapped executor's raw channel.
            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: PassthroughProbeModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                await configuration.transcripts.record(request.transcript)

                let innerSession = LanguageModelSession(model: configuration.wrapped, tools: [])
                let response = try await innerSession.respond(to: "delegated probe turn")

                await configuration.responses.record(response.content)

                await channel.send(.response(action: .appendText(response.content, tokenCount: 1)))
            }
        }
    }

    // MARK: - Suite

    /// De-risks the recording-LanguageModel-handle design (plan section 8,
    /// task 9f3ev1k) BEFORE it gets built: a compiling, GPU-free probe that a
    /// custom `LanguageModel` conformer wrapping another model can see the
    /// transcript passed in on every call, and can observe the response text
    /// it delegates to and re-emits.
    @Suite("LanguageModel boundary probe: transcript visibility, statelessness, and response observability")
    struct LanguageModelBoundaryProbeTests {
        @Test("a passthrough wrapper observes the transcript passed to a call and the response text it delegates and emits")
        func passthroughWrapperObservesTranscriptAndResponse() async throws {
            // Deliberately separate recorders for the stub's own (inner,
            // throwaway one-turn session) transcript versus the wrapper's
            // (outer, real session) transcript — sharing one recorder between
            // them conflated the two and produced a bogus double-count (an
            // earlier version of this test caught exactly that bug: sharing
            // one `ProbeTranscriptRecorder` made every outer turn record two
            // transcripts instead of one).
            let stubTranscripts = ProbeTranscriptRecorder()
            let wrapperTranscripts = ProbeTranscriptRecorder()
            let responses = ProbeResponseRecorder()
            let stub = ProbeStubModel(cannedResponseText: "stub says hello", transcripts: stubTranscripts)
            let wrapper = PassthroughProbeModel(wrapped: stub, transcripts: wrapperTranscripts, responses: responses)

            let session = LanguageModelSession(model: wrapper, tools: [], instructions: "be terse")
            let response = try await session.respond(to: "hello there")

            // Fact 3: the wrapper actually possessed the response text before
            // re-emitting it — not a value asserted independently of what was
            // actually delegated and sent onward.
            let recordedResponses = await responses.responses
            #expect(recordedResponses == ["stub says hello"])
            #expect(response.content == "stub says hello")

            // Fact 1: the wrapper's own executor call received the full
            // session transcript for this turn (the leading `.instructions`
            // entry plus this turn's new `.prompt` entry) — not just new
            // content since a prior call.
            let recordedWrapperTranscripts = await wrapperTranscripts.transcripts
            let wrapperTranscript = try #require(recordedWrapperTranscripts.first)
            #expect(wrapperTranscript.count == 2)

            // Fact 1 also holds at the innermost boundary: the stub's own
            // executor call (driven by the wrapper's nested, single-turn
            // session) received that session's one `.prompt` entry as its
            // full transcript.
            let recordedStubTranscripts = await stubTranscripts.transcripts
            let stubTranscript = try #require(recordedStubTranscripts.first)
            #expect(stubTranscript.count == 1)
        }

        @Test("a second call's transcript is the full accumulated history again, not just the new turn's delta")
        func secondCallReceivesFullAccumulatedTranscriptAgain() async throws {
            let stubTranscripts = ProbeTranscriptRecorder()
            let wrapperTranscripts = ProbeTranscriptRecorder()
            let responses = ProbeResponseRecorder()
            let stub = ProbeStubModel(cannedResponseText: "ok", transcripts: stubTranscripts)
            let wrapper = PassthroughProbeModel(wrapped: stub, transcripts: wrapperTranscripts, responses: responses)

            let session = LanguageModelSession(model: wrapper, tools: [])
            _ = try await session.respond(to: "first turn")
            _ = try await session.respond(to: "second turn")

            let recordedTranscripts = await wrapperTranscripts.transcripts
            #expect(recordedTranscripts.count == 2)
            // First call: just the first turn's own prompt (no instructions).
            #expect(recordedTranscripts[0].count == 1)
            // Second call: full accumulated history so far — first turn's
            // prompt + response, plus the second turn's new prompt — proving
            // the "no session identity; every respond() call receives the
            // complete history again" contract (see MLXLanguageModel.swift's
            // `preparedInputMappingImageFailures` doc comment) applies at the
            // raw `LanguageModel` boundary generally, not just to the MLX
            // adapter.
            #expect(recordedTranscripts[1].count == 3)

            // Fact 3, across both calls: the wrapper recorded the response
            // text it delegated to and re-emitted on each of the two turns,
            // not just the first.
            let recordedResponses = await responses.responses
            #expect(recordedResponses.count == 2)
            #expect(recordedResponses == ["ok", "ok"])

            // The stub's own executor was likewise called once per outer
            // turn (each via a fresh, independent one-turn inner session),
            // each time seeing just that inner session's single `.prompt`
            // entry — the stub has no visibility into (and no dependency on)
            // the outer session's growing history, only the wrapper does.
            let recordedStubTranscripts = await stubTranscripts.transcripts
            #expect(recordedStubTranscripts.count == 2)
            #expect(recordedStubTranscripts.allSatisfy { $0.count == 1 })
        }
    }
#endif  // canImport(FoundationModels)
