import Foundation

/// Resolve o destino do MP3 na biblioteca organizada:
/// `<root>/<Album Artist>/<Álbum>/[D-]NN - Título.mp3`.
struct LibraryOrganizer: Sendable {
    let root: URL

    func destinationURL(for metadata: TrackMetadata) throws -> URL {
        let artistDir = TrackMetadata.sanitizePathComponent(
            metadata.effectiveAlbumArtist, fallback: "Unknown Artist"
        )
        let albumDir = TrackMetadata.sanitizePathComponent(
            metadata.album, fallback: "Unknown Album"
        )
        let directory = root
            .appendingPathComponent(artistDir)
            .appendingPathComponent(albumDir)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let title = TrackMetadata.sanitizePathComponent(metadata.name, fallback: "Gravacao")
        var baseName = title
        if let track = metadata.trackNumber {
            let number = String(format: "%02d", track)
            // Prefixo de disco só quando o álbum tem mais de um.
            let multiDisc = (metadata.discCount ?? 1) > 1 || (metadata.discNumber ?? 1) > 1
            if multiDisc, let disc = metadata.discNumber {
                baseName = "\(disc)-\(number) - \(title)"
            } else {
                baseName = "\(number) - \(title)"
            }
        }

        var candidate = directory.appendingPathComponent("\(baseName).mp3")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(counter)).mp3")
            counter += 1
        }
        return candidate
    }
}
