// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Watches a project folder as a file presenter (PLAN.md §3 WorkspaceKit), so:
/// - when another app or the Files app is about to read, copy or move the project folder, we save first
///   (coordination asks only the presenters of the item being accessed, so a single file read by another
///   app doesn't ask; the editor's 3 s autosave covers that);
/// - when something outside Omnie-dev changes, adds or removes a file, we hear about it once,
///   debounced, with the paths that changed.
///
/// Only coordinated access is reported, which covers Files, document providers and well-behaved
/// apps. Writes that skip coordination (libgit2, a shell) are handled by their callers.
/// Pass the watcher as `presenter` to `TextFile.save` so our own saves don't echo back.
public final class ProjectWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "ai.wckd.omniedev.watcher"
        return q
    }()

    /// Called on the main queue with the changed URLs, after `debounce` of quiet.
    public var onChange: (@Sendable (Set<URL>) -> Void)?
    /// Called (and waited for) when another process wants the files on disk to be current.
    public var onSaveRequest: (@Sendable () -> Void)?

    private let debounce: TimeInterval
    private var pending: Set<URL> = []
    private var flush: DispatchWorkItem?
    private let lock = NSLock()

    public init(root: URL, debounce: TimeInterval = 0.3) {
        presentedItemURL = root
        self.debounce = debounce
        super.init()
    }

    public func start() { NSFileCoordinator.addFilePresenter(self) }
    public func stop() { NSFileCoordinator.removeFilePresenter(self) }

    // MARK: NSFilePresenter

    public func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        if let onSaveRequest { DispatchQueue.main.sync { onSaveRequest() } }
        completionHandler(nil)
    }

    public func presentedSubitemDidChange(at url: URL) { note(url) }
    public func presentedSubitemDidAppear(at url: URL) { note(url) }
    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { note(oldURL); note(newURL) }
    public func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        note(url)
        completionHandler(nil)
    }
    public func presentedItemDidChange() { presentedItemURL.map(note) }

    private func note(_ url: URL) {
        // Atomic saves write a sibling temp file ("a.txt.sb-4d091091-aXxzuE") and rename it over the original.
        if Self.isSafeSaveTemp(url.lastPathComponent) { return }
        lock.lock()
        pending.insert(url.standardizedFileURL)
        flush?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.lock()
            let urls = pending
            pending = []
            lock.unlock()
            if !urls.isEmpty { onChange?(urls) }
        }
        flush = item
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    static func isSafeSaveTemp(_ name: String) -> Bool {
        name.wholeMatch(of: /.+\.sb-[0-9a-f]{8}-[A-Za-z0-9]{6}/) != nil
    }
}
