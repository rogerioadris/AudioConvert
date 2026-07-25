import AVFoundation
import Foundation

/// Converte o CAF temporário (PCM) para ALAC em .m4a, grava as tags da faixa
/// e move para o nome final "Artista - Título.m4a".
struct AlacExporter {
    let outputDir: URL

    /// Retorna a URL do ALAC final no sucesso (mesmo no fallback sem tags);
    /// nil se a conversão falhou.
    @discardableResult
    func export(tempURL: URL, metadata: TrackMetadata, artwork: ArtworkFile?) -> URL? {
        let destination = uniqueURL(baseName: metadata.sanitizedFileName)
        let converted = outputDir.appendingPathComponent(".conv-\(UUID().uuidString).m4a")

        do {
            try convert(from: tempURL, to: converted)
        } catch {
            Log.warn(
                "Conversão falhou para \(metadata.displayName): \(error). "
                    + "PCM preservado em \(tempURL.lastPathComponent)"
            )
            return nil
        }

        do {
            try tag(converted, to: destination, metadata: metadata, artwork: artwork)
            try? FileManager.default.removeItem(at: converted)
        } catch {
            Log.warn("Tags falharam para \(metadata.displayName): \(error). Salvando sem tags.")
            do {
                try FileManager.default.moveItem(at: converted, to: destination)
            } catch {
                Log.warn("Falha ao mover arquivo final: \(error)")
                return nil
            }
        }

        try? FileManager.default.removeItem(at: tempURL)
        Log.info("✔ Salvo: \(destination.lastPathComponent)")
        return destination
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
    private func tag(
        _ source: URL, to destination: URL, metadata: TrackMetadata, artwork: ArtworkFile?
    ) throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RuntimeError("Falha ao criar sessão de export.")
        }
        session.metadata = Self.metadataItems(metadata, artwork: artwork)

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

    private static func metadataItems(
        _ metadata: TrackMetadata, artwork: ArtworkFile?
    ) -> [AVMetadataItem] {
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
        add(.iTunesMetadataAlbumArtist, metadata.albumArtist)
        add(.iTunesMetadataUserGenre, metadata.genre)
        if let year = metadata.year {
            add(.iTunesMetadataReleaseDate, String(year))
        }

        // trkn/disk são átomos binários (pares UInt16 big-endian), não strings.
        func addPairAtom(_ identifier: AVMetadataIdentifier, _ number: Int?, _ count: Int?, trailingPad: Bool) {
            guard let number else { return }
            var bytes: [UInt8] = [0, 0]
            for value in [number, count ?? 0] {
                let clamped = UInt16(clamping: value)
                bytes += [UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
            }
            if trailingPad { bytes += [0, 0] }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = Data(bytes) as NSData
            item.dataType = kCMMetadataBaseDataType_RawData as String
            items.append(item)
        }
        addPairAtom(.iTunesMetadataTrackNumber, metadata.trackNumber, metadata.trackCount, trailingPad: true)
        addPairAtom(.iTunesMetadataDiscNumber, metadata.discNumber, metadata.discCount, trailingPad: false)

        if let artwork, let data = try? Data(contentsOf: artwork.url) {
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = data as NSData
            item.dataType = artwork.format.avDataType
            items.append(item)
        }
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
