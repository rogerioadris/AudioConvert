import Foundation

/// Uma faixa da biblioteca, já com tags lidas do arquivo.
struct LibraryTrack: Sendable {
    var relativePath: String  // "Álbum/01 - Título.mp3", relativo à raiz da Biblioteca
    var title: String
    var artist: String  // tag crua, antes de dividir por cantor
    var album: String
    var durationSeconds: Int  // -1 = desconhecida
}

/// Percorre a Biblioteca (pastas de álbum com MP3s) e lê as tags de cada faixa.
struct LibraryScanner {
    let root: URL
    let probe: FfprobeReader

    func scan() throws -> [LibraryTrack] {
        let fm = FileManager.default
        var mp3s: [URL] = []
        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]  // cobre temps .enc-*/.pl-*
        )
        while let item = enumerator?.nextObject() as? URL {
            // Playlists/ não é álbum — pular para não listar playlists como faixas.
            if item.lastPathComponent == "Playlists", item.hasDirectoryPath {
                enumerator?.skipDescendants()
                continue
            }
            if item.pathExtension.lowercased() == "mp3" {
                mp3s.append(item)
            }
        }

        let rootPath = root.standardizedFileURL.path
        var tracks: [LibraryTrack] = []
        tracks.reserveCapacity(mp3s.count)
        for (index, mp3) in mp3s.enumerated() {
            if mp3s.count > 20, (index + 1) % 20 == 0 {
                Log.info("♫ lendo tags… \(index + 1)/\(mp3s.count)")
            }

            var relative = mp3.standardizedFileURL.path
            if relative.hasPrefix(rootPath + "/") {
                relative = String(relative.dropFirst(rootPath.count + 1))
            }

            var info: FfprobeReader.ProbeInfo
            do {
                info = try probe.read(mp3)
            } catch {
                Log.warn("sem tags legíveis: \(relative) — usando nome do arquivo")
                info = .init(title: "", artist: "", album: "", durationSeconds: -1)
            }

            if info.title.isEmpty {
                info.title = Self.titleFromFileName(mp3.deletingPathExtension().lastPathComponent)
            }
            if info.album.isEmpty {
                info.album = mp3.deletingLastPathComponent().lastPathComponent
            }
            if info.artist.isEmpty {
                Log.warn("faixa sem artista (entra só na playlist geral): \(relative)")
            }

            tracks.append(LibraryTrack(
                relativePath: relative,
                title: info.title,
                artist: info.artist,
                album: info.album,
                durationSeconds: info.durationSeconds
            ))
        }

        // Álbum, depois nome de arquivo numérico-consciente ("2 -" antes de "10 -";
        // o nome já embute disco/faixa via prefixo [D-]NN, então nada de tag aqui).
        tracks.sort { a, b in
            let album = a.album.localizedCaseInsensitiveCompare(b.album)
            if album != .orderedSame { return album == .orderedAscending }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }
        return tracks
    }

    /// Remove o prefixo "NN - " ou "D-NN - " gerado pelo LibraryOrganizer.
    static func titleFromFileName(_ name: String) -> String {
        if let range = name.range(of: #"^\d+(-\d+)? - "#, options: .regularExpression) {
            return String(name[range.upperBound...])
        }
        return name
    }
}
