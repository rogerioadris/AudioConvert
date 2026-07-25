import Foundation

struct TrackMetadata {
    var name: String
    var artist: String
    var album: String
    var totalTimeMS: Int?

    var displayName: String {
        artist.isEmpty ? name : "\(artist) - \(name)"
    }

    // "/" e ":" quebram paths no macOS/Finder
    var sanitizedFileName: String {
        displayName
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    func sameIdentity(as other: TrackMetadata) -> Bool {
        name == other.name && artist == other.artist && album == other.album
    }
}
