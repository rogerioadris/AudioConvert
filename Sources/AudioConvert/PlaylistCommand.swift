import ArgumentParser
import Foundation

/// Gera playlists M3U8 a partir dos MP3s da Biblioteca: uma geral com tudo
/// e uma por cantor (faixa com 2+ cantores entra na playlist de cada um).
struct PlaylistCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playlist",
        abstract: "Gera playlists M3U8 (geral + por cantor) a partir da biblioteca MP3."
    )

    @Option(name: .shortAndLong, help: "Diretório de saída das gravações.")
    var output: String = "./Recordings"

    @Option(name: .shortAndLong, help: "Pasta da biblioteca MP3 (Álbuns/ e Singles e Parcerias/). Padrão: <output>/Biblioteca.")
    var library: String?

    @Option(name: .customLong("keep"), help: "Dupla com \"&\" que não deve ser dividida (repetível). Ex: --keep \"Sandy & Junior\".")
    var keep: [String] = []

    func run() throws {
        guard let ffprobeURL = FfprobeReader.locate() else {
            throw RuntimeError(
                "ffprobe não encontrado (PATH, /opt/homebrew/bin, /usr/local/bin). "
                    + "Instale com: brew install ffmpeg"
            )
        }

        let outputDir = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        let libraryDir = library.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? outputDir.appendingPathComponent("Biblioteca")
        guard FileManager.default.fileExists(atPath: libraryDir.path) else {
            throw RuntimeError("Biblioteca não encontrada em \(libraryDir.path)")
        }

        Log.info("♫ Escaneando biblioteca: \(libraryDir.path)")
        let scanner = LibraryScanner(root: libraryDir, probe: FfprobeReader(ffprobeURL: ffprobeURL))
        let tracks = try scanner.scan()
        guard !tracks.isEmpty else {
            throw RuntimeError("Nenhum MP3 encontrado em \(libraryDir.path)")
        }

        // Agrupa por cantor com chave normalizada (caixa/acentos), guardando a
        // primeira grafia vista — APFS case-insensitive não tolera dois arquivos.
        let splitter = ArtistSplitter(extraKeep: keep)
        var artistNames: [String: String] = [:]
        var artistTracks: [String: [LibraryTrack]] = [:]
        for track in tracks {
            for artist in splitter.split(track.artist) {
                let key = ArtistSplitter.foldKey(artist)
                if artistNames[key] == nil { artistNames[key] = artist }
                artistTracks[key, default: []].append(track)
            }
        }

        let writer = PlaylistWriter(playlistsDir: libraryDir.appendingPathComponent("Playlists"))
        try writer.removeExistingPlaylists()
        try writer.write(name: "Biblioteca", tracks: tracks)
        for key in artistTracks.keys.sorted() {
            try writer.write(name: artistNames[key]!, tracks: artistTracks[key]!)
        }

        Log.info("✔ \(tracks.count) faixas, \(artistTracks.count) cantores, \(artistTracks.count + 1) playlists em \(libraryDir.appendingPathComponent("Playlists").path)")
    }
}
