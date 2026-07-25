import Foundation

/// Divide a tag artist em cantores individuais para as playlists por cantor.
/// Faixa com "X part. Y" entra na playlist de X e na de Y.
struct ArtistSplitter {
    /// Duplas/bandas com "&" no nome que NÃO são dois cantores separados.
    /// Comparação por chave normalizada (caixa/acentos ignorados).
    static let knownDuos: [String] = [
        "Sandy & Junior",
        "Chitãozinho & Xororó",
        "Zezé Di Camargo & Luciano",
        "César Menotti & Fabiano",
        "Guilherme & Santiago",
        "João Bosco & Vinícius",
        "Simon & Garfunkel",
        "Hall & Oates",
    ]

    /// Marcadores de participação que sempre separam cantores. Exigem limites
    /// de palavra para não cortar nomes que contenham as letras por acaso.
    private static let featurePattern =
        #"(?i)\s+(feat\.?|ft\.?|featuring|part\.|participa[çc][ãa]o(\s+especial)?(\s+de)?)\s+"#

    private let keepTogether: Set<String>

    init(extraKeep: [String] = []) {
        keepTogether = Set((Self.knownDuos + extraKeep).map(Self.foldKey))
    }

    func split(_ rawArtist: String) -> [String] {
        let whole = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        if keepTogether.contains(Self.foldKey(whole)) { return [whole] }

        // Marcadores de feat/part viram delimitador comum antes do split de lista.
        let normalized = whole.replacingOccurrences(
            of: Self.featurePattern, with: ";", options: .regularExpression
        )

        var pieces: [String] = []
        for piece in normalized.components(separatedBy: CharacterSet(charactersIn: ",;/")) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // " & " divide, exceto duplas conhecidas. " e " nunca divide:
            // no Brasil é quase sempre nome de dupla (Jorge e Mateus etc.).
            if trimmed.contains(" & "), !keepTogether.contains(Self.foldKey(trimmed)) {
                pieces += trimmed.components(separatedBy: " & ")
            } else {
                pieces.append(trimmed)
            }
        }

        // Dedupe mantendo a primeira grafia — APFS é case-insensitive, então
        // "Anitta" e "ANITTA" não podem virar dois arquivos de playlist.
        var seen = Set<String>()
        var result: [String] = []
        for piece in pieces {
            let cleaned = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if seen.insert(Self.foldKey(cleaned)).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    /// Chave de comparação insensível a caixa e acentos (pt-BR).
    static func foldKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "pt_BR")
            )
    }
}
