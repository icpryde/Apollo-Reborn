//
//  ApolloFoundationModels.swift
//  Apollo-Reborn
//
//  Swift -> ObjC bridge to Apple's on-device FoundationModels framework
//  (iOS 26+). The rest of the tweak is pure Objective-C/Logos and cannot call
//  the Swift-only `LanguageModelSession` / `SystemLanguageModel` API directly,
//  nor `async` functions, so this file exposes a small `@objc` surface with
//  completion-block callbacks that the ObjC feature module (ApolloAISummary.xm)
//  drives.
//
//  The whole framework is weak-linked (see Makefile `-weak_framework
//  FoundationModels`) and every entry point is guarded by `#available(iOS 26)`,
//  so the tweak still loads on older OSes — it simply reports "unavailable".
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@objc(ApolloFoundationModels)
public final class ApolloFoundationModels: NSObject {

    @objc public static let shared = ApolloFoundationModels()

    /// Prepared, short-lived sessions keyed by the post/type that will consume
    /// them. Prewarming the actual instructed session avoids paying session
    /// setup and guardrail preparation again when generation starts.
    private var preparedSessions: [String: Any] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Mirrors `SystemLanguageModel.Availability`, flattened to an Int so ObjC
    /// can branch without bridging the Swift enum.
    ///   0 = available
    ///   1 = appleIntelligenceNotEnabled  (user hasn't turned on Apple Intelligence)
    ///   2 = modelNotReady                (assets still downloading)
    ///   3 = deviceNotEligible            (hardware can't run it)
    ///   4 = osTooOld                     (< iOS 26, framework absent)
    ///   5 = unknown
    @objc public func availabilityStatus() -> Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return 0
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return 1
                case .modelNotReady:               return 2
                case .deviceNotEligible:           return 3
                @unknown default:                  return 5
                }
            @unknown default:
                return 5
            }
        }
        #endif
        return 4
    }

    /// Convenience for ObjC: is the on-device model ready to generate right now?
    @objc public func isModelAvailable() -> Bool {
        return availabilityStatus() == 0
    }

    /// Prepare the exact instructed session that a subsequent summarize call
    /// will use. Sessions are consumed once and discarded so unrelated Reddit
    /// threads never accumulate transcript context.
    @objc public func prepareSession(_ identifier: String, instructions: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard !identifier.isEmpty, preparedSessions[identifier] == nil else { return }
            let session = LanguageModelSession(instructions: instructions)
            preparedSessions[identifier] = session
            session.prewarm()
        }
        #endif
    }

    @objc public func discardPreparedSession(_ identifier: String) {
        preparedSessions.removeValue(forKey: identifier)
    }

    @objc public func cancelRequest(_ identifier: String) {
        preparedSessions.removeValue(forKey: identifier)
        activeTasks.removeValue(forKey: identifier)?.cancel()
    }

    /// Summarize `text` using `instructions` as the system prompt. `onPartial`
    /// fires repeatedly with the cumulative text as it streams; `onComplete`
    /// fires once with the final text (or an error). Both callbacks are invoked
    /// on the main thread, so the ObjC side can touch UIKit directly.
    @objc public func summarize(_ text: String,
                                identifier: String,
                                instructions: String,
                                maximumResponseTokens: Int,
                                onPartial: @escaping (String) -> Void,
                                onComplete: @escaping (String?, NSError?) -> Void) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            onComplete(nil, Self.makeError(code: 4, message: "Requires iOS 26 or later"))
            return
        }

        // NOTE: we intentionally do NOT pre-gate on `availabilityStatus() == 0`.
        // On iOS 27, `SystemLanguageModel.default.availability` reports
        // `.appleIntelligenceNotEnabled` to sideloaded apps even when the model
        // works (other clients like Hydra summarize fine on the same device).
        // So we just attempt generation and let an actual thrown error from the
        // session be the only thing that stops us. `availabilityStatus()` remains
        // for diagnostics/UI only.

        // Run the async generation on the main actor: the framework does the
        // heavy work on its own executor and only resumes here to deliver
        // snapshots, so the callbacks land on the main thread for free.
        let task = Task { @MainActor in
            do {
                let startedAt = ContinuousClock.now
                let session: LanguageModelSession
                if let prepared = preparedSessions.removeValue(forKey: identifier) as? LanguageModelSession {
                    session = prepared
                } else {
                    session = LanguageModelSession(instructions: instructions)
                }
                let options = GenerationOptions(
                    samplingMode: .greedy,
                    maximumResponseTokens: maximumResponseTokens > 0 ? maximumResponseTokens : nil
                )
                var latest = ""
                var loggedFirstToken = false
                for try await snapshot in session.streamResponse(to: text, options: options) {
                    latest = snapshot.content
                    if !loggedFirstToken, !latest.isEmpty {
                        loggedFirstToken = true
                        let elapsed = ContinuousClock.now - startedAt
                        NSLog("[ApolloReborn][AISummary] first text %@ after %@",
                              identifier, String(describing: elapsed))
                    }
                    onPartial(latest)
                }
                NSLog("[ApolloReborn][AISummary] completed %@ after %@",
                      identifier, String(describing: ContinuousClock.now - startedAt))
                if #available(iOS 27.0, *) {
                    let usage = session.usage
                    NSLog("[ApolloReborn][AISummary] tokens input=%ld cached=%ld output=%ld reasoning=%ld",
                          usage.input.totalTokenCount,
                          usage.input.cachedTokenCount,
                          usage.output.totalTokenCount,
                          usage.output.reasoningTokenCount)
                }
                onComplete(latest, nil)
            } catch {
                preparedSessions.removeValue(forKey: identifier)
                if Task.isCancelled {
                    onComplete(nil, Self.makeError(code: 6, message: "Generation cancelled"))
                } else {
                    onComplete(nil, error as NSError)
                }
            }
            activeTasks.removeValue(forKey: identifier)
        }
        activeTasks[identifier]?.cancel()
        activeTasks[identifier] = task
        #else
        onComplete(nil, Self.makeError(code: 4, message: "FoundationModels not available in this build"))
        #endif
    }

    private static func makeError(code: Int, message: String) -> NSError {
        return NSError(domain: "ApolloFoundationModels",
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}
