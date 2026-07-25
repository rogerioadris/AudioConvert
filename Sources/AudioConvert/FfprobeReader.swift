import Foundation

/// Lê tags e duração de um MP3 via ffprobe (vem junto do ffmpeg no Homebrew).
/// Usamos ffprobe em vez de AVAsset porque a API síncrona do AVAsset está
/// deprecada no macOS 15 e o projeto é síncrono/DispatchQueue.
struct FfprobeReader: Sendable {
    struct ProbeInfo: Sendable {
        var title: String
        var artist: String
        var album: String
        var durationSeconds: Int  // -1 = desconhecida (convenção M3U)
    }

    let ffprobeURL: URL

    static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.components(separatedBy: ":").map { "\($0)/ffprobe" }
        }
        candidates += ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Bloqueante: um processo ffprobe por arquivo.
    func read(_ mp3: URL) throws -> ProbeInfo {
        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            mp3.path,
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Ler stdout até EOF antes de waitUntilExit evita deadlock de pipe cheio.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let format = root["format"] as? [String: Any]
        else {
            throw RuntimeError("ffprobe falhou em \(mp3.lastPathComponent)")
        }

        // ffprobe varia a caixa das chaves de tag (artist/ARTIST) conforme a origem.
        var tags: [String: String] = [:]
        if let rawTags = format["tags"] as? [String: Any] {
            for (key, value) in rawTags {
                tags[key.lowercased()] = (value as? String) ?? ""
            }
        }

        let duration = (format["duration"] as? String).flatMap(Double.init)
        return ProbeInfo(
            title: tags["title"] ?? "",
            artist: tags["artist"] ?? "",
            album: tags["album"] ?? "",
            durationSeconds: duration.map { Int($0.rounded()) } ?? -1
        )
    }
}
