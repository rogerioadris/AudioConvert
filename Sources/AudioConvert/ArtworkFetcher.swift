import CoreMedia
import Foundation

enum ArtworkFormat: Sendable {
    case jpeg
    case png

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    var avDataType: String {
        switch self {
        case .jpeg: return kCMMetadataBaseDataType_JPEG as String
        case .png: return kCMMetadataBaseDataType_PNG as String
        }
    }
}

struct ArtworkFile: Sendable {
    let url: URL
    let format: ArtworkFormat
}

/// Busca a capa da faixa corrente do Music via AppleScript. A capa não vem na
/// distributed notification, então é colhida no início da faixa — enquanto ela
/// ainda é a current track. Chamada bloqueante: rodar em queue background.
enum ArtworkFetcher {
    static func fetchCurrentTrackArtwork(tempDir: URL) -> (art: ArtworkFile, trackName: String)? {
        let rawURL = tempDir.appendingPathComponent(".art-\(UUID().uuidString)")
        // Path é gerado por nós (UUID), sem aspas ou caracteres a escapar.
        let script = """
        tell application "Music"
            if not running then return ""
            try
                set t to current track
                set art to artwork 1 of t
                set fmt to (format of art) as text
                set d to raw data of art
                set tname to name of t
            on error
                return ""
            end try
        end tell
        set f to open for access POSIX file "\(rawURL.path)" with write permission
        set eof f to 0
        write d to f
        close access f
        return fmt & linefeed & tname
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        func cleanupAndFail() -> (art: ArtworkFile, trackName: String)? {
            try? FileManager.default.removeItem(at: rawURL)
            return nil
        }

        do {
            try process.run()
        } catch {
            return cleanupAndFail()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else { return cleanupAndFail() }

        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2,
              FileManager.default.fileExists(atPath: rawURL.path)
        else { return cleanupAndFail() }

        let format: ArtworkFormat = lines[0].uppercased().contains("JPEG") ? .jpeg : .png
        let finalURL = rawURL.appendingPathExtension(format.fileExtension)
        do {
            try FileManager.default.moveItem(at: rawURL, to: finalURL)
        } catch {
            return cleanupAndFail()
        }
        return (ArtworkFile(url: finalURL, format: format), lines[1])
    }
}
