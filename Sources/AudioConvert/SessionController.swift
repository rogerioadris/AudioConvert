import Foundation

/// Máquina de estados da sessão de gravação: segmenta a captura por faixa a
/// partir dos eventos do player e despacha as conversões para background.
/// Todos os eventos chegam na main queue (observers e teclado), então o
/// estado é confinado a ela.
final class SessionController {
    private let recorder: ProcessTapRecorder
    private let exporter: AlacExporter
    private let mp3Encoder: Mp3Encoder
    private let organizer: LibraryOrganizer
    private let outputDir: URL
    private let conversionQueue = DispatchQueue(
        label: "audioconvert.convert", qos: .utility
    )
    // Só roda o osascript bloqueante da capa; estado continua na main.
    private let artworkQueue = DispatchQueue(
        label: "audioconvert.artwork", qos: .utility
    )

    private var currentTrack: TrackMetadata?
    private var currentTempURL: URL?
    private var currentArtwork: ArtworkFile?
    private var paused = false

    /// Gravações abaixo disso são descartadas mesmo sem duração da faixa.
    static let minimumSeconds = 5.0

    init(
        recorder: ProcessTapRecorder, exporter: AlacExporter,
        mp3Encoder: Mp3Encoder, organizer: LibraryOrganizer, outputDir: URL
    ) {
        self.recorder = recorder
        self.exporter = exporter
        self.mp3Encoder = mp3Encoder
        self.organizer = organizer
        self.outputDir = outputDir
    }

    func handle(_ event: PlayerEvent) {
        switch event {
        case .playing(let metadata):
            if let current = currentTrack, current.sameIdentity(as: metadata) {
                // Mesma faixa: retomada de pause ou seek — arquivo segue aberto.
                if paused {
                    paused = false
                    Log.info("▶ Retomado: \(metadata.displayName)")
                }
                return
            }
            rotate(to: metadata)
        case .paused:
            if currentTrack != nil, !paused {
                paused = true
                Log.info("⏸ Pausado")
            }
        case .stopped:
            finalizeCurrent()
        }
    }

    /// Finaliza a faixa corrente e drena a fila de conversões pendentes.
    func shutdownAndWait() {
        finalizeCurrent()
        conversionQueue.sync {}
    }

    private func rotate(to metadata: TrackMetadata) {
        finalizeCurrent()

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let tempURL = outputDir.appendingPathComponent(".rec-\(timestamp).caf")
        do {
            try recorder.startFile(url: tempURL)
        } catch {
            Log.warn("Falha ao iniciar gravação de \(metadata.displayName): \(error)")
            return
        }
        currentTrack = metadata
        currentTempURL = tempURL
        currentArtwork = nil
        paused = false
        Log.info("● Gravando: \(metadata.displayName)")
        fetchArtwork(for: metadata)
    }

    /// A capa só existe via AppleScript enquanto a faixa é a current track,
    /// então é buscada no início da gravação, em background.
    private func fetchArtwork(for metadata: TrackMetadata) {
        let outputDir = self.outputDir
        artworkQueue.async { [weak self] in
            let result = ArtworkFetcher.fetchCurrentTrackArtwork(tempDir: outputDir)
            DispatchQueue.main.async {
                guard let self, let result,
                      let current = self.currentTrack,
                      current.sameIdentity(as: metadata),
                      result.trackName == metadata.name
                else {
                    // Faixa já trocou (skip rápido) — capa não é mais desta gravação.
                    if let result {
                        try? FileManager.default.removeItem(at: result.art.url)
                    }
                    return
                }
                self.currentArtwork = result.art
            }
        }
    }

    private func finalizeCurrent() {
        guard let tempURL = currentTempURL, let metadata = currentTrack else { return }
        let (frames, wasSilent) = recorder.closeFile()
        let artwork = currentArtwork
        currentTempURL = nil
        currentTrack = nil
        currentArtwork = nil
        paused = false

        if wasSilent {
            Log.warn(
                "\(metadata.displayName): gravação saiu em silêncio digital "
                    + "(permissão de captura ausente ou faixa DRM)."
            )
        }

        let recordedSeconds = recorder.sampleRate > 0
            ? Double(frames) / recorder.sampleRate
            : 0
        // Sem duração conhecida a regra dos 90% não pega fragmentos (ex.: um
        // clique de play/stop que vira "Faixa desconhecida" de 1s).
        if recordedSeconds < Self.minimumSeconds {
            try? FileManager.default.removeItem(at: tempURL)
            if let artwork { try? FileManager.default.removeItem(at: artwork.url) }
            Log.info("✗ Descartada (curta demais): \(metadata.displayName) (\(Int(recordedSeconds))s)")
            return
        }
        if let totalMS = metadata.totalTimeMS, totalMS > 0,
           recordedSeconds < (Double(totalMS) / 1000.0) * 0.9 {
            try? FileManager.default.removeItem(at: tempURL)
            if let artwork { try? FileManager.default.removeItem(at: artwork.url) }
            Log.info(
                "✗ Parcial descartada: \(metadata.displayName) "
                    + "(\(Int(recordedSeconds))s de \(totalMS / 1000)s)"
            )
            return
        }

        let exporter = self.exporter
        let encoder = self.mp3Encoder
        let organizer = self.organizer
        conversionQueue.async {
            defer {
                if let artwork { try? FileManager.default.removeItem(at: artwork.url) }
            }
            guard let alacURL = exporter.export(
                tempURL: tempURL, metadata: metadata, artwork: artwork
            ) else { return }
            do {
                let destination = try organizer.destinationURL(for: metadata)
                try encoder.encode(
                    alacURL: alacURL, metadata: metadata,
                    artwork: artwork, to: destination
                )
                Log.info("♫ MP3: \(destination.path)")
            } catch {
                Log.warn("MP3 falhou para \(metadata.displayName): \(error). ALAC preservado.")
            }
        }
    }
}
