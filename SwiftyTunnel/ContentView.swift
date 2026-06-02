//
//  ContentView.swift
//  SwiftEditSH
//
//  Created by Chris Rios on 5/31/26.
//

import SwiftUI        // SwiftUI views, modifiers, property wrappers
import SwiftData      // Used by the Preview's modelContainer (and available for future model storage)
import Citadel        // The SSH client library — provides SSHClient, SFTPClient, withPTY, etc.
import SwiftTerm      // The VT100 terminal emulator UIView (TerminalView) that we host

// MARK: - TerminalPaneView
//
// A SwiftUI bridge that hosts SwiftTerm's UIKit-based `TerminalView` so we can place
// a real terminal emulator inside our SwiftUI layout.
//
// `UIViewRepresentable` is the protocol SwiftUI provides to wrap any UIView for use as
// a SwiftUI view. SwiftUI calls `makeUIView` once to create the UIView, and
// `updateUIView` whenever SwiftUI's state changes (we don't need to do anything there).
struct TerminalPaneView: UIViewRepresentable {
    let ssh: SSHSession                  // shared SSH actor (passed in by parent)
    var onClose: () -> Void = {}         // called when the remote shell exits (e.g., `exit`)

    // SwiftUI calls this to make a "coordinator" — a long-lived helper object that
    // SwiftUI holds onto across re-renders. It's where we keep the stream Task and
    // implement SwiftTerm's delegate protocol.
    func makeCoordinator() -> Coordinator {
        Coordinator(ssh: ssh, onClose: onClose)
    }

    // Called once, the first time SwiftUI needs the UIView. We configure SwiftTerm here.
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)

        // Use a different font size depending on if iPhone is in use
        if UIDevice.current.userInterfaceIdiom == .phone {
            view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        } else {
            view.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        }

        // Disable the inherited UIScrollView zoom behavior — otherwise pinch-zoom can
        // corrupt SwiftTerm's rendering.
        view.bouncesZoom = false
        view.maximumZoomScale = 1
        view.minimumZoomScale = 1

        view.backgroundColor = .black
        view.isOpaque = true                                  // perf hint: no blending needed

        // Don't reserve safe-area padding inside the scroll view; we manage layout above.
        view.contentInsetAdjustmentBehavior = .never
        view.contentInset = .zero

        // SwiftTerm calls our coordinator on input/resize/etc.
        view.terminalDelegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    // Called by SwiftUI whenever the state changes. We have nothing dynamic at this level
    // — the coordinator listens for input and pushes output asynchronously.
    func updateUIView(_ uiView: TerminalView, context: Context) {}

    // Called when SwiftUI is removing the view from the hierarchy. We cancel the stream
    // task here to release the PTY cleanly.
    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // The Coordinator is the bridge between SwiftTerm's UIKit delegate API and our
    // Swift-concurrency SSH actor. It owns the background Task that pipes bytes back and
    // forth between the SSH PTY and the TerminalView.
    final class Coordinator: NSObject, TerminalViewDelegate {
        let ssh: SSHSession
        let onClose: () -> Void
        weak var view: TerminalView?              // weak: SwiftUI owns the view, not us
        private var streamTask: Task<Void, Never>?       // long-running PTY read loop
        private var pendingResizeTask: Task<Void, Never>?// debounced resize sender
        private var didStart = false              // ensures we only open the PTY once

        init(ssh: SSHSession, onClose: @escaping () -> Void) {
            self.ssh = ssh
            self.onClose = onClose
            super.init()
        }

        // Opens the remote PTY at the given dimensions and pipes its output into the
        // terminal view. Called once we know the real cell dimensions from the first
        // `sizeChanged` delegate call.
        private func startStream(cols: Int, rows: Int) {
            streamTask = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    // `openTerminal` returns an async stream of raw UTF-8 bytes from the
                    // remote PTY. We feed them into SwiftTerm in small chunks so the
                    // renderer doesn't get overwhelmed by one giant burst.
                    for await chunk in try await self.ssh.openTerminal(cols: cols, rows: rows) {
                        let chunkSize = 1024
                        var next = 0
                        while next < chunk.count {
                            let end = min(next + chunkSize, chunk.count)
                            let slice = ArraySlice(chunk[next..<end])
                            // SwiftTerm's `feed` must be called on the main thread.
                            DispatchQueue.main.async { [weak self] in
                                self?.view?.feed(byteArray: slice)
                            }
                            next = end
                        }
                    }
                } catch {
                    // Network failure or unexpected SSH error — show inside the terminal.
                    DispatchQueue.main.async { [weak self] in
                        let msg = "\r\n[error: \(String(reflecting: error))]\r\n"
                        self?.view?.feed(text: msg)
                    }
                }
                // Stream ended (user typed `exit`, connection dropped, or error).
                // Notify parent so it can hide the terminal pane.
                DispatchQueue.main.async { [weak self] in
                    self?.onClose()
                }
            }
        }

        // Cancel the read loop. Called from `dismantleUIView`.
        func stop() {
            streamTask?.cancel()
            streamTask = nil
        }

        // MARK: TerminalViewDelegate
        // These are callbacks SwiftTerm invokes when the user interacts with the terminal.

        // User typed something — forward the raw bytes (including escape sequences for
        // arrow keys, etc.) to the remote PTY.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { try? await ssh.sendBytes(bytes) }
        }

        // Fired when SwiftTerm's view bounds change and the cell grid is recomputed.
        // First call: open the PTY at the right size. Subsequent calls: debounced resize
        // notification to the remote (SIGWINCH) so we don't spam the server during drags.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            if !didStart {
                didStart = true
                startStream(cols: newCols, rows: newRows)
            } else {
                // Each new size cancels the previous pending task, so only the final
                // size (after ~120ms of quiet) is actually sent to the server.
                pendingResizeTask?.cancel()
                let ssh = ssh
                pendingResizeTask = Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    try? await ssh.resizeTerminal(cols: newCols, rows: newRows)
                }
            }
        }

        // Delegate methods we don't need — leave them as no-ops.
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func bell(source: TerminalView) {}
    }
}

// MARK: - FileView
//
// The text editor for a single remote file. Pushed onto HostView's NavigationStack when
// the user taps a file. Loads the file's contents via SFTP, lets the user edit them in
// a SwiftUI TextEditor, and saves back via SFTP.
struct FileView: View {
    let path: String                       // absolute path on the remote
    let ssh: SSHSession                    // shared SSH actor
    @Binding var showTerminal: Bool        // two-way: toolbar terminal button toggles this
    var bottomReserve: CGFloat = 0         // height the parent reserves so the persistent terminal doesn't cover content

    // Editor state. `text` is what's in the editor right now; `originalText` is what we
    // loaded from disk. Comparing the two tells us whether to enable Save.
    @State private var text: String = ""
    @State private var originalText: String = ""
    @State private var loadError: String?              // shown in place of the editor if loading fails
    @State private var saveError: String?              // shown in an alert; editor stays visible
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showSavedConfirmation = false   // controls the brief "Saved" toast

    // `@FocusState` lets us programmatically focus/unfocus a field (used to dismiss the
    // keyboard via the toolbar's "Done" button on the keyboard accessory bar).
    @FocusState private var editorFocused: Bool

    var body: some View {
        // `Group` is a transparent container — it lets us return one of multiple views
        // from an if/else without needing AnyView.
        Group {
            if isLoading {
                ProgressView()
            } else if let loadError {
                Text(loadError).foregroundStyle(.red).padding()
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()                  // don't autocorrect code
                    .textInputAutocapitalization(.never)       // don't capitalize sentence starts
                    .focused($editorFocused)
            }
        }
        // File name in the nav bar.
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        // Reserve space at the bottom so the persistent terminal pane doesn't cover the editor.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: bottomReserve)
        }
        .toolbar {
            // Right side: Save button (or progress spinner while saving).
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(text == originalText)        // disabled when no changes
                }
            }
            // Also right side: terminal toggle so the user can flip it on from here.
            ToolbarItem {
                Button {
                    showTerminal.toggle()
                } label: {
                    Label("Toggle Terminal", systemImage: "terminal")
                }
            }
        }
        // "Saved" toast that briefly appears at the top after a successful save.
        .overlay(alignment: .top) {
            if showSavedConfirmation {
                Text("Saved")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Load the file when the view appears.
        .task { await load() }
        // Save failures pop a system alert without replacing the editor.
        // The Binding(get:set:) bridges an Optional? into the Bool the alert needs.
        .alert(
            "Save failed",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            ),
            presenting: saveError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    // Reads the file over SFTP. `readForEditing` does size and binary checks first;
    // EditError values give a friendly message, anything else falls through to the raw error.
    private func load() async {
        isLoading = true
        defer { isLoading = false }       // `defer` runs when the function exits, success or throw
        do {
            let loaded = try await ssh.readForEditing(path)
            text = loaded
            originalText = loaded         // both equal → Save button is disabled
        } catch let error as EditError {
            loadError = error.errorDescription
        } catch {
            loadError = String(reflecting: error)
        }
    }

    // Writes the current text over SFTP, then shows the "Saved" toast for ~1.2s.
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await ssh.write(path, text)
            originalText = text           // now they match → Save disables itself again
            withAnimation { showSavedConfirmation = true }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { showSavedConfirmation = false }
        } catch {
            saveError = String(reflecting: error)   // triggers the alert
        }
    }
}

struct CreateNewContent : View {
    @Environment(\.dismiss) private var dismiss
    @State var currentDir: String
    @State private var fileOrDir: Bool = false
    
    var onSave: (String, Bool) -> Void

    init(_ path: String, onSave: @escaping (String, Bool) -> Void) {
        self.currentDir = path
        self.onSave = onSave
    }

    var body: some View {
        // Sheets get their own NavigationStack so the toolbar's Cancel/Save show in a nav bar.
        NavigationStack {
            // `Form` styles its contents as grouped table rows — the standard iOS form look.
            Form {
                TextField("Path", text: $currentDir)
                Toggle("Create Directory", isOn: $fileOrDir)
            }
            .toolbar {
                // Left side: Cancel — just dismisses without doing anything.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Right side: Save — calls the callback, then dismisses.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // id: 0 is a placeholder; the database assigns a real id on insert.
                        onSave(currentDir, fileOrDir)
                        dismiss()
                    }
                    // Disable Save until the required fields are non-empty.
                    .disabled(currentDir.isEmpty)
                }
            }
            .navigationTitle("Create New Content")
        }
    }
}

// MARK: - AddHostView
//
// A simple form sheet used to create a new saved host. Presented as a sheet from
// ContentView when the user taps the "+" button.
struct AddHostView: View {
    // `@Environment(\.dismiss)` pulls in a function we can call to dismiss the sheet
    // (alternative to a bound `isPresented` flag — works for both sheets and pushes).
    @Environment(\.dismiss) private var dismiss

    // Form field state — each TextField binds to one of these via `$name`, `$address`, etc.
    @State private var name = ""
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""

    // Caller-provided callback. We invoke it with the new Host when the user taps Save.
    var onSave: (Host) -> Void

    var body: some View {
        // Sheets get their own NavigationStack so the toolbar's Cancel/Save show in a nav bar.
        NavigationStack {
            // `Form` styles its contents as grouped table rows — the standard iOS form look.
            Form {
                TextField("Name", text: $name)
                TextField("Address", text: $address)
                    .textInputAutocapitalization(.never)   // hosts are lowercase
                    .autocorrectionDisabled()
                TextField("User", text: $user)
                    .textInputAutocapitalization(.never)
                // SecureField hides characters (•••) — used for passwords.
                SecureField("Password", text: $password)
            }
            .toolbar {
                // Left side: Cancel — just dismisses without doing anything.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Right side: Save — calls the callback, then dismisses.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // id: 0 is a placeholder; the database assigns a real id on insert.
                        onSave(Host(id: 0, name: name, address: address, user: user, password: password))
                        dismiss()
                    }
                    // Disable Save until the required fields are non-empty.
                    .disabled(name.isEmpty || address.isEmpty || user.isEmpty)
                }
            }
            .navigationTitle("New Host")
        }
    }
}

struct RenameTarget: Identifiable {
    let id = UUID()
    let name: String
}

struct RenameFileOrDirView: View {
    @Environment(\.dismiss) private var dismiss
    let fileToRename: String
    @State private var renameTo: String

    var onSave: (String) -> Void

    init(_ fileToRename: String, onSave: @escaping (String) -> Void) {
        self.fileToRename = fileToRename
        self.renameTo = fileToRename
        self.onSave = onSave
    }

    var body : some View {
        NavigationStack {
            Text("Original Path: \(fileToRename)")
            Form {
                TextField("Rename to", text: $renameTo)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(renameTo)
                        dismiss()
                    }
                    .disabled(renameTo.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .navigationTitle("Rename Contents")
    }
}

// MARK: - HostView
//
// Shown in the detail column once the user picks a host from the sidebar. Lists files
// and folders at `currentPath`, lets the user navigate into folders, and pushes a
// FileView onto its own NavigationStack when a file is tapped.
//
// The SSH session is owned by ContentView and passed in here as `let`, so the connection
// outlives any in-this-view navigation.
struct HostView: View {
    let host: Host                              // selected host metadata (passed from ContentView)
    let ssh: SSHSession                         // shared SSH actor
    @Binding var showTerminal: Bool             // two-way: terminal toolbar button toggles this
    let terminalHeight: CGFloat                 // read-only: used to reserve safe-area space

    @State private var entries: [SFTPPathComponent] = []   // current directory listing
    @State private var currentPath = "/"                   // path we're currently browsing
    @State private var lastWorkingPath = "/"               // last path that loaded OK (for "Go back" button)
    @State private var errorMessage: String?               // shown if list/connect fails
    @State private var isLoading = true
    @State private var nonDirSymlinks: Set<String> = []    // filenames known to be symlinks-to-non-dirs

    @State private var renameTarget: RenameTarget? = nil
    @State private var deleteTarget: String? = nil // filename pending delete confirmation
    @State private var actionError: String? // shown in an alert for transient action failures

    @State private var showCreateNew: Bool = false
    
    var body: some View {
        // Each HostView gets its own NavigationStack so file pushes happen inside this column.
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    // Error state: show the message and (if relevant) a "Go back" button
                    // that returns to the last working directory.
                    VStack(alignment: .leading, spacing: 12) {
                        Text(errorMessage).foregroundStyle(.red)
                        if currentPath != lastWorkingPath {
                            Button {
                                currentPath = lastWorkingPath
                            } label: {
                                Label("Go back to \(lastWorkingPath)", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                } else {
                    // Success state: list each entry, decide row type by whether it's navigable.
                    ForEach(entries, id: \.filename) { entry in
                        entryRow(entry)
                    }
                }
            }
            // Scrolling the list dismisses the keyboard if one is up.
            .scrollDismissesKeyboard(.immediately)
            // Reserve room for the persistent terminal beneath the list.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: showTerminal ? terminalHeight + 16 : 0)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showCreateNew = true
                    } label: {
                        Label("Create New", systemImage: "plus")
                    }
                    Button {
                        showTerminal.toggle()
                    } label: {
                        Label("Toggle Terminal", systemImage: "terminal")
                    }
                }
            }
            .alert(
                "Action Failed",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                ),
                presenting: actionError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error)
            }
            .sheet(isPresented: $showCreateNew) {
                CreateNewContent(currentPath) { path, isDir in
                    Task {
                        do {
                            try await ssh.touch(path, isDir: isDir)
                        } catch {
                            actionError = error.localizedDescription
                        }
                        await load()
                    }
                }
            }
            .confirmationDialog(
                deleteTarget.map { "Delete “\($0)”?" } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { name in
                Button("Delete", role: .destructive) {
                    let target = join(currentPath, name)
                    Task {
                        do {
                            try await ssh.delete(target)
                        } catch {
                            actionError = error.localizedDescription
                        }
                        await load()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This cannot be undone.")
            }
            .sheet(item: $renameTarget) { target in
                RenameFileOrDirView(target.name) { renameTo in
                    Task {
                        do {
                            try await ssh.rename(join(currentPath, target.name),
                                                 join(currentPath, renameTo))
                        } catch {
                            actionError = error.localizedDescription
                        }
                        await load()
                    }
                }
            }
            .navigationTitle(host.name)
            // `.task(id:)` reruns the closure whenever the id string changes.
            // host.id changes when SwiftUI gives us a different HostView instance for a
            // different host; currentPath changes when the user navigates into a folder.
            // Either way, we (re)load the listing.
            .task(id: "\(host.id):\(currentPath)") { await load() }
            // Background/foreground lifecycle observer (sibling task, runs the whole time HostView is alive).
            .task { await observeScenePhase() }
        }
    }

    // One row of the directory listing. Extracted from `body` to keep the type-checker
    // happy — the inline if/else with two contextMenus full of closures was over the limit.
    @ViewBuilder
    private func entryRow(_ entry: SFTPPathComponent) -> some View {
        if isNavigable(entry) {
            // Folder (or directory-symlink): tapping changes currentPath.
            Button {
                currentPath = join(currentPath, entry.filename)
            } label: {
                Label(entry.filename, systemImage: "folder")
            }
            .contextMenu { entryContextMenu(for: entry) }
        } else {
            // Regular file: push FileView to edit it.
            NavigationLink {
                FileView(
                    path: join(currentPath, entry.filename),
                    ssh: ssh,
                    showTerminal: $showTerminal,
                    // Reserve room for the persistent terminal so the editor
                    // isn't covered when the terminal is showing.
                    bottomReserve: showTerminal ? terminalHeight + 16 : 0
                )
            } label: {
                Label(entry.filename, systemImage: "doc")
            }
            .contextMenu { entryContextMenu(for: entry) }
        }
    }

    // Rename / Copy Path / Delete actions shared by both row types.
    @ViewBuilder
    private func entryContextMenu(for entry: SFTPPathComponent) -> some View {
        if entry.filename != "." && entry.filename != ".." {
            Button("Rename", systemImage: "pencil") {
                Task {
                    renameTarget = RenameTarget(name: entry.filename)
                    await load()
                }
            }
            Button("Copy Path", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = join(currentPath, entry.filename)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteTarget = entry.filename
            }
        }
    }

    // Listens for iOS app-lifecycle notifications. On background we disconnect cleanly so
    // a half-dead TCP socket doesn't get stuck. On foreground we re-run load() which will
    // reconnect via the host-aware isConnected check.
    private func observeScenePhase() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                    await ssh.disconnect()
                }
            }
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                    await load()
                }
            }
        }
    }

    // Path join helper. `".."` walks up one level (clamped at "/"), anything else is appended.
    // `NSString` has handy `appendingPathComponent` / `deletingLastPathComponent` methods.
    private func join(_ base: String, _ name: String) -> String {
        if name == ".." {
            guard base != "/" else { return "/" }
            return (base as NSString).deletingLastPathComponent
        }
        return (base as NSString).appendingPathComponent(name)
    }

    // The main "fetch the directory listing for currentPath" routine. Called by .task(id:)
    // whenever the host or path changes.
    private func load() async {
        isLoading = true
        errorMessage = nil
        nonDirSymlinks = []           // reset symlink resolution cache for the new directory
        defer { isLoading = false }
        do {
            // Only call connect if we're not already connected to *this specific host*.
            // The host-aware check is what lets switching hosts work without "Output closed"
            // races, and avoids resetting the terminal when navigating within one host.
            if await !ssh.isConnected(to: host.address) {
                try await ssh.connect(
                    host: host.address,
                    user: host.user,
                    password: host.password
                )
            }
            // Pull the listing and sort it Finder-style (case-insensitive, numeric-aware).
            let newEntries = try await ssh.list(currentPath).sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
            entries = newEntries
            lastWorkingPath = currentPath
            // Resolve which symlinks actually point to non-directories, in the background.
            let path = currentPath
            Task { await resolveSymlinks(in: path, entries: newEntries) }
        } catch {
            errorMessage = String(reflecting: error)
        }
    }

    // POSIX file type checks using the raw mode bits returned by SFTP.
    // `S_IFMT` masks out the file-type bits; `S_IFDIR`/`S_IFLNK` are the specific patterns.
    private func isDirectory(_ entry: SFTPPathComponent) -> Bool {
        guard let mode = entry.attributes.permissions else { return false }
        return (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    }

    private func isSymlink(_ entry: SFTPPathComponent) -> Bool {
        guard let mode = entry.attributes.permissions else { return false }
        return (mode & UInt32(S_IFMT)) == UInt32(S_IFLNK)
    }

    // Decide whether tapping this row should navigate into a folder.
    // Default: directories and symlinks. Once we've resolved a symlink's target as non-dir,
    // we add it to `nonDirSymlinks` so it stops being treated as navigable.
    private func isNavigable(_ entry: SFTPPathComponent) -> Bool {
        if nonDirSymlinks.contains(entry.filename) { return false }
        return isDirectory(entry) || isSymlink(entry)
    }

    // For each symlink in the listing, do a follow-stat to find out what its target is.
    // If the target is NOT a directory, mark it as non-navigable so the UI updates the row.
    // Captures `path` at task start; aborts if the user navigates away mid-resolution.
    private func resolveSymlinks(in path: String, entries: [SFTPPathComponent]) async {
        for entry in entries where isSymlink(entry) {
            let target = (path as NSString).appendingPathComponent(entry.filename)
            guard let attrs = try? await ssh.stat(target) else { continue }
            let mode = attrs.permissions ?? 0
            let isDir = (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
            guard !isDir else { continue }
            guard currentPath == path else { return }    // user navigated away — bail
            nonDirSymlinks.insert(entry.filename)
        }
    }
}

/// The top-level view of the app. It owns the cross-host state that needs to survive
/// navigation: the saved-hosts list, the currently-selected host, the active SSH session,
/// and the persistent terminal pane (which sits ABOVE all navigation so editing a file
/// can't tear it down).
struct ContentView: View {
    // `@Environment` reads a value SwiftUI is providing from somewhere above us in the
    // view tree. SwiftData injects the model context this way. We don't use it directly
    // below, but it's needed for the SwiftData Preview.
    @Environment(\.modelContext) private var modelContext

    // `@State` is SwiftUI's "this view owns this mutable value" annotation. When a @State
    // value changes, SwiftUI re-runs `body` to redraw. `private` keeps these internal to
    // the view (only this struct can mutate them).
    @State private var hosts: [Host] = []                    // loaded from the SQLite db
    @State private var showAddSSHHost = false                // controls the "Add Host" sheet
    @State private var selectedHost: Host?                   // nil when nothing is selected in the sidebar
    @State private var ssh = SSHSession()                    // the one SSH actor shared across this whole view
    @State private var showTerminal = false                  // toggled by the terminal button in HostView/FileView
    @State private var terminalHeight: CGFloat = 280         // current height of the terminal pane in pt
    @State private var keyboardHeight: CGFloat = 0           // kept up-to-date by `observeKeyboardGlobal`; currently informational
    @State private var terminalDragStartHeight: CGFloat? = nil // remembers the height when a resize drag begins

    // `let`/`var` without `@State` is a plain stored property. `database` is created once
    // when the view is initialized and never reassigned, so a regular `private var` is fine.
    // `try!` here means "crash if the DB can't be opened" — acceptable for a local sqlite
    // file we always expect to exist.
    private var database: Database = try! Database()

    // `body` is the only required property of a `View` — SwiftUI calls it to know what to draw.
    // It returns `some View`, meaning "some opaque concrete View type" — Swift figures out
    // the exact type from the contents.
    var body: some View {
        // `NavigationSplitView` is the two-pane layout (sidebar + detail) that automatically
        // collapses to a single push-stack on iPhone in compact width.
        NavigationSplitView {
            // SIDEBAR: list of hosts.
            // `List(selection:)` binds the user's tap to `$selectedHost` — when a row is tapped,
            // SwiftUI writes the corresponding Host into our @State.
            List(selection: $selectedHost) {
                // `ForEach` iterates an Identifiable collection to produce one view per element.
                ForEach(hosts) { item in
                    // The value-form NavigationLink works with `List(selection:)` and
                    // `navigationDestination` patterns. Tapping writes `item` into `selectedHost`.
                    NavigationLink(value: item) {
                        Text(item.name)
                    }
                }
                // `.onDelete` adds swipe-to-delete on each row in the List.
                .onDelete(perform: deleteItem)
            }
            // Toolbar items live in the navigation bar (top of the sidebar).
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()  // built-in toggle for List edit mode (used by .onDelete)
                }
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
            // `.task` runs an async block when the view appears, and cancels it when the view
            // disappears. We use it to load hosts from the database on first show.
            .task { reloadHosts() }
            // `.sheet(isPresented:)` shows a modal sheet when the bound bool is true.
            // The `AddHostView` calls back into `onSave` with the new Host, which we insert
            // and then reload from the db.
            .sheet(isPresented: $showAddSSHHost) {
                withAnimation {
                    AddHostView { newHost in
                        withAnimation {
                            try! database.addHost(host: newHost)
                            reloadHosts()
                        }
                    }
                }
            }
        } detail: {
            // DETAIL: shows the selected host's file browser, or a placeholder if nothing is selected.
            if let selectedHost {
                HostView(
                    host: selectedHost,
                    ssh: ssh,                          // pass the actor reference down
                    showTerminal: $showTerminal,       // `$` makes it a Binding (two-way)
                    terminalHeight: terminalHeight     // read-only here, just for layout reservation
                )
                // `.id(...)` tells SwiftUI to treat this as a *new* view when the id changes.
                // Result: switching hosts recreates HostView fresh (clears state, fires .task).
                .id(selectedHost.id)
            } else {
                Text("Select a host to connect to")
            }
        }
        // `.overlay(alignment: .bottom)` draws content ON TOP of the modified view (the
        // NavigationSplitView) anchored to its bottom. Because it's outside the navigation
        // hierarchy, push transitions inside HostView/FileView can't drag it off-screen.
        // That's the trick that keeps the terminal pinned across navigation.
        .overlay(alignment: .bottom) {
            if showTerminal {
                VStack(spacing: 0) {
                    terminalResizeHandle
                    TerminalPaneView(ssh: ssh, onClose: { showTerminal = false })
                        .frame(maxWidth: .infinity)
                        .frame(height: terminalHeight)
                }
                .background(Color.black) // fills the home-indicator area cleanly
                // Ignore the geometric safe-area only (notch / home indicator) so the
                // terminal extends to the physical bottom of the screen. We do NOT ignore
                // the keyboard safe area, so SwiftUI auto-raises the overlay when typing.
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // `.onChange(of:)` fires whenever the bound value changes. Here: when the user
        // picks a different host, hide the terminal and cleanly tear down the SSH client.
        // (The new HostView will reconnect on its own via its load() task.)
        .onChange(of: selectedHost) { _, _ in
            showTerminal = false
            Task { await ssh.disconnect() }
        }
        // Long-running background task that watches keyboard notifications.
        .task { await observeKeyboardGlobal() }
    }

    // MARK: - Subviews

    // A computed property that returns a small View. This is the gray draggable bar above
    // the terminal. The drag gesture defers committing the new height until the user lets
    // go (onEnded), which keeps SwiftTerm from re-laying out cells on every drag tick.
    private var terminalResizeHandle: some View {
        ZStack {
            Color(uiColor: .systemGray5)
            Capsule()
                .fill(Color.secondary)
                .frame(width: 40, height: 5)
        }
        .frame(height: 16)
        .contentShape(Rectangle()) // make the entire 16pt strip tap-receptive, not just the capsule
        // Tapping the handle (without dragging) dismisses any keyboard that might be up.
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .gesture(
            DragGesture()
                // `onChanged` runs many times per second during a drag. We only record the
                // starting height — we don't touch `terminalHeight` here, which is what
                // prevents the terminal from strobing while dragging.
                .onChanged { value in
                    if terminalDragStartHeight == nil {
                        terminalDragStartHeight = terminalHeight
                    }
                }
                // `onEnded` fires once when the user lifts their finger. We compute the
                // final height and assign it in a single update.
                .onEnded { value in
                    let start = terminalDragStartHeight ?? terminalHeight
                    // Drag up = grow taller (translation.height is negative when dragging up,
                    // so we subtract). Clamp between 120pt and 800pt so the pane can't vanish.
                    let final = max(120, min(800, start - value.translation.height))
                    terminalDragStartHeight = nil
                    terminalHeight = final
                }
        )
    }

    // MARK: - Helpers

    // Subscribes to two iOS notifications and keeps `keyboardHeight` in sync.
    // `withTaskGroup` runs both subscriptions concurrently and cancels them when the
    // surrounding .task is cancelled (e.g., when this view is removed).
    private func observeKeyboardGlobal() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // The notification stream is async — `for await` reads one event at a time.
                for await note in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) {
                    if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                        // SwiftUI state must be written from the main actor.
                        await MainActor.run { keyboardHeight = frame.height }
                    }
                }
            }
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillHideNotification) {
                    await MainActor.run { keyboardHeight = 0 }
                }
            }
        }
    }

    // Reload the list of hosts from the SQLite database. `try?` returns nil on failure
    // and we fall back to an empty array so the UI shows "no hosts" cleanly.
    private func reloadHosts() {
        hosts = (try? database.getHosts()) ?? []
    }

    // Toolbar "+" button handler — just shows the AddHostView sheet via the bound bool.
    private func addItem() {
        showAddSSHHost = true
    }

    // Called by `.onDelete` with the indices the user swiped/selected to delete.
    // We delete each from the database, then reload to refresh the displayed list.
    private func deleteItem(offsets: IndexSet) {
        for index in offsets {
            try? database.deleteHost(host: hosts[index])
        }
        reloadHosts()
    }
}

// MARK: - Preview
//
// `#Preview` is the Xcode preview macro — it tells Xcode "render this view in the
// canvas." `.modelContainer(...)` provides an in-memory SwiftData container so the
// view's `@Environment(\.modelContext)` lookup doesn't crash inside the preview.
#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
