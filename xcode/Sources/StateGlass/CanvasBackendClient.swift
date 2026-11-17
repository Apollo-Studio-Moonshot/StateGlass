import Foundation

enum CanvasBackendError: LocalizedError {
    case unavailable
    case invalidResponse
    case response(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The SoloVibe Python backend could not be located. Rebuild the app or check its Python installation."
        case .invalidResponse:
            "The SoloVibe backend returned an invalid response."
        case .response(let message):
            message
        }
    }
}

private struct BackendRequest: Encodable {
    let id: String
    let method: String
    let protocolVersion: Int
    let params: [String: String]
}

private struct BackendEnvelope: Decodable {
    struct BackendFailure: Decodable {
        let message: String
    }

    let id: String?
    let result: Data?
    let error: BackendFailure?

    enum CodingKeys: String, CodingKey {
        case id, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        if let resultValue = try container.decodeIfPresent(AnyCodable.self, forKey: .result) {
            result = try JSONEncoder().encode(resultValue)
        } else {
            result = nil
        }
        error = try container.decodeIfPresent(BackendFailure.self, forKey: .error)
    }
}

private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self.value = value }
        else if let value = try? container.decode(Bool.self) { self.value = value }
        else if let value = try? container.decode(Int.self) { self.value = value }
        else if let value = try? container.decode(Double.self) { self.value = value }
        else if let value = try? container.decode([AnyCodable].self) { self.value = value.map(\.value) }
        else if let value = try? container.decode([String: AnyCodable].self) { self.value = value.mapValues(\.value) }
        else if container.decodeNil() { self.value = NSNull() }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let value as String: try container.encode(value)
        case let value as Bool: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Double: try container.encode(value)
        case let value as [Any]: try container.encode(value.map(AnyCodable.init(value:)))
        case let value as [String: Any]: try container.encode(value.mapValues(AnyCodable.init(value:)))
        case is NSNull: try container.encodeNil()
        default: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    private init(value: Any) {
        self.value = value
    }
}

final class CanvasBackendClient: @unchecked Sendable {
    func request<Response: Decodable & Sendable>(
        _ method: String,
        params: [String: String] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await Task.detached {
            try Self.perform(method, params: params, as: type)
        }.value
    }

    private static func perform<Response: Decodable>(
        _ method: String,
        params: [String: String],
        as type: Response.Type
    ) throws -> Response {
        let modulePath = try locateModulePath()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "solovibe"]
        var environment = ProcessInfo.processInfo.environment
        let previousPythonPath = environment["PYTHONPATH"]
        environment["PYTHONPATH"] = [modulePath.path, previousPythonPath]
            .compactMap { $0 }
            .joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            let request = BackendRequest(
                id: UUID().uuidString,
                method: method,
                protocolVersion: 1,
                params: params
            )
            var bytes = try JSONEncoder().encode(request)
            bytes.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
            let responseData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let response = try? JSONDecoder().decode(BackendEnvelope.self, from: responseData)
            else {
                throw CanvasBackendError.invalidResponse
            }
            if let error = response.error {
                throw CanvasBackendError.response(error.message)
            }
            guard let result = response.result else {
                throw CanvasBackendError.invalidResponse
            }
            return try JSONDecoder().decode(type, from: result)
        } catch let error as CanvasBackendError {
            throw error
        } catch {
            throw CanvasBackendError.response(error.localizedDescription)
        }
    }

    private static func locateModulePath() throws -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("python", isDirectory: true)
            if FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent("solovibe").path
            ) {
                return bundled
            }
        }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            repository.deleteLastPathComponent()
        }
        let source = repository.appendingPathComponent("python", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("solovibe").path) else {
            throw CanvasBackendError.unavailable
        }
        return source
    }
}
