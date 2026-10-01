import ArgumentParser
import Foundation

/// Limpa e completa as tags dos MP3s da biblioteca e os reposiciona segundo
/// o LibraryOrganizer. Por padrão só mostra o plano; --apply grava.
struct TagsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tags",
        abstract: "Limpa/completa tags dos MP3s (opcionalmente pela iTunes API) e reorganiza a biblioteca."
    )

    @Option(name: .shortAndLong, help: "Diretório de saída das gravações.")
    var output: String = "./Recordings"

    @Option(name: .shortAndLong, help: "Pasta da biblioteca MP3. Padrão: <output>/Biblioteca.")
    var library: String?

    @Flag(help: "Completa faixa, ano, artista do álbum e capa pela iTunes Search API (envia artista/título à Apple).")
    var fetch = false

    @Option(help: "Loja da iTunes API usada na busca (código de país).")
    var country = "BR"

    @Flag(help: "Grava as mudanças. Sem isso, só mostra o que seria feito.")
    var apply = false

    @Option(name: .customLong("keep"), help: "Dupla com \"&\" que não conta como parceria (repetível).")
    var keep: [String] = []

    func run() throws {
        guard let ffmpegURL = Mp3Encoder.locate(), let ffprobeURL = FfprobeReader.locate() else {
            throw RuntimeError("ffmpeg/ffprobe não encontrados. Instale com: brew install ffmpeg")
        }
        let outputDir = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        let libraryDir = library.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? outputDir.appendingPathComponent("Biblioteca")
        guard FileManager.default.fileExists(atPath: libraryDir.path) else {
            throw RuntimeError("Biblioteca não encontrada em \(libraryDir.path)")
        }

        let probe = FfprobeReader(ffprobeURL: ffprobeURL)
        let files = LibraryScanner(root: libraryDir, probe: probe).mp3Files()
        guard !files.isEmpty else { throw RuntimeError("Nenhum MP3 em \(libraryDir.path)") }

        // 1. Tags atuais.
        var items: [Item] = []
        for file in files {
            let info = try probe.read(file)
            items.append(Item(file: file, info: info, metadata: TrackMetadata(
                name: info.title, artist: info.artist, album: info.album, totalTimeMS: nil,
                albumArtist: info.albumArtist, trackNumber: info.trackNumber,
                trackCount: info.trackCount, discNumber: info.discNumber,
                discCount: info.discCount, genre: info.genre, year: info.year
            )))
        }

        // 2. Catálogo: só preenche o que falta; artista do álbum é corrigido
        // porque o Music costuma repetir nele o artista da faixa (feat).
        if fetch {
            let catalog = ItunesCatalog(country: country)
            let splitter = ArtistSplitter(extraKeep: keep)
            for index in items.indices {
                let meta = items[index].metadata
                Log.info("♫ buscando \(index + 1)/\(items.count): \(meta.displayName)")
                let mainArtist = splitter.split(meta.artist).first ?? meta.artist
                do {
                    items[index].match = try catalog.findTrack(
                        artist: mainArtist, title: meta.name, album: meta.album
                    )
                } catch {
                    Log.warn("busca falhou para \(meta.displayName): \(error)")
                }
            }
            let ids = Array(Set(items.compactMap { $0.match?.collectionId })).sorted()
            let albums = ids.isEmpty ? [:] : try catalog.albums(ids: ids)

            for index in items.indices {
                guard let match = items[index].match else { continue }
                var meta = items[index].metadata
                let album = albums[match.collectionId]
                if meta.trackNumber == nil {
                    meta.trackNumber = match.trackNumber
                    meta.trackCount = match.trackCount
                }
                if meta.discNumber == nil {
                    meta.discNumber = match.discNumber
                    meta.discCount = match.discCount
                }
                if meta.year == nil { meta.year = album?.year }
                if meta.genre.isEmpty { meta.genre = match.genre }
                let albumArtist = album?.artist ?? match.albumArtist
                if !albumArtist.isEmpty { meta.albumArtist = albumArtist }
                items[index].metadata = meta
            }
        }

        // 3. Plano.
        let organizer = LibraryOrganizer(root: libraryDir, keep: keep)
        let rootPath = libraryDir.standardizedFileURL.path + "/"
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
        }

        var moves = 0, covers = 0, unmatched: [String] = []
        for index in items.indices {
            let item = items[index]
            let destination = organizer.plannedURL(for: item.metadata)
            items[index].destination = destination
            let willFetchCover = !item.info.hasCover && item.match?.artworkURL != nil

            var changes = item.changes()
            if willFetchCover { changes.append("capa") }
            Log.info("• \(relative(item.file))")
            if destination.standardizedFileURL.path != item.file.standardizedFileURL.path {
                Log.info("    → \(relative(destination))")
                moves += 1
            }
            if !changes.isEmpty { Log.info("    + \(changes.joined(separator: ", "))") }
            if fetch, item.match == nil {
                Log.info("    ? sem correspondência exata no catálogo")
                unmatched.append(relative(item.file))
            }
            if willFetchCover { covers += 1 }
        }
        Log.info("")
        Log.info("\(items.count) faixas · \(moves) a mover · \(covers) capas a baixar"
            + (fetch ? " · \(unmatched.count) sem correspondência" : "")
            + " · tags herdadas do M4A removidas de todas")

        guard apply else {
            Log.info("Nada gravado (dry-run). Rode de novo com --apply para aplicar.")
            return
        }

        // 4. Aplicação: reescreve tags (áudio copiado) já no destino final.
        let encoder = Mp3Encoder(ffmpegURL: ffmpegURL)
        let catalog = ItunesCatalog(country: country)
        let fm = FileManager.default
        var written = 0
        for item in items {
            guard let planned = item.destination else { continue }
            let samePath = planned.standardizedFileURL.path == item.file.standardizedFileURL.path
            if !samePath, fm.fileExists(atPath: planned.path) {
                Log.warn("destino já existe, pulando: \(relative(planned))")
                continue
            }
            var artwork: ArtworkFile?
            if !item.info.hasCover, let url = item.match?.artworkURL {
                do {
                    artwork = try catalog.downloadArtwork(url, tempDir: libraryDir)
                } catch {
                    Log.warn("capa falhou para \(item.metadata.displayName): \(error)")
                }
            }
            defer { if let artwork { try? fm.removeItem(at: artwork.url) } }
            do {
                let destination = try organizer.destinationURL(for: item.metadata)
                try encoder.retag(
                    mp3URL: item.file, metadata: item.metadata,
                    artwork: artwork, to: destination
                )
                if !samePath { try fm.removeItem(at: item.file) }
                written += 1
            } catch {
                Log.warn("falhou em \(relative(item.file)): \(error)")
            }
        }
        Self.removeEmptyDirectories(in: libraryDir)
        Log.info("✔ \(written)/\(items.count) faixas gravadas. Rode `playlist` para atualizar as playlists.")
    }

    private struct Item {
        let file: URL
        let info: FfprobeReader.ProbeInfo
        var metadata: TrackMetadata
        var match: ItunesCatalog.Match? = nil
        var destination: URL? = nil

        /// Campos que mudam em relação ao arquivo, para o relatório.
        func changes() -> [String] {
            var result: [String] = []
            if metadata.trackNumber != info.trackNumber, let number = metadata.trackNumber {
                result.append("faixa \(number)/\(metadata.trackCount.map(String.init) ?? "?")")
            }
            if metadata.discNumber != info.discNumber, let disc = metadata.discNumber {
                result.append("disco \(disc)/\(metadata.discCount.map(String.init) ?? "?")")
            }
            if metadata.year != info.year, let year = metadata.year {
                result.append("ano \(year)")
            }
            if metadata.genre != info.genre { result.append("gênero \(metadata.genre)") }
            if metadata.effectiveAlbumArtist != info.albumArtist {
                result.append("artista do álbum: \(info.albumArtist) → \(metadata.effectiveAlbumArtist)")
            }
            return result
        }
    }

    /// Remove pastas que ficaram vazias (ignorando .DS_Store), de baixo pra cima.
    private static func removeEmptyDirectories(in root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var directories: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(item)
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            if contents.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: directory)
            }
        }
    }
}
