import Foundation

/// Converte o ALAC final para MP3 320kbps CBR via ffmpeg, com tags ID3 e capa.
struct Mp3Encoder: Sendable {
    let ffmpegURL: URL

    static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.components(separatedBy: ":").map { "\($0)/ffmpeg" }
        }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Bloqueante: rodar dentro da task da conversionQueue. Falha nunca toca
    /// no ALAC de origem.
    func encode(alacURL: URL, metadata: TrackMetadata, artwork: ArtworkFile?, to destination: URL) throws {
        let destDir = destination.deletingLastPathComponent()
        // Escreve num temp e move no sucesso — evita MP3 truncado no destino.
        let tempMP3 = destDir.appendingPathComponent(".enc-\(UUID().uuidString).mp3")

        var args = ["-hide_banner", "-nostdin", "-y", "-i", alacURL.path]
        if let artwork {
            args += ["-i", artwork.url.path]
        }
        args += ["-map", "0:a", "-c:a", "libmp3lame", "-b:a", "320k"]
        if artwork != nil {
            args += [
                "-map", "1:v", "-c:v", "copy",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)",
                "-disposition:v", "attached_pic",
            ]
        }
        args += ["-id3v2_version", "3", "-write_id3v1", "1"]

        func tag(_ key: String, _ value: String) {
            guard !value.isEmpty else { return }
            args += ["-metadata", "\(key)=\(value)"]
        }
        tag("title", metadata.name)
        tag("artist", metadata.artist)
        tag("album", metadata.album)
        tag("album_artist", metadata.effectiveAlbumArtist)
        tag("genre", metadata.genre)
        if let year = metadata.year { tag("date", String(year)) }
        if let track = metadata.trackNumber {
            let count = metadata.trackCount.map { "/\($0)" } ?? ""
            tag("track", "\(track)\(count)")
        }
        if let disc = metadata.discNumber {
            let count = metadata.discCount.map { "/\($0)" } ?? ""
            tag("disc", "\(disc)\(count)")
        }
        args.append(tempMP3.path)

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        // Ler stderr até EOF antes de waitUntilExit evita deadlock de pipe cheio.
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempMP3)
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let tail = stderr
                .components(separatedBy: "\n")
                .suffix(15)
                .joined(separator: "\n")
            throw RuntimeError("ffmpeg saiu com código \(process.terminationStatus):\n\(tail)")
        }

        try FileManager.default.moveItem(at: tempMP3, to: destination)
    }
}
