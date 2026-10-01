import Foundation

/// Resolve o destino do MP3 na biblioteca organizada:
/// - `<root>/Álbuns/<Álbum>/[D-]NN - Título.mp3` — faixa solo de álbum;
/// - `<root>/Singles e Parcerias/Artista - Título.mp3` — single ou faixa com
///   mais de um cantor (feat, dueto), numa pasta plana.
struct LibraryOrganizer: Sendable {
    static let albumsFolder = "Álbuns"
    static let singlesFolder = "Singles e Parcerias"

    let root: URL
    let splitter: ArtistSplitter

    init(root: URL, keep: [String] = []) {
        self.root = root
        self.splitter = ArtistSplitter(extraKeep: keep)
    }

    /// Mesma faixa regravada cai no mesmo caminho — o encoder substitui o
    /// arquivo antigo em vez de criar duplicata " (2)".
    func destinationURL(for metadata: TrackMetadata) throws -> URL {
        let url = plannedURL(for: metadata)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return url
    }

    /// Mesmo destino de `destinationURL`, sem criar a pasta (para dry-run).
    func plannedURL(for metadata: TrackMetadata) -> URL {
        let title = TrackMetadata.sanitizePathComponent(metadata.name, fallback: "Gravacao")
        let directory: URL
        let baseName: String

        if Self.isSingle(album: metadata.album) || splitter.split(metadata.artist).count > 1 {
            directory = root.appendingPathComponent(Self.singlesFolder)
            baseName = TrackMetadata.sanitizePathComponent(metadata.displayName, fallback: title)
        } else {
            let albumDir = TrackMetadata.sanitizePathComponent(
                metadata.album, fallback: "Sem Álbum"
            )
            directory = root
                .appendingPathComponent(Self.albumsFolder)
                .appendingPathComponent(albumDir)
            baseName = Self.numberedName(title: title, metadata: metadata)
        }

        return directory.appendingPathComponent("\(baseName).mp3")
    }

    /// Apple Music marca singles com o sufixo " - Single" no nome do álbum.
    static func isSingle(album: String) -> Bool {
        album.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix(" - single")
    }

    private static func numberedName(title: String, metadata: TrackMetadata) -> String {
        guard let track = metadata.trackNumber else { return title }
        let number = String(format: "%02d", track)
        // Prefixo de disco só quando o álbum tem mais de um.
        let multiDisc = (metadata.discCount ?? 1) > 1 || (metadata.discNumber ?? 1) > 1
        if multiDisc, let disc = metadata.discNumber {
            return "\(disc)-\(number) - \(title)"
        }
        return "\(number) - \(title)"
    }
}
