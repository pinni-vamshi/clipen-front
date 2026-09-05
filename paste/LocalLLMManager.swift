import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

nonisolated enum LocalModelTier: String, CaseIterable, Identifiable, Codable {
    case threeB = "qwen2_5_3b"
    case sevenB = "qwen2_5_7b"
    case nineB = "gemma2_9b"

    var id: String { rawValue }

    var hubID: String {
        switch self {
        case .threeB: "mlx-community/Qwen2.5-3B-Instruct-4bit"
        case .sevenB: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        case .nineB:  "mlx-community/gemma-2-9b-it-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .threeB: "Qwen2.5 3B (on-device)"
        case .sevenB: "Qwen2.5 7B (on-device)"
        case .nineB:  "Gemma 2 9B (on-device)"
        }
    }

    var totalBytes: Int64 {
        switch self {
        case .threeB: 1_750_000_000
        case .sevenB: 4_300_000_000
        case .nineB:  5_220_000_000
        }
    }

    var approxSizeText: String {
        switch self {
        case .threeB: "~1.8 GB · fastest"
        case .sevenB: "~4.3 GB · balanced"
        case .nineB:  "~5.2 GB · highest quality"
        }
    }
}

nonisolated enum LocalModelPaths {
    static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func directory(for tier: LocalModelTier) -> URL {
        ModelConfiguration(id: tier.hubID).modelDirectory(hub: HubApi(downloadBase: modelsDirectory))
    }

    static func isDownloaded(_ tier: LocalModelTier) -> Bool {
        let dir = directory(for: tier)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              files.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        return bytesOnDisk(for: tier) >= Int64(Double(tier.totalBytes) * 0.9)
    }

    static func hasAnyLocalFiles(_ tier: LocalModelTier) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: tier).path)
    }

    static func bytesOnDisk(for tier: LocalModelTier) -> Int64 {
        let dir = directory(for: tier)
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

actor InferenceGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var peakConcurrent = 0
    private var current = 0

    private func acquire() async {
        if !busy {
            busy = true
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        current += 1
        peakConcurrent = max(peakConcurrent, current)
    }

    private func release() {
        current -= 1
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    var waitingCount: Int { waiters.count }

    func withExclusiveAccess<R>(_ body: @Sendable () async throws -> R) async rethrows -> R {
        await acquire()
        defer { release() }
        return try await body()
    }
}

enum LocalModelError: LocalizedError {
    case downloadStalled

    var errorDescription: String? {
        switch self {
        case .downloadStalled:
            return "The model download stalled and was aborted. Check your connection, then try again — partial files are cleared automatically."
        }
    }
}

private actor StallTracker {
    private var lastFraction: Double = -1
    private var lastAdvance = Date()

    func note(_ fraction: Double) {
        guard fraction != lastFraction else { return }
        lastFraction = fraction
        lastAdvance = Date()
    }

    func isStalled(for seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastAdvance) > seconds
    }
}

actor LocalModelRuntime {
    static let shared = LocalModelRuntime()

    private enum ContainerState {
        case loading(Task<ModelContainer, Error>)
        case ready(ModelContainer)
    }

    private var containers: [LocalModelTier: ContainerState] = [:]
    private let hub = HubApi(downloadBase: LocalModelPaths.modelsDirectory)

    func unload(_ tier: LocalModelTier) {
        containers[tier] = nil
    }

    func cancelLoad(_ tier: LocalModelTier) {
        if case .loading(let task) = containers[tier] {
            task.cancel()
            DebugLog.write("MODEL: \(tier.displayName) — cancelled by user")
        }
        containers[tier] = nil
    }

    func container(
        for tier: LocalModelTier,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelContainer {
        switch containers[tier] {
        case .ready(let container):
            return container
        case .loading(let task):
            return try await task.value
        case nil:
            DebugLog.write("MODEL: \(tier.displayName) — starting download/load (\(tier.hubID))")
            let hub = self.hub
            let configuration = ModelConfiguration(id: tier.hubID)
            let task = Task<ModelContainer, Error> {

                let lastProgress = StallTracker()
                return try await withThrowingTaskGroup(of: ModelContainer.self) { group in
                    group.addTask {
                        try await LLMModelFactory.shared.loadContainer(
                            hub: hub, configuration: configuration
                        ) { p in
                            DebugLog.write("MODEL: \(tier.displayName) — \(Int(p.fractionCompleted * 100))%")
                            Task { await lastProgress.note(p.fractionCompleted) }
                            progress?(p.fractionCompleted)
                        }
                    }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .seconds(30))
                            if await lastProgress.isStalled(for: 180) {
                                DebugLog.write("MODEL: \(tier.displayName) — download stalled, aborting")
                                throw LocalModelError.downloadStalled
                            }
                        }
                    }
                    guard let container = try await group.next() else {
                        throw LocalModelError.downloadStalled
                    }
                    group.cancelAll()
                    return container
                }
            }
            containers[tier] = .loading(task)
            do {
                let container = try await task.value
                containers[tier] = .ready(container)
                DebugLog.write("MODEL: \(tier.displayName) — loaded successfully")
                return container
            } catch {
                DebugLog.write("MODEL: \(tier.displayName) — FAILED: \(error)")
                containers[tier] = nil
                throw error
            }
        }
    }

    func respondChat(
        tier: LocalModelTier,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        // No gate here: the only caller (AIStructuringService.structure)
        // already runs this whole call inside its own analysisGate
        // exclusive-access block, which alone limits inference concurrency
        // app-wide to 1. A second InferenceGate here could never actually
        // see concurrent access as long as that remains the only caller —
        // it was dead, misleading machinery, not a real second layer of
        // protection.
        let container = try await container(for: tier)
        let params = GenerateParameters(maxTokens: maxTokens)
        let session = ChatSession(container, instructions: instructions, generateParameters: params)
        return try await session.respond(to: prompt)
    }
}

enum AIEngineSelection: Equatable, Hashable {
    case apple
    case local(LocalModelTier)

    var storageValue: String {
        switch self {
        case .apple: "apple"
        case .local(let tier): tier.rawValue
        }
    }

    init(storageValue: String?) {
        if let storageValue, let tier = LocalModelTier(rawValue: storageValue) {
            self = .local(tier)
        } else {
            self = .apple
        }
    }
}

@MainActor
final class LocalLLMManager: ObservableObject {
    static let shared = LocalLLMManager()

    @Published private(set) var downloadedTiers: Set<LocalModelTier> = []
    @Published private(set) var downloadingTiers: Set<LocalModelTier> = []
    @Published private(set) var downloadProgress: [LocalModelTier: Double] = [:]

    @Published private(set) var downloadedBytes: [LocalModelTier: Int64] = [:]
    @Published private(set) var downloadSpeed: [LocalModelTier: Double] = [:]
    @Published private(set) var lastError: String?

    private var pollTimers: [LocalModelTier: Task<Void, Never>] = [:]

    private func startBytePolling(_ tier: LocalModelTier) {
        pollTimers[tier]?.cancel()
        pollTimers[tier] = Task { [weak self] in
            var lastBytes: Int64 = 0
            var lastAt = Date()
            while !Task.isCancelled {
                let bytes = LocalModelPaths.bytesOnDisk(for: tier)
                let now = Date()
                let dt = now.timeIntervalSince(lastAt)
                if dt > 0, bytes >= lastBytes {
                    let speed = Double(bytes - lastBytes) / dt
                    await MainActor.run {
                        self?.downloadedBytes[tier] = bytes

                        let prev = self?.downloadSpeed[tier] ?? speed
                        self?.downloadSpeed[tier] = prev * 0.6 + speed * 0.4
                        self?.downloadProgress[tier] =
                            min(0.999, Double(bytes) / Double(tier.totalBytes))
                    }
                }
                lastBytes = bytes
                lastAt = now
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopBytePolling(_ tier: LocalModelTier) {
        pollTimers[tier]?.cancel()
        pollTimers[tier] = nil
        downloadedBytes[tier] = nil
        downloadSpeed[tier] = nil
    }

    @Published private(set) var selectedEngine: AIEngineSelection = .apple {
        didSet {
            UserDefaults.standard.set(selectedEngine.storageValue, forKey: Self.selectedEngineDefaultsKey)
        }
    }

    /// Whether Apple Intelligence can actually run here — unsupported Mac,
    /// switched off in System Settings, or an OS too old for it to exist all
    /// land as false.
    ///
    /// Cached: `availability` is the framework asking the system about model
    /// state, and this is read from view bodies. It is re-read by
    /// `refreshAppleAvailability()` rather than on every access, since the
    /// answer only changes when the user changes a System Setting.
    @Published private(set) var appleIntelligenceAvailable: Bool = true

    func refreshAppleAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let ok: Bool
            if case .available = SystemLanguageModel.default.availability { ok = true } else { ok = false }
            if appleIntelligenceAvailable != ok { appleIntelligenceAvailable = ok }
            return
        }
        #endif
        if appleIntelligenceAvailable { appleIntelligenceAvailable = false }
    }

    /// Is there anything at all that could run an analysis? False only when
    /// Apple Intelligence cannot run AND no local model is on disk — the one
    /// state where pressing D can never produce anything.
    var canRunAnalysis: Bool {
        appleIntelligenceAvailable || !downloadedTiers.isEmpty
    }

    var effectiveEngine: AIEngineSelection {
        if case .local(let tier) = selectedEngine, downloadedTiers.contains(tier) {
            return .local(tier)
        }
        return .apple
    }

    func selectEngine(_ engine: AIEngineSelection) {
        if case .local(let tier) = engine, !downloadedTiers.contains(tier) {
            if let busy = downloadingTiers.first(where: { $0 != tier }) {
                lastError = "\(busy.displayName) is still downloading — cancel it or wait before starting another."
                return
            }
            selectedEngine = engine
            // Already reserved (e.g. the launch-time auto-resume above got
            // there first for this exact tier) — nothing more to start.
            guard !downloadingTiers.contains(tier) else { return }
            // Reserve synchronously, before spawning the Task — see the
            // comment at the other call site above for why this can't be
            // deferred into download() itself.
            downloadingTiers.insert(tier)
            downloadProgress[tier] = 0
            Task { await download(tier, alreadyReserved: true) }
        } else {
            selectedEngine = engine
        }
    }

    private static let selectedEngineDefaultsKey = "LocalLLMManager.selectedEngine"
    static var modelsDirectory: URL { LocalModelPaths.modelsDirectory }

    private init() {
        selectedEngine = AIEngineSelection(storageValue: UserDefaults.standard.string(forKey: Self.selectedEngineDefaultsKey))
        rescanDownloadedTiers()
        refreshAppleAvailability()

        // A download in progress when the app was last killed (crash,
        // force-quit, macOS restart) leaves exactly this: `selectedEngine`
        // still points at that tier (persisted to UserDefaults), but
        // nothing is downloading and the on-disk scan above didn't find a
        // complete download either — `download(_:)` was never given the
        // chance to reach either of its own two outcomes (finish, or reset
        // `selectedEngine` back to `.apple` on failure). Left alone, the
        // user would be silently stuck on a model that looks selected but
        // will never actually run. Resuming automatically here is the
        // "start it back up on its own" half of that; the AI ANALYSIS
        // card's own download-state message is the fallback for whatever
        // this can't cover (e.g. no network at this exact moment).
        if case .local(let tier) = selectedEngine, !downloadedTiers.contains(tier) {
            DebugLog.write("MODEL: \(tier.displayName) selected but not downloaded at launch — resuming")
            // Reserve synchronously, here, before spawning the Task — not
            // inside download() itself. download()'s own guard-then-insert
            // only ever protected against the SAME tier being downloaded
            // twice; it couldn't stop a different tier's selectEngine() call
            // from also passing its "is anything else downloading" check in
            // the window between this Task being scheduled and it actually
            // starting to run, since that check read `downloadingTiers`
            // before this Task's body had reached the line that reserves it.
            downloadingTiers.insert(tier)
            downloadProgress[tier] = 0
            Task { await download(tier, alreadyReserved: true) }
        }
    }

    private func rescanDownloadedTiers() {
        downloadedTiers = Set(LocalModelTier.allCases.filter { LocalModelPaths.isDownloaded($0) })
    }

    func download(_ tier: LocalModelTier, alreadyReserved: Bool = false) async {
        if !alreadyReserved {
            guard !downloadingTiers.contains(tier) else { return }
            downloadingTiers.insert(tier)
            downloadProgress[tier] = 0
        }
        lastError = nil

        startBytePolling(tier)

        do {
            _ = try await LocalModelRuntime.shared.container(for: tier)
            downloadedTiers.insert(tier)
        } catch is CancellationError {

        } catch {

            if !LocalModelPaths.isDownloaded(tier) {
                DebugLog.write("MODEL: \(tier.displayName) — incomplete download detected, clearing for a clean retry (\(error))")
                try? FileManager.default.removeItem(at: LocalModelPaths.directory(for: tier))
                lastError = "\(tier.displayName) didn't fully download (a file failed partway through) — cleared it, please try again."
            } else {
                lastError = "Failed to load \(tier.displayName): \(error.localizedDescription)"
            }
            if selectedEngine == .local(tier) { selectedEngine = .apple }
        }

        stopBytePolling(tier)
        downloadingTiers.remove(tier)
        downloadProgress[tier] = nil
    }

    func cancelDownload(_ tier: LocalModelTier) {
        stopBytePolling(tier)
        Task {
            await LocalModelRuntime.shared.cancelLoad(tier)
            try? FileManager.default.removeItem(at: LocalModelPaths.directory(for: tier))
        }
        downloadingTiers.remove(tier)
        downloadProgress[tier] = nil
        lastError = nil
        if selectedEngine == .local(tier) { selectedEngine = .apple }
    }

    func delete(_ tier: LocalModelTier) {
        let dir = LocalModelPaths.directory(for: tier)
        try? FileManager.default.removeItem(at: dir)
        downloadedTiers.remove(tier)
        if selectedEngine == .local(tier) { selectedEngine = .apple }
        Task { await LocalModelRuntime.shared.unload(tier) }
    }
}
