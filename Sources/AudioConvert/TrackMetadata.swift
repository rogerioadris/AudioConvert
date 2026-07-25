import Foundation

struct TrackMetadata: Sendable {
    var name: String
    var artist: String
    var album: String
    var totalTimeMS: Int?
    var albumArtist: String = ""
    var trackNumber: Int? = nil
    var trackCount: Int? = nil
    var discNumber: Int? = nil
    var discCount: Int? = nil
    var genre: String = ""
    var year: Int? = nil

    var displayName: String {
        artist.isEmpty ? name : "\(artist) - \(name)"
    }

    /// Album artist para agrupar pastas; coletâneas sem o campo caem no artist.
    var effectiveAlbumArtist: String {
        albumArtist.isEmpty ? artist : albumArtist
    }

    var sanitizedFileName: String {
        Self.sanitizePathComponent(displayName, fallback: "")
    }

    /// Torna um texto seguro como componente de path: "/" e ":" quebram paths
    /// no macOS/Finder; ponto inicial cria pasta oculta; ponto final quebra
    /// volumes SMB/Windows.
    static func sanitizePathComponent(_ raw: String, fallback: String) -> String {
        var value = raw
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while value.hasSuffix(".") {
            value = String(value.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? fallback : value
    }

    func sameIdentity(as other: TrackMetadata) -> Bool {
        name == other.name && artist == other.artist && album == other.album
    }
}
