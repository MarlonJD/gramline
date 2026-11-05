import DMCore
import Foundation

@MainActor
final class CoreProcess {
    var onEvent: ((WireFrame) throws -> Void)?
    var onExit: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private let writes = DispatchQueue(label: "dev.instadm.pipe.write")
    private var generation = UUID()

    func start() throws {
        guard process == nil else { return }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "insta-core") else {
            throw CoreError(code: "helper_missing", message: "The connection helper is missing. Rebuild InstaDM using script/build_and_run.sh.")
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        let current = UUID(); generation = current
        child.executableURL = executable
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated(generation: current) }
        }
        try child.run()
        process = child; input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            var framer = LineFramer()
            do {
                while true {
                    let chunk = output.availableData
                    if chunk.isEmpty { break }
                    for line in try framer.append(chunk) { continuation.yield(line) }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            try? output.close()
        }
        reader = Task { [weak self] in
            do {
                for try await bytes in stream {
                    guard let self, self.generation == current else { return }
                    let frame = try JSONDecoder().decode(WireFrame.self, from: bytes)
                    guard frame.v == 1 else { throw CoreError(code: "version", message: "InstaDM and its helper use different protocol versions.") }
                    if let id = frame.id, let continuation = self.pending.removeValue(forKey: id) {
                        self.deadlines.removeValue(forKey: id)?.cancel()
                        if let error = frame.error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: frame.data ?? .null) }
                    } else { try self.onEvent?(frame) }
                }
            } catch { self?.failPending(error); self?.stop() }
        }
    }

    func request(_ type: String, _ data: JSONValue = .object([:]), timeout: Duration = .seconds(70)) async throws -> JSONValue {
        guard process?.isRunning == true else { throw disconnected() }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.deadlines.removeValue(forKey: id)
                self?.pending.removeValue(forKey: id)?.resume(throwing: CoreError(code: "timeout", message: "Instagram did not respond in time."))
            }
            write(WireFrame(id: id, type: type, data: data))
        }
    }

    func acknowledge(saveID: String, success: Bool) {
        write(WireFrame(type: "session_ack", data: .object(["saveID": .string(saveID), "ok": .bool(success)])))
    }

    func stop() {
        generation = UUID()
        reader?.cancel(); reader = nil
        try? input?.close(); input = nil
        if let child = process, child.isRunning {
            child.terminate()
            Task { try? await Task.sleep(for: .seconds(2)); if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        process = nil
        failPending(disconnected())
    }

    private func write(_ frame: WireFrame) {
        do {
            guard let input else { throw disconnected() }
            var bytes = try JSONEncoder().encode(frame); bytes.append(10)
            let payload = bytes
            writes.async { [weak self] in
                do { try input.write(contentsOf: payload) }
                catch { Task { @MainActor in self?.failPending(CoreError(code: "pipe", message: "The connection helper stopped.")) } }
            }
        } catch { failPending(error) }
    }
    private func terminated(generation: UUID) {
        guard self.generation == generation else { return }
        process = nil; try? input?.close(); input = nil
        failPending(disconnected()); onExit?()
    }
    private func failPending(_ error: Error) {
        let requests = pending; pending.removeAll()
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        requests.values.forEach { $0.resume(throwing: error) }
    }
    private func disconnected() -> CoreError { CoreError(code: "disconnected", message: "The connection helper is offline. Reconnect to continue.") }
}
