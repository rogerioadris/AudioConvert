import AVFoundation
import Foundation

/// Converte o CAF temporário (PCM) para ALAC em .m4a, grava as tags da faixa
/// e move para o nome final "Artista - Título.m4a".
struct AlacExporter {
    let outputDir: URL

    func export(tempURL: URL, metadata: TrackMetadata, partial: Bool) {
        let baseName = metadata.sanitizedFileName + (partial ? " (partial)" : "")
        let destination = uniqueURL(baseName: baseName)
        let converted = outputDir.appendingPathComponent(".conv-\(UUID().uuidString).m4a")

        do {
            try convert(from: tempURL, to: converted)
        } catch {
            Log.warn(
                "Conversão falhou para \(metadata.displayName): \(error). "
                    + "PCM preservado em \(tempURL.lastPathComponent)"
            )
            return
        }

        do {
            try tag(converted, to: destination, metadata: metadata)
            try? FileManager.default.removeItem(at: converted)
        } catch {
            Log.warn("Tags falharam para \(metadata.displayName): \(error). Salvando sem tags.")
            do {
                try FileManager.default.moveItem(at: converted, to: destination)
            } catch {
                Log.warn("Falha ao mover arquivo final: \(error)")
                return
            }
        }

        try? FileManager.default.removeItem(at: tempURL)
        Log.info("✔ Salvo: \(destination.lastPathComponent)")
    }

    private func convert(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey: 24,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw RuntimeError("Falha ao alocar buffer de conversão.")
        }
        // Ler além do EOF lança erro em algumas versões do AVAudioFile;
        // controlar pelo framePosition evita o read extra.
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    /// Reexporta em passthrough (sem reencodar) só para embutir as tags.
    private func tag(_ source: URL, to destination: URL, metadata: TrackMetadata) throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RuntimeError("Falha ao criar sessão de export.")
        }
        session.metadata = Self.metadataItems(metadata)

        let semaphore = DispatchSemaphore(value: 0)
        var exportError: Error?
        Task {
            do {
                try await session.export(to: destination, as: .m4a)
            } catch {
                exportError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let exportError { throw exportError }
    }

    private static func metadataItems(_ metadata: TrackMetadata) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: String) {
            guard !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        add(.iTunesMetadataSongName, metadata.name)
        add(.iTunesMetadataArtist, metadata.artist)
        add(.iTunesMetadataAlbum, metadata.album)
        return items
    }

    private func uniqueURL(baseName: String) -> URL {
        let name = baseName.isEmpty ? "Gravacao" : baseName
        var candidate = outputDir.appendingPathComponent("\(name).m4a")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDir.appendingPathComponent("\(name) (\(counter)).m4a")
            counter += 1
        }
        return candidate
    }
}
