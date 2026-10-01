import Foundation

/// Consulta a iTunes Search API (pública, sem chave) para completar tags:
/// número de faixa, ano do álbum, artista do álbum e capa.
/// Doc: https://performance-partners.apple.com/search-api
struct ItunesCatalog {
    struct Match {
        var trackNumber: Int?
        var trackCount: Int?
        var discNumber: Int?
        var discCount: Int?
        var genre: String
        var albumArtist: String
        var collectionId: Int
        var artworkURL: URL?
    }

    struct Album {
        var artist: String
        var year: Int?
    }

    let country: String
    /// Capa pedida ao CDN da Apple nesse tamanho (o original costuma ir a 3000).
    var artworkSize = 1400

    /// A API limita a ~20 chamadas/min por IP; espaçar evita 403/429.
    private static let requestInterval: TimeInterval = 3

    /// Faixa do catálogo com mesmo título E mesmo álbum (caixa/acentos
    /// ignorados). Sem as duas coincidências não arrisca: devolve nil.
    func findTrack(artist: String, title: String, album: String) throws -> Match? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(artist) \(title)"),
            .init(name: "entity", value: "song"),
            .init(name: "country", value: country),
            .init(name: "limit", value: "50"),
        ]
        let results = try fetchResults(components.url!)
        let wantedTitle = Self.matchKey(title)
        let wantedAlbum = Self.matchKey(album)
        guard let hit = results.first(where: {
            Self.matchKey($0["trackName"] as? String ?? "") == wantedTitle
                && Self.matchKey($0["collectionName"] as? String ?? "") == wantedAlbum
        }), let collectionId = hit["collectionId"] as? Int else { return nil }

        let artwork = (hit["artworkUrl100"] as? String).flatMap {
            URL(string: $0.replacingOccurrences(
                of: "100x100bb", with: "\(artworkSize)x\(artworkSize)bb"
            ))
        }
        return Match(
            trackNumber: hit["trackNumber"] as? Int,
            trackCount: hit["trackCount"] as? Int,
            discNumber: hit["discNumber"] as? Int,
            discCount: hit["discCount"] as? Int,
            genre: hit["primaryGenreName"] as? String ?? "",
            // collectionArtistName só vem quando difere do artista da faixa
            // (ex.: feat dentro do álbum de outro cantor).
            albumArtist: hit["collectionArtistName"] as? String
                ?? hit["artistName"] as? String ?? "",
            collectionId: collectionId,
            artworkURL: artwork
        )
    }

    /// Lookup em lote dos álbuns: o releaseDate da busca é o da faixa, que
    /// varia dentro do mesmo álbum; o ano certo é o do álbum.
    func albums(ids: [Int]) throws -> [Int: Album] {
        var result: [Int: Album] = [:]
        // URL fica curta o bastante com lotes de 100 ids.
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = ids[start..<min(start + 100, ids.count)]
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                .init(name: "id", value: chunk.map(String.init).joined(separator: ",")),
                .init(name: "country", value: country),
            ]
            for item in try fetchResults(components.url!) {
                guard let id = item["collectionId"] as? Int else { continue }
                let year = (item["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }
                result[id] = Album(artist: item["artistName"] as? String ?? "", year: year)
            }
        }
        return result
    }

    /// Baixa a capa para um arquivo temporário (JPEG, como o CDN entrega).
    func downloadArtwork(_ url: URL, tempDir: URL) throws -> ArtworkFile {
        let data = try get(url)
        let file = tempDir.appendingPathComponent(".art-\(UUID().uuidString).jpg")
        try data.write(to: file)
        return ArtworkFile(url: file, format: .jpeg)
    }

    private func fetchResults(_ url: URL) throws -> [[String: Any]] {
        let data = try get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else { throw RuntimeError("Resposta inesperada da iTunes API") }
        return results
    }

    /// GET síncrono com espaçamento global e uma nova tentativa em 403/429
    /// (é assim que a API sinaliza limite de taxa).
    private func get(_ url: URL) throws -> Data {
        for attempt in 1...3 {
            Self.throttle()
            let (data, status) = try Self.syncGet(url)
            if status == 200 { return data }
            if (status == 403 || status == 429), attempt < 3 {
                Log.warn("iTunes API limitou (HTTP \(status)) — aguardando 60s…")
                Thread.sleep(forTimeInterval: 60)
                continue
            }
            throw RuntimeError("HTTP \(status) em \(url.host ?? "")")
        }
        throw RuntimeError("iTunes API indisponível")
    }

    nonisolated(unsafe) private static var lastRequest = Date.distantPast

    private static func throttle() {
        let wait = requestInterval - Date().timeIntervalSince(lastRequest)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        lastRequest = Date()
    }

    private static func syncGet(_ url: URL) throws -> (Data, Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var output: (Data, Int)?
        var failure: Error?
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error {
                failure = error
            } else {
                output = (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure { throw failure }
        return output!
    }

    /// Comparação insensível a caixa, acentos e espaços repetidos.
    static func matchKey(_ value: String) -> String {
        ArtistSplitter.foldKey(value)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
