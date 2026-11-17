@preconcurrency import Foundation

enum SidecarError: LocalizedError {
    case unavailable(String)
    case processExited
    case response(String)
    case encoding

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .response(let message):
            message
        case .processExited:
            "The Stateglass backend stopped unexpectedly."
        case .encoding:
            "Could not encode a request for the Stateglass backend."
        }
    }
}

final class SidecarClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private var lineBuffer = Data()
    private let eventContinuation: AsyncStream<SidecarEvent>.Continuation
    let events: AsyncStream<SidecarEvent>

    init() {
        let channel = AsyncStream<SidecarEvent>.makeStream()
        events = channel.stream
        eventContinuation = channel.continuation
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }

        let executable = try locateSidecar()
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderrPipe = Pipe()
        child.executableURL = executable
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderrPipe
        try child.run()
        process = child
        input = stdin.fileHandleForWriting

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.processEnded()
            } else {
                self?.consume(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let message = String(data: data, encoding: .utf8) {
                fputs(message, stderr)
            }
        }
    }

    func request<Response: Decodable & Sendable>(
        _ method: String,
        params: sending [String: Any] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            let id = UUID().uuidString
            let message: [String: Any] = [
                "id": id,
                "method": method,
                "protocolVersion": 1,
                "params": params,
            ]
            guard JSONSerialization.isValidJSONObject(message),
                  var bytes = try? JSONSerialization.data(withJSONObject: message)
            else {
                continuation.resume(throwing: SidecarError.encoding)
                return
            }
            bytes.append(0x0A)

            lock.lock()
            guard process?.isRunning == true, let input else {
                lock.unlock()
                continuation.resume(throwing: SidecarError.processExited)
                return
            }
            pending[id] = continuation
            do {
                try input.write(contentsOf: bytes)
                lock.unlock()
            } catch {
                pending.removeValue(forKey: id)
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
        return try JSONDecoder().decode(Response.self, from: responseData)
    }

    func stop() {
        lock.lock()
        let child = process
        let isRunning = child?.isRunning ?? false
        process = nil
        input = nil
        lock.unlock()
        if isRunning { child?.terminate() }
        failAll(SidecarError.processExited)
        eventContinuation.finish()
    }

    private func locateSidecar() throws -> URL {
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["STATEGLASS_SIDECAR_PATH"] {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("stateglass-sidecar"))
        }

        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            repository.deleteLastPathComponent()
        }
        candidates.append(repository.appendingPathComponent("src-tauri/target/debug/stateglass-sidecar"))
        candidates.append(repository.appendingPathComponent("src-tauri/target/release/stateglass-sidecar"))

        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw SidecarError.unavailable(
            "The Stateglass Rust backend is missing. Build it with `scripts/build-macos.sh` or set STATEGLASS_SIDECAR_PATH."
        )
    }

    private func consume(_ data: Data) {
        lock.lock()
        lineBuffer.append(data)
        var lines: [Data] = []
        while let newline = lineBuffer.firstRange(of: Data([0x0A])) {
            lines.append(lineBuffer.subdata(in: lineBuffer.startIndex..<newline.lowerBound))
            lineBuffer.removeSubrange(lineBuffer.startIndex..<newline.upperBound)
        }
        lock.unlock()

        for line in lines {
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = message["kind"] as? String
        else {
            failAll(SidecarError.response("The backend sent malformed JSON."))
            return
        }
        guard message["protocolVersion"] as? Int == 1 else {
            failAll(SidecarError.response("The Rust backend uses an unsupported protocol version."))
            return
        }
        if kind == "protocolError" {
            failAll(SidecarError.response(message["error"] as? String ?? "The backend rejected a protocol message."))
            return
        }
        if kind == "event" {
            guard let name = message["event"] as? String,
                  let payload = message["payload"],
                  let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
            else {
                failAll(SidecarError.response("The backend sent an invalid event."))
                return
            }
            eventContinuation.yield(SidecarEvent(name: name, payload: payloadData))
            return
        }
        guard kind == "response" else {
            failAll(SidecarError.response("The backend sent an unknown message type."))
            return
        }
        guard let id = message["id"] as? String else {
            failAll(SidecarError.response("The backend response did not include a request ID."))
            return
        }

        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }

        if let error = message["error"] as? [String: Any],
           let text = error["message"] as? String {
            continuation.resume(throwing: SidecarError.response(text))
        } else if let result = message["result"],
                  let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
            continuation.resume(returning: resultData)
        } else {
            continuation.resume(throwing: SidecarError.response("The backend returned an invalid response."))
        }
    }

    private func failAll(_ error: any Error) {
        lock.lock()
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func processEnded() {
        lock.lock()
        process = nil
        input = nil
        lock.unlock()
        failAll(SidecarError.processExited)
    }

    deinit {
        stop()
    }
}
