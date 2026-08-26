import Combine
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The on-device model tiers offered in Settings.
///
/// Raw values are deliberately model-identifiers rather than "small" /
/// "medium" / "large". The tiers were renumbered once already — what used to
/// be `medium` (Qwen2.5 3B) is now `low`, and the old `large` (7B) is now
/// `medium` — so position-based raw values would silently move an existing
/// user onto a different model than the one they chose, and in the case of
/// the new `large` onto one they have not downloaded. Naming the weights
/// makes the stored value mean the same thing forever; see
/// `AIEngineSelection.init(storageValue:)` for the migration off the old
/// names.
enum LocalModelTier: String, CaseIterable, Identifiable, Codable {
    case low = "qwen2_5_3b"
    case medium = "qwen2_5_7b"
    case large = "qwen3_5_9b"

    var id: String { rawValue }

    var hubID: String {
        switch self {
        case .low: "mlx-community/Qwen2.5-3B-Instruct-4bit"
        case .medium: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        case .large: "mlx-community/Qwen3.5-9B-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .low: "Low — Qwen2.5 3B"
        case .medium: "Medium — Qwen2.5 7B"
        case .large: "Large — Qwen3.5 9B"
        }
    }

    var approxSizeText: String {
        switch self {
        case .low: "~1.9 GB · fastest"
        case .medium: "~4.3 GB · balanced"
        case .large: "~6.0 GB · highest quality"
        }
    }
}

/// Filesystem location for downloaded weights. Deliberately outside the
/// @MainActor class below so both the UI layer and the off-main inference
/// actor can read it without hopping actors just to build a path.
enum LocalModelPaths {
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
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return files.contains { $0.hasSuffix(".safetensors") }
    }
}

/// Strict mutual exclusion for async work.
///
/// An actor **cannot** provide this, and assuming otherwise is what crashed
/// the app twice. Actors release isolation at every `await`, so a suspension
/// inside a critical section lets the next task walk straight in.
/// `ModelContainer.perform` is literally `try await action(context)` — it
/// isolates the stored property, it is not a lock — and MLX's generate
/// closure suspends on `processor.prepare` before touching the GPU. Eleven
/// tasks therefore reached Metal at once and corrupted the command encoder.
///
/// This gate holds across suspensions: a second caller waits on a
/// continuation until the first actually finishes.
actor InferenceGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Peak simultaneous holders. Must never exceed 1; surfaced in the log so
    /// the guarantee is checkable from outside rather than taken on trust.
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

/// Owns the loaded MLX model containers and every inference call.
///
/// Deliberately a separate actor from `LocalLLMManager` (which is
/// @MainActor because it publishes UI state): loading a multi-gigabyte
/// model and running token generation must never occupy the main thread,
/// which is also the thread the event tap and all AX reads depend on.
actor LocalModelRuntime {
    static let shared = LocalModelRuntime()

    /// Every local generation goes through this. Nothing else may call MLX.
    static let gate = InferenceGate()

    /// Waits for any in-flight generation to finish, up to `timeoutSeconds`.
    ///
    /// Quitting the app while a generation is running is a real crash, not a
    /// hypothetical one: `-[NSApplication terminate:]` calls `exit()`, whose
    /// static-destructor sequence tears down MLX's global scheduler and
    /// compiler cache on the main thread — while a background thread can
    /// still be mid-access of those same globals inside a running
    /// `TokenIterator`. Observed live: a SIGSEGV in
    /// `mlx::core::detail::CompilerCache::find`, `far: 0x0`, one second
    /// after quit was triggered.
    ///
    /// Call this from `applicationShouldTerminate` before allowing the app
    /// to actually exit. Acquiring-then-immediately-releasing the gate
    /// resolves instantly when nothing is running (the common case) and
    /// waits for the current holder otherwise; the timeout is a last-resort
    /// bound in case a generation is unexpectedly stuck, so quitting is
    /// never blocked forever.
    static func waitUntilIdle(timeoutSeconds: Double) async {
        // NOT `withTaskGroup` — a structured group blocks its closing brace
        // until every child actually finishes, even after `cancelAll()`.
        // Cancellation is cooperative, and a task parked on
        // `withCheckedContinuation` inside the gate's `acquire()` never
        // checks it, so a truly stuck generation would keep the group open
        // for as long as that generation runs — unbounded, exactly what the
        // timeout exists to prevent. Verified with a test before fixing:
        // 0.5s timeout against a "stuck" 10s holder measured 10.48s, not
        // ~0.5s. Two independent unstructured tasks racing to resume one
        // continuation avoids the implicit join.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeGuard()
            Task {
                await gate.withExclusiveAccess {}
                if resumed.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if resumed.claim() { continuation.resume() }
            }
        }
    }

    /// A `CheckedContinuation` may only be resumed once; two unstructured
    /// tasks can race to do it, so the actual resume is gated behind this.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        /// Returns true for exactly one caller, across any number of racing
        /// callers — false for every caller after that.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }

    /// `.loading` holds the in-flight load itself, not just the finished
    /// result — see `container(for:progress:)` for why that distinction is
    /// load-bearing.
    private enum ContainerState {
        case loading(Task<ModelContainer, Error>)
        case ready(ModelContainer)
    }

    private var containers: [LocalModelTier: ContainerState] = [:]
    private let hub = HubApi(downloadBase: LocalModelPaths.modelsDirectory)

    func unload(_ tier: LocalModelTier) {
        containers[tier] = nil
    }

    /// Returns the one shared container for a tier, loading it at most once.
    ///
    /// Being inside an actor is NOT enough to make a cache like this safe.
    /// Actors are reentrant: the `await` on the load is a suspension point,
    /// so with a naive `if cached { return } / await load / cache = result`
    /// every concurrent caller arrives, sees an empty cache, and starts its
    /// own load. That produced *ten separate ModelContainers* in a crash
    /// report — ten independent actors, so none of them serialized against
    /// the others, and ten concurrent Metal command-encoder creations on one
    /// device corrupted memory (SIGSEGV inside
    /// AGXG16GFamilyCommandBuffer). Ten copies of a multi-gigabyte model
    /// were also resident at once.
    ///
    /// Recording the *Task* before the first suspension closes the window:
    /// latecomers find `.loading` and await the same work.
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
            let hub = self.hub
            let configuration = ModelConfiguration(id: tier.hubID)
            let task = Task<ModelContainer, Error> {
                try await LLMModelFactory.shared.loadContainer(
                    hub: hub, configuration: configuration
                ) { p in
                    progress?(p.fractionCompleted)
                }
            }
            containers[tier] = .loading(task)
            do {
                let container = try await task.value
                containers[tier] = .ready(container)
                DebugLog.write("MODEL: \(tier.displayName) loaded")
                return container
            } catch {
                // Clear the failed entry so a later attempt can retry rather
                // than awaiting a task that will never succeed. Logged here,
                // at the source, rather than trusting every caller's own
                // catch block to — several of them don't, which is how a
                // load failure could vanish without a trace.
                DebugLog.write("MODEL: \(tier.displayName) load FAILED — \(error)")
                containers[tier] = nil
                throw error
            }
        }
    }

    /// Instruction-following generation (translate, summarize, …) — a real
    /// request being answered, routed through the chat template.
    ///
    /// Routed through the same gate as everything else. `ChatSession` runs
    /// generation in an unstructured `Task {}` that ignores cancellation, so
    /// nothing stops concurrent calls from piling up on their own; the gate
    /// bounds them to one at a time even though they still cannot be
    /// cancelled.
    func respondChat(
        tier: LocalModelTier,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        let container = try await container(for: tier)
        let queued = await Self.gate.waitingCount
        if queued > 0 { DebugLog.write("GATE(chat): \(queued) generation(s) queued ahead") }
        return try await Self.gate.withExclusiveAccess {
            let peak = await Self.gate.peakConcurrent
            DebugLog.write("GATE(chat): entered (peak concurrent so far=\(peak))")
            defer { DebugLog.write("GATE(chat): released") }
            let params = GenerateParameters(maxTokens: maxTokens)
            let session = ChatSession(container, instructions: instructions, generateParameters: params)
            return try await session.respond(to: prompt)
        }
    }
}

/// The one AI engine choice that governs every AI feature — a single
/// selection, not a per-feature setting, since a user picking "my
/// downloaded model" expects that to mean the whole app, not just one
/// feature. `.local` is a stated preference, not a guarantee it's what's
/// actually used — see `effectiveEngine`, which is what callers should
/// check before running inference.
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
        guard let storageValue else { self = .apple; return }
        if let tier = LocalModelTier(rawValue: storageValue) {
            self = .local(tier)
            return
        }
        // Migration off the pre-renumbering names. Mapped by WEIGHTS, not by
        // position, so a user keeps running the model they actually chose:
        // the old medium and the new low are both Qwen2.5 3B, and the old
        // large and the new medium are both 7B. The retired 1.5B tier has no
        // equivalent, so those users land on the smallest surviving model
        // rather than being pushed onto a multi-gigabyte download.
        switch storageValue {
        case "small":  self = .local(.low)
        case "medium": self = .local(.low)
        case "large":  self = .local(.medium)
        default:       self = .apple
        }
    }
}

@MainActor
final class LocalLLMManager: ObservableObject {
    static let shared = LocalLLMManager()

    @Published private(set) var downloadedTiers: Set<LocalModelTier> = []
    @Published private(set) var downloadingTiers: Set<LocalModelTier> = []
    @Published private(set) var downloadProgress: [LocalModelTier: Double] = [:]
    @Published private(set) var lastError: String?

    /// The user's stated choice — may name a tier that isn't downloaded yet
    /// (selecting one starts its download; see `selectEngine`). Read
    /// `effectiveEngine` for what to actually run inference with.
    @Published private(set) var selectedEngine: AIEngineSelection = .apple {
        didSet {
            UserDefaults.standard.set(selectedEngine.storageValue, forKey: Self.selectedEngineDefaultsKey)
        }
    }

    /// What every AI call should actually use right now: the selected local
    /// tier only if it's genuinely downloaded and ready, Apple Intelligence
    /// otherwise. Kept separate from `selectedEngine` so the UI can show
    /// "downloading Medium…" as the user's intent while inference safely
    /// keeps using Apple until that download actually finishes.
    var effectiveEngine: AIEngineSelection {
        if case .local(let tier) = selectedEngine, downloadedTiers.contains(tier) {
            return .local(tier)
        }
        return .apple
    }

    /// Sets the user's engine choice. Picking a tier that isn't downloaded
    /// yet starts the download immediately — `effectiveEngine` keeps
    /// returning `.apple` until it actually completes, so no feature
    /// silently goes idle waiting on a multi-GB download.
    func selectEngine(_ engine: AIEngineSelection) {
        let label: String = {
            switch engine {
            case .apple: return "Apple Intelligence"
            case .local(let tier): return tier.displayName
            }
        }()
        DebugLog.write("ENGINE: user selected \(label)")
        selectedEngine = engine
        if case .local(let tier) = engine, !downloadedTiers.contains(tier) {
            DebugLog.write("ENGINE: \(label) not downloaded — starting download, using Apple Intelligence until ready")
            Task { await download(tier) }
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

        do {
            _ = try await LocalModelRuntime.shared.container(for: tier) { [weak self] fraction in
                Task { @MainActor in self?.downloadProgress[tier] = fraction }
            }
            downloadedTiers.insert(tier)
        } catch {
            lastError = "Failed to download \(tier.displayName): \(error.localizedDescription)"
            if selectedEngine == .local(tier) { selectedEngine = .apple }
        }

        downloadingTiers.remove(tier)
        downloadProgress[tier] = nil
    }

    func delete(_ tier: LocalModelTier) {
        let dir = LocalModelPaths.directory(for: tier)
        try? FileManager.default.removeItem(at: dir)
        downloadedTiers.remove(tier)
        if selectedEngine == .local(tier) { selectedEngine = .apple }
        Task { await LocalModelRuntime.shared.unload(tier) }
    }
}
