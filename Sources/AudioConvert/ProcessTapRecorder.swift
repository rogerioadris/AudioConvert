import AudioToolbox
import CoreAudio
import Foundation

/// Captura o áudio de um único processo via Core Audio process tap
/// (macOS 14.4+) e grava PCM num arquivo CAF, com rotação de arquivo por
/// faixa sem interromper o fluxo de captura.
final class ProcessTapRecorder {
    private let processObject: AudioObjectID
    private let tapDescription: CATapDescription
    private let ioQueue = DispatchQueue(label: "audioconvert.io")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var streamFormat = AudioStreamBasicDescription()
    private var fileFormat = AudioStreamBasicDescription()

    // Estado do arquivo corrente — acessado apenas na ioQueue.
    private var file: ExtAudioFileRef?
    private var framesWritten: Int64 = 0
    private var sawNonZeroSample = false
    private var warnedSilence = false

    private(set) var monitorEnabled: Bool

    var sampleRate: Double { streamFormat.mSampleRate }

    init(processObject: AudioObjectID, monitor: Bool) {
        self.processObject = processObject
        self.monitorEnabled = monitor

        let description = CATapDescription(
            stereoMixdownOfProcesses: [processObject]
        )
        description.name = "AudioConvert Tap"
        description.isPrivate = true
        description.muteBehavior = monitor
            ? CATapMuteBehavior.unmuted
            : CATapMuteBehavior.muted
        self.tapDescription = description
    }

    func start() throws {
        try buildGraph()
    }

    func stop() {
        ioQueue.sync { closeFileLocked() }
        tearDownGraph()
    }

    /// Fecha o arquivo corrente (se houver) e começa a gravar no novo URL.
    func startFile(url: URL) throws {
        try ioQueue.sync {
            closeFileLocked()
            try openFileLocked(url: url)
        }
    }

    /// Fecha o arquivo corrente e retorna o total de frames gravados nele e
    /// se o arquivo inteiro saiu em silêncio digital.
    @discardableResult
    func closeFile() -> (frames: Int64, wasSilent: Bool) {
        ioQueue.sync {
            let result = (framesWritten, framesWritten > 0 && !sawNonZeroSample)
            closeFileLocked()
            return result
        }
    }

    /// Liga/desliga a saída nos alto-falantes sem parar a gravação.
    func setMonitor(_ enabled: Bool) {
        monitorEnabled = enabled
        tapDescription.muteBehavior = enabled
            ? CATapMuteBehavior.unmuted
            : CATapMuteBehavior.muted

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description: CATapDescription? = tapDescription
        let status = withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectSetPropertyData(
                tapID, &address, 0, nil,
                UInt32(MemoryLayout<CATapDescription?>.size), pointer
            )
        }
        if status != noErr {
            // Atualização ao vivo recusada: recria o grafo com o novo
            // muteBehavior. O arquivo corrente segue aberto (gap de ms).
            tearDownGraph()
            do {
                try buildGraph()
            } catch {
                Log.warn("Falha ao recriar captura após toggle de monitor: \(error)")
            }
        }
    }

    // MARK: - Grafo de captura

    private func buildGraph() throws {
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            throw RuntimeError(
                "Falha ao criar process tap (status \(status)). "
                    + "Verifique a permissão em Ajustes do Sistema → Privacidade e Segurança → "
                    + "Gravação de Tela e Áudio do Sistema."
            )
        }

        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioConvert",
            kAudioAggregateDeviceUIDKey: "com.audioconvert.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]
        // Device de saída padrão como sub-device: fornece o clock do aggregate.
        if let outputUID = Self.defaultOutputDeviceUID() {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputUID]
            ]
        }

        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregateID
        )
        guard status == noErr else {
            throw RuntimeError("Falha ao criar aggregate device (status \(status)).")
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamFormat)
        guard status == noErr, streamFormat.mSampleRate > 0 else {
            throw RuntimeError("Falha ao ler o formato do tap (status \(status)).")
        }
        fileFormat = Self.interleaved(from: streamFormat)

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.writeLocked(inputData)
        }
        guard status == noErr else {
            throw RuntimeError("Falha ao criar IOProc (status \(status)).")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw RuntimeError("Falha ao iniciar captura (status \(status)).")
        }
    }

    private func tearDownGraph() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Arquivo (sempre na ioQueue)

    private func openFileLocked(url: URL) throws {
        var newFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &newFile
        )
        guard status == noErr, let newFile else {
            throw RuntimeError("Falha ao criar arquivo de gravação (status \(status)): \(url.path)")
        }
        var clientFormat = streamFormat
        status = ExtAudioFileSetProperty(
            newFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else {
            ExtAudioFileDispose(newFile)
            throw RuntimeError("Falha ao configurar formato de gravação (status \(status)).")
        }
        file = newFile
        framesWritten = 0
        sawNonZeroSample = false
    }

    private func closeFileLocked() {
        if let file {
            ExtAudioFileDispose(file)
            self.file = nil
        }
    }

    private func writeLocked(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let file else { return }
        let firstBuffer = bufferList.pointee.mBuffers
        let bytesPerFrame = max(streamFormat.mBytesPerFrame, 1)
        let frames = firstBuffer.mDataByteSize / bytesPerFrame
        guard frames > 0 else { return }
        let status = ExtAudioFileWrite(file, frames, bufferList)
        if status == noErr {
            framesWritten += Int64(frames)
        }
        checkSilenceLocked(firstBuffer)
    }

    /// Sem permissão TCC (ou com faixa DRM) o tap entrega zeros sem nenhum
    /// erro de API — este é o único jeito de detectar e avisar o usuário.
    private func checkSilenceLocked(_ buffer: AudioBuffer) {
        guard !warnedSilence else { return }
        if !sawNonZeroSample, let data = buffer.mData {
            let samples = data.assumingMemoryBound(to: Float32.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            var index = 0
            while index < count {
                if samples[index] != 0 {
                    sawNonZeroSample = true
                    break
                }
                index += 64
            }
        }
        if !sawNonZeroSample, framesWritten > Int64(sampleRate * 5) {
            warnedSilence = true
            Log.warn(
                "Captura em SILÊNCIO há 5s — o tap está entregando zeros. Causas prováveis:\n"
                    + "  1) Permissão ausente: Ajustes do Sistema → Privacidade e Segurança → "
                    + "Gravação de Tela e Áudio do Sistema → botão \"+\" → adicione o app do "
                    + "terminal, ative, reinicie o terminal e rode de novo.\n"
                    + "  2) Faixa de streaming da assinatura (DRM) — toque um arquivo local."
            )
        }
    }

    // MARK: - Helpers

    private static func interleaved(
        from format: AudioStreamBasicDescription
    ) -> AudioStreamBasicDescription {
        var result = format
        guard format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 else {
            return result
        }
        result.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
        let bytesPerSample = format.mBitsPerChannel / 8
        result.mBytesPerFrame = bytesPerSample * format.mChannelsPerFrame
        result.mBytesPerPacket = result.mBytesPerFrame * format.mFramesPerPacket
        return result
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String
    }
}
