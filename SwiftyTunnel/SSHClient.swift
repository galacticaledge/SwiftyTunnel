//
//  SSHClient.swift
//  SwiftEditSH
//
//  Created by Chris Rios on 5/31/26.
//

import Foundation
import Citadel
internal import NIOCore
internal import NIOFoundationEssentialsCompat
internal import NIOSSH

enum EditError: LocalizedError {
    case tooLarge(UInt64)
    case binary
    case notUTF8
    case notConnected

    var errorDescription: String? {
        switch self {
        case .tooLarge(let size): return "File is too large to edit (\(size) bytes)."
        case .binary: return "File appears to be binary."
        case .notUTF8: return "File is not valid UTF-8 text."
        case .notConnected: return "Not connected."
        }
    }
}

actor SSHSession {
    private static let maxEditableSize: UInt64 = 1_000_000  // 1 MB
    private var terminalStdin: (@Sendable (ByteBuffer) async throws -> Void)?
    private var terminalResize: (@Sendable (Int, Int) async throws -> Void)?

    var client: SSHClient? // SSH Client
    var sftp: SFTPClient? // SFTP Client
    private var connectedHost: String?

    func connect(host: String, user: String, password: String) async throws {
        // If something is lingering, tear it down first so we don't leak a half-dead session.
        await disconnect()
        client = try await SSHClient.connect(
            host: host,
            authenticationMethod: .passwordBased(username: user, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .always
        )
        sftp = try await client?.openSFTP()
        connectedHost = host
    }

    func disconnect() async {
        terminalStdin = nil
        terminalResize = nil
        if let sftp {
            try? await sftp.close()
        }
        sftp = nil
        if let client {
            try? await client.close()
        }
        client = nil
        connectedHost = nil
    }

    func isConnected(to host: String) -> Bool {
        client != nil && sftp != nil && connectedHost == host
    }
    
    func list(_ path: String) async throws -> [SFTPPathComponent] {
        // Get list of files
        guard let sftp else { throw EditError.notConnected }
        return try await sftp.listDirectory(atPath: path).flatMap(\.components)
    }

    func read(_ path: String) async throws -> String {
        guard let sftp else { throw EditError.notConnected }
        let file = try await sftp.openFile(filePath: path, flags: .read)
        defer { Task { try? await file.close() } }
        let buf = try await file.readAll()
        return buf.getString(at: 0, length: buf.readableBytes) ?? ""
    }

    func write(_ path: String, _ text: String) async throws {
        guard let sftp else { throw EditError.notConnected }
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        var buf = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buf.writeString(text)
        try await file.write(buf, at: 0)
        try await file.close()
    }
    
    func touch(_ path: String, isDir: Bool) async throws {
        if !isDir {
            try await sftp?.openFile(
                filePath: path,
                flags: [.write, .forceCreate]
            )
        } else {
            try await sftp?.createDirectory(atPath: path)
        }
    }
    
    func download(_ path: String, _ dest: String, isDir: Bool) async throws {
        let destURL = URL(filePath: dest)
        let filename = (path as NSString).lastPathComponent
        let localURL = destURL.appending(path: filename)

        if !isDir {
            let file = try await sftp?.openFile(filePath: path, flags: [.read])
            guard let buf = try await file?.readAll() else { return }
            try Data(buffer: buf).write(to: localURL)
            try await file?.close()
        } else {
            let entries = try await sftp?.listDirectory(atPath: path).flatMap(\.components) ?? []
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            for entry in entries where entry.filename != "." && entry.filename != ".." {
                let childPath = path + "/" + entry.filename
                let isChildDir = ((entry.attributes.permissions ?? 0) & 0o170000) == 0o040000
                try await download(childPath, localURL.path, isDir: isChildDir)
            }
        }
    }
    
    func rename(_ path: String, _ newPath: String) async throws {
        try await sftp?.rename(at: path, to: newPath)
    }
    
    func delete(_ path: String) async throws {
        guard let sftp else { throw EditError.notConnected }
        let attrs = try await sftp.getAttributes(at: path)
        let isDirectory = (attrs.permissions ?? 0) & 0o170000 == 0o040000
        if isDirectory {
            let entries = try await sftp.listDirectory(atPath: path).flatMap(\.components)
            for entry in entries where entry.filename != "." && entry.filename != ".." {
                try await delete(path + "/" + entry.filename)
            }
            try await sftp.rmdir(at: path)
        } else {
            try await sftp.remove(at: path)
        }
    }

    func stat(_ path: String) async throws -> SFTPFileAttributes {
        guard let sftp else { throw EditError.notConnected }
        return try await sftp.getAttributes(at: path)
    }

    func readBytes(_ path: String) async throws -> Data {
        let file = try await sftp!.openFile(filePath: path, flags: .read)
        defer { Task { try? await file.close() } }
        let buf = try await file.readAll()
        return Data(buffer: buf)
    }

    func readForEditing(_ path: String) async throws -> String {
        let attrs = try await stat(path)
        if let size = attrs.size, size > Self.maxEditableSize {
            throw EditError.tooLarge(size)
        }
        let data = try await readBytes(path)
        guard !data.contains(0) else { throw EditError.binary }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EditError.notUTF8
        }
        return text
    }
    
    private func setTerminal(
        write: (@Sendable (ByteBuffer) async throws -> Void)?,
        resize: (@Sendable (Int, Int) async throws -> Void)?
    ) {
        self.terminalStdin = write
        self.terminalResize = resize
    }

    func openTerminal(cols: Int = 80, rows: Int = 24) async throws -> AsyncStream<[UInt8]> {
        guard let client else { throw EditError.notConnected }
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        Task { [weak self] in
            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    await self?.setTerminal(
                        write: { buf in try await outbound.write(buf) },
                        resize: { cols, rows in
                            try await outbound.changeSize(
                                cols: cols,
                                rows: rows,
                                pixelWidth: 0,
                                pixelHeight: 0
                            )
                        }
                    )
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buf), .stderr(let buf):
                            continuation.yield(Array(buffer: buf))
                        }
                    }
                }
            } catch {
                let msg = "\n[terminal error: \(String(reflecting: error))]\n"
                continuation.yield(Array(msg.utf8))
            }
            await self?.setTerminal(write: nil, resize: nil)
            continuation.finish()
        }

        return stream
    }

    func sendBytes(_ bytes: [UInt8]) async throws {
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        try await terminalStdin?(buf)
    }

    func sendInput(_ text: String) async throws {
        try await sendBytes(Array(text.utf8))
    }

    func resizeTerminal(cols: Int, rows: Int) async throws {
        try await terminalResize?(cols, rows)
    }
}
