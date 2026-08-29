import Combine
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The on-device models this build offers as an alternative to Apple
/// Intelligence, 4-bit quantized for a reasonable download size.
///
/// Both are confirmed genuine text-only LLMs (`pipeline_tag:
/// text-generation`) — this matters because `LLMModelFactory` (the loader
/// used below) is the text-only path, not the vision-language one. An
/// earlier "9B" choice here (Qwen3.5-9B-4bit) turned out to actually be a
/// vision-language model (`image-text-to-text`), which silently hung at
/// 0% forever under the text loader instead of failing loudly. Verify any
/// future addition's `pipeline_tag` on Hugging Face before adding it here.
// Plain data, no actor affinity — nonisolated so LocalModelRuntime (a real
// actor, isolated separately from the project's MainActor default) can
// read these without every call site needing `await`.
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

    /// Real totals, measured from each repo's file listing — used both for
    /// the pre-download label and as the denominator for byte-level
    /// progress, so the bar can't drift from what's actually on disk.
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

/// Filesystem location for downloaded weights — under Clipen's own
/// Application Support folder, never Clipen's. Deliberately outside the
/// @MainActor class below so both the UI layer and the off-main inference
/// actor can read it without hopping actors just to build a path.
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

    /// A `.safetensors` file existing is not proof it's actually complete —
    /// a download whose weights file silently failed to transfer (network
    /// drop treated as "nothing to do" rather than a raised error) can
    /// leave metadata-only or truncated files behind that look present on
    /// a shallow file-listing check. This checks real bytes against the
    /// tier's known total, with slack for filesystem/metadata overhead —
    /// exactly the gap that let a load be attempted against a missing
    /// weights file and fail with a confusing "Key ... not found" error
    /// instead of an honest "download incomplete."
    static func isDownloaded(_ tier: LocalModelTier) -> Bool {
        let dir = directory(for: tier)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              files.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        return bytesOnDisk(for: tier) >= Int64(Double(tier.totalBytes) * 0.9)
    }

    /// True for a partial/stuck/cancelled download too, not just a
    /// complete one — a `.cache/huggingface/download` scaffold with no
    /// `.safetensors` yet still counts as real leftover disk usage.
    static func hasAnyLocalFiles(_ tier: LocalModelTier) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: tier).path)
    }

    /// Total bytes actually written to disk for this tier so far, including
    /// in-flight `.incomplete` parts.
    ///
    /// This exists because HubApi's own progress is **file-count** based:
    /// `Progress(totalUnitCount: filenames.count)` with `pendingUnitCount: 1`
    /// per file, so a 4.3 GB weights file and a 300-byte config.json each
    /// get an identical slice of the bar. The result looked exactly like a
    /// frozen download — it sprinted to 50% across ten tiny files in ten
    /// seconds, then sat at "50%" for the entire multi-gigabyte transfer.
    /// Measuring the bytes that have actually landed is the only honest
    /// signal here.
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

/// Strict mutual exclusion for async work.
///
/// An actor **cannot** provide this on its own: actors release isolation at
/// every `await`, so a suspension inside a critical section lets the next
/// task walk straight in. `ModelContainer.perform` is literally
/// `try await action(context)` — it isolates the stored property, it is not
/// a lock — and MLX's generate closure suspends before touching the GPU.
/// Concurrent callers reaching Metal at once corrupts the command encoder.
/// This gate holds across suspensions: a second caller waits on a
/// continuation until the first actually finishes.
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

/// Owns the loaded MLX model container and every inference call.
///
/// Deliberately a separate actor from `LocalLLMManager` (which is
/// @MainActor because it publishes UI state): loading a multi-gigabyte
/// model and running token generation must never occupy the main thread.
enum LocalModelError: LocalizedError {
    case downloadStalled

    var errorDescription: String? {
        switch self {
        case .downloadStalled:
            return "The model download stalled and was aborted. Check your connection, then try again — partial files are cleared automatically."
        }
    }
}

/// Tracks when download progress last actually advanced, so a dead
/// download can be told apart from a merely slow one. Only a CHANGE in
/// fraction counts as liveness — a stalled download keeps reporting the
/// same value, which must not be mistaken for progress.
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
    static let gate = InferenceGate()

    private enum ContainerState {
        case loading(Task<ModelContainer, Error>)
        case ready(ModelContainer)
    }

    private var containers: [LocalModelTier: ContainerState] = [:]
    private let hub = HubApi(downloadBase: LocalModelPaths.modelsDirectory)

    func unload(_ tier: LocalModelTier) {
        containers[tier] = nil
    }

    /// Actually stops an in-flight download/load — cooperative
    /// cancellation, not just forgetting about it. Without this, picking a
    /// different engine (or even quitting to the picker) left the
    /// background download task running invisibly, which is exactly how
    /// two multi-gigabyte downloads ended up racing each other for
    /// bandwidth and both stalling.
    func cancelLoad(_ tier: LocalModelTier) {
        if case .loading(let task) = containers[tier] {
            task.cancel()
            DebugLog.write("MODEL: \(tier.displayName) — cancelled by user")
        }
        containers[tier] = nil
    }

    /// Returns the one shared container for a tier, loading it at most once.
    /// Being inside an actor is not enough on its own — actors are
    /// reentrant, so recording the *Task* before the first suspension (not
    /// just the eventual result) is what stops concurrent callers from each
    /// starting their own independent multi-gigabyte load.
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
                // Stall guard. A download that dies mid-flight does not
                // error — it simply stops advancing, reporting the same
                // percentage forever. Because analysis is serialized behind
                // one gate, that silently blocks EVERY item indefinitely
                // (seen for real: a 7B stuck at 39% with 840MB of 4.3GB on
                // disk, every text and image item hanging behind it with no
                // output at all). Progress arriving is the liveness signal;
                // if none arrives for this long, the download is dead, not
                // slow, so fail loudly instead of hanging forever.
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

    /// Instruction-following generation, routed through the chat template.
    /// Routed through the same gate as everything else — `ChatSession` runs
    /// generation in an unstructured `Task {}` that ignores cancellation,
    /// so nothing else stops concurrent calls from piling onto the GPU at
    /// once; the gate bounds them to one at a time.
    func respondChat(
        tier: LocalModelTier,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        let container = try await container(for: tier)
        return try await Self.gate.withExclusiveAccess {
            let params = GenerateParameters(maxTokens: maxTokens)
            let session = ChatSession(container, instructions: instructions, generateParameters: params)
            return try await session.respond(to: prompt)
        }
    }
}

/// The AI engine choice — Apple Intelligence or the downloaded local model.
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
    /// Real bytes on disk + observed speed, polled during a download — the
    /// honest signal the file-count `downloadProgress` can't give. See
    /// `LocalModelPaths.bytesOnDisk`.
    @Published private(set) var downloadedBytes: [LocalModelTier: Int64] = [:]
    @Published private(set) var downloadSpeed: [LocalModelTier: Double] = [:]
    @Published private(set) var lastError: String?

    private var pollTimers: [LocalModelTier: Task<Void, Never>] = [:]

    /// Polls actual disk usage once a second for the duration of a
    /// download, deriving both the fraction and a smoothed speed. Stopped
    /// by `stopBytePolling` on completion, failure, or cancellation.
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
                        // Blend, so a momentarily idle poll doesn't read as a hard stop.
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

    /// The user's stated choice — may name a tier that isn't downloaded yet
    /// (selecting it starts the download; see `selectEngine`). Read
    /// `effectiveEngine` for what to actually run inference with.
    @Published private(set) var selectedEngine: AIEngineSelection = .apple {
        didSet {
            UserDefaults.standard.set(selectedEngine.storageValue, forKey: Self.selectedEngineDefaultsKey)
        }
    }

    /// What every AI call should actually use right now: the selected local
    /// tier only if it's genuinely downloaded and ready, Apple Intelligence
    /// otherwise — so the UI can show "downloading…" as the user's intent
    /// while inference safely keeps using Apple until that finishes.
    var effectiveEngine: AIEngineSelection {
        if case .local(let tier) = selectedEngine, downloadedTiers.contains(tier) {
            return .local(tier)
        }
        return .apple
    }

    /// Refuses to start a second concurrent download rather than letting
    /// two multi-gigabyte downloads race each other for bandwidth — that's
    /// exactly what stalled both of them the first time this shipped.
    /// Switching to Apple Intelligence, or to a tier that's already
    /// downloaded, always works regardless — only starting a *new*
    /// download while another is in flight is blocked.
    func selectEngine(_ engine: AIEngineSelection) {
        if case .local(let tier) = engine, !downloadedTiers.contains(tier) {
            if let busy = downloadingTiers.first(where: { $0 != tier }) {
                lastError = "\(busy.displayName) is still downloading — cancel it or wait before starting another."
                return
            }
            selectedEngine = engine
            Task { await download(tier) }
        } else {
            selectedEngine = engine
        }
    }

    private static let selectedEngineDefaultsKey = "LocalLLMManager.selectedEngine"
    static var modelsDirectory: URL { LocalModelPaths.modelsDirectory }

    private init() {
        selectedEngine = AIEngineSelection(storageValue: UserDefaults.standard.string(forKey: Self.selectedEngineDefaultsKey))
        rescanDownloadedTiers()
    }

    private func rescanDownloadedTiers() {
        downloadedTiers = Set(LocalModelTier.allCases.filter { LocalModelPaths.isDownloaded($0) })
    }

    func download(_ tier: LocalModelTier) async {
        guard !downloadingTiers.contains(tier) else { return }
        downloadingTiers.insert(tier)
        downloadProgress[tier] = 0
        lastError = nil

        // Byte polling drives the visible progress; HubApi's own
        // file-count fraction is deliberately ignored for display.
        startBytePolling(tier)

        do {
            _ = try await LocalModelRuntime.shared.container(for: tier)
            downloadedTiers.insert(tier)
        } catch is CancellationError {
            // User-initiated via cancelDownload(_:) — that already cleaned
            // up state, this is not a failure worth showing as an error.
        } catch {
            // A load failure right after a "successful" download usually
            // means a file silently failed to transfer — some individual
            // file's download errored in a way HubApi didn't propagate as
            // a hard failure, so it moved on and later crashed trying to
            // load weights that were never actually written. Confirmed via
            // isDownloaded's real byte-completeness check, not a file's
            // mere presence. Surface that plainly instead of MLX's raw
            // "Key ... not found" error, and clear the broken directory so
            // a retry starts genuinely clean rather than resuming into the
            // same hole.
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

    /// Stops a download in progress AND removes whatever partial bytes it
    /// already wrote — a plain cancel that leaves a half-downloaded
    /// `.cache/huggingface/download` scaffold behind isn't actually clean,
    /// it just hides the mess until the next `isDownloaded` check.
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

    /// Works for a complete download or leftover partial files alike — the
    /// UI shows this whenever `LocalModelPaths.hasAnyLocalFiles` is true,
    /// not only once `downloadedTiers` says the download finished.
    func delete(_ tier: LocalModelTier) {
        let dir = LocalModelPaths.directory(for: tier)
        try? FileManager.default.removeItem(at: dir)
        downloadedTiers.remove(tier)
        if selectedEngine == .local(tier) { selectedEngine = .apple }
        Task { await LocalModelRuntime.shared.unload(tier) }
    }
}
