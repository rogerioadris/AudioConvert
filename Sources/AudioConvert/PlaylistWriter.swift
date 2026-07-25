import Foundation

/// Escreve playlists M3U8 em <Biblioteca>/Playlists, com caminhos relativos
/// "../<Álbum>/faixa.mp3" (M3U resolve relativo ao arquivo da playlist).
struct PlaylistWriter {
    let playlistsDir: URL

    /// Regenerar do zero: apaga só *.m3u8 para sumir com playlists órfãs de
    /// artistas removidos, sem tocar em arquivos alheios do usuário.
    func removeExistingPlaylists() throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: playlistsDir, includingPropertiesForKeys: nil
        ) else { return }
        for item in items where item.pathExtension.lowercased() == "m3u8" {
            try fm.removeItem(at: item)
        }
    }

    /// Escreve uma playlist; devolve a URL final (pode ganhar sufixo " (2)"
    /// se dois nomes sanitizados distintos colidirem).
    @discardableResult
    func write(name: String, tracks: [LibraryTrack]) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: playlistsDir, withIntermediateDirectories: true)

        var content = "#EXTM3U\n"
        for track in tracks {
            let display = track.artist.isEmpty
                ? track.title : "\(track.artist) - \(track.title)"
            content += "#EXTINF:\(track.durationSeconds),\(display)\n"
            content += "../\(track.relativePath)\n"
        }

        let base = TrackMetadata.sanitizePathComponent(name, fallback: "Desconhecido")
        var destination = playlistsDir.appendingPathComponent("\(base).m3u8")
        var attempt = 2
        while fm.fileExists(atPath: destination.path) {
            destination = playlistsDir.appendingPathComponent("\(base) (\(attempt)).m3u8")
            attempt += 1
        }

        // Escreve num temp e move no sucesso — evita playlist truncada no destino.
        let temp = playlistsDir.appendingPathComponent(".pl-\(UUID().uuidString).m3u8")
        do {
            try Data(content.utf8).write(to: temp)
            try fm.moveItem(at: temp, to: destination)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return destination
    }
}
