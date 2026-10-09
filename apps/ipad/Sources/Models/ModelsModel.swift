// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ModelKit
import PolicyKit
import UIKit
import os

/// Downloads model files with URLSession, reporting progress while the transfer runs.
struct URLSessionFetcher: ModelFetcher {
    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let observer = ProgressRelay(progress)
        let (temp, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: observer)
        observer.stop()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// Polls the task's byte count; URLSession's async download has no progress callback of its own.
    final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Int64) -> Void
        private var timer: DispatchSourceTimer?
        init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak task, report] in
                if let task { report(task.countOfBytesReceived) }
            }
            timer.resume()
            self.timer = timer
        }

        func stop() { timer?.cancel() }
    }
}

/// The app's models: what's installed, downloads in progress, and the loaded Tiny model
/// (PLAN.md §7, §16: one large model resident, unload on memory warnings and in the background).
@MainActor
@Observable
final class ModelsModel {
    struct Download: Equatable {
        var done: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    let store = ModelStore(root: AppPaths.support.appendingPathComponent("Models", isDirectory: true), fetcher: URLSessionFetcher())
    @ObservationIgnored let policy: PolicyModel
    private(set) var states: [String: ModelStore.State] = [:]
    private(set) var downloads: [String: Download] = [:]
    var error: String?
    /// Ghost text from the Tiny model while you type. On by default once it's installed.
    var inlineSuggestions = UserDefaults.standard.object(forKey: "models.inlineSuggestions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inlineSuggestions, forKey: "models.inlineSuggestions") }
    }
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loaded: (pack: ModelPack, model: MLXTextModel)?
    @ObservationIgnored private var isLoading = false

    init(policy: PolicyModel) {
        self.policy = policy
        Task { await refresh() }
        let center = NotificationCenter.default
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.unload() }
            }
        }
    }

    func refresh() async {
        for pack in ModelPack.catalog { states[pack.id] = await store.state(of: pack) }
    }

    func isInstalled(_ pack: ModelPack) -> Bool { states[pack.id] == .installed }

    func install(_ pack: ModelPack) {
        guard tasks[pack.id] == nil else { return }
        tasks[pack.id] = Task {
            defer { tasks[pack.id] = nil; downloads[pack.id] = nil }
            guard await policy.authorize(.network(domain: ModelPack.host)) else {
                error = policy.lastRefusal ?? "Downloads aren't allowed right now."
                return
            }
            downloads[pack.id] = Download(done: 0, total: pack.totalBytes)
            do {
                try await store.install(pack, freeSpace: Self.freeSpace()) { done, total in
                    Task { @MainActor in self.downloads[pack.id] = Download(done: done, total: total) }
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                self.error = "\(pack.displayName): \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    func cancel(_ pack: ModelPack) {
        tasks[pack.id]?.cancel()
    }

    func remove(_ pack: ModelPack) {
        if loaded?.pack == pack { loaded = nil }
        Task {
            try? await store.remove(pack)
            await refresh()
        }
    }

    /// The Tiny model, loaded on first use if it's installed and fits in memory now. Paused (nil)
    /// while the 7B is loaded for an agent task: one large model resident at a time (PLAN.md §16).
    func tinyModel() async -> TextModel? {
        let pack = ModelPack.tiny
        if let loaded { return loaded.pack == pack ? loaded.model : nil }
        if states[pack.id] == nil { await refresh() }
        guard isInstalled(pack), !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }
        guard MemoryBudget.canLoad(pack, available: Int64(os_proc_available_memory())) else {
            error = "Not enough free memory to load \(pack.displayName) right now."
            return nil
        }
        do {
            let model = try await MLXTextModel.load(from: store.folder(for: pack))
            loaded = (pack, model)
            return model
        } catch {
            self.error = "Couldn't load \(pack.displayName): \(error.localizedDescription)"
            return nil
        }
    }

    /// The 7B for the agent. Loading it drops Tiny first.
    func standardModel() async -> TextModel? {
        let pack = ModelPack.standard
        if let loaded, loaded.pack == pack { return loaded.model }
        if states[pack.id] == nil { await refresh() }
        guard isInstalled(pack), !isLoading else { return nil }
        loaded = nil
        isLoading = true
        defer { isLoading = false }
        guard MemoryBudget.canLoad(pack, available: Int64(os_proc_available_memory())) else {
            error = "Not enough free memory to load \(pack.displayName) right now. Close other apps and try again."
            return nil
        }
        do {
            let model = try await MLXTextModel.load(from: store.folder(for: pack))
            loaded = (pack, model)
            return model
        } catch {
            self.error = "Couldn't load \(pack.displayName): \(error.localizedDescription)"
            return nil
        }
    }

    func unload() { loaded = nil }

    static func freeSpace() -> Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
