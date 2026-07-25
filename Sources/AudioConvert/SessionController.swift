import Foundation

/// Máquina de estados da sessão de gravação: segmenta a captura por faixa a
/// partir dos eventos do player e despacha as conversões para background.
/// Todos os eventos chegam na main queue (observers e teclado), então o
/// estado é confinado a ela.
final class SessionController {
    private let recorder: ProcessTapRecorder
    private let exporter: AlacExporter
    private let outputDir: URL
    private let conversionQueue = DispatchQueue(
        label: "audioconvert.convert", qos: .utility
    )

    private var currentTrack: TrackMetadata?
    private var currentTempURL: URL?
    private var paused = false

    init(recorder: ProcessTapRecorder, exporter: AlacExporter, outputDir: URL) {
        self.recorder = recorder
        self.exporter = exporter
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
        paused = false
        Log.info("● Gravando: \(metadata.displayName)")
    }

    private func finalizeCurrent() {
        guard let tempURL = currentTempURL, let metadata = currentTrack else { return }
        let (frames, wasSilent) = recorder.closeFile()
        currentTempURL = nil
        currentTrack = nil
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
        var partial = false
        if let totalMS = metadata.totalTimeMS, totalMS > 0 {
            partial = recordedSeconds < (Double(totalMS) / 1000.0) * 0.9
        }

        let exporter = self.exporter
        conversionQueue.async {
            exporter.export(tempURL: tempURL, metadata: metadata, partial: partial)
        }
    }
}
