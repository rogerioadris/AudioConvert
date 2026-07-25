import AppKit
import ArgumentParser
import Foundation

struct AudioConvertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "AudioConvert",
        abstract: "Grava o áudio do Apple Music por faixa em ALAC (.m4a), sem capturar outros apps."
    )

    @Option(name: .shortAndLong, help: "Diretório de saída das gravações.")
    var output: String = "./Recordings"

    @Option(name: .shortAndLong, help: "Pasta da biblioteca MP3 organizada (Artista/Álbum). Padrão: <output>/Biblioteca.")
    var library: String?

    @Flag(name: .shortAndLong, help: "Toca o áudio nos alto-falantes durante a gravação (padrão: mudo).")
    var monitor = false

    func run() throws {
        guard let ffmpegURL = Mp3Encoder.locate() else {
            throw RuntimeError(
                "ffmpeg não encontrado (PATH, /opt/homebrew/bin, /usr/local/bin). "
                    + "Instale com: brew install ffmpeg"
            )
        }

        let outputDir = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let libraryDir = library.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? outputDir.appendingPathComponent("Biblioteca")
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        let processObject = try MusicProcess.findAudioObject()
        let recorder = ProcessTapRecorder(processObject: processObject, monitor: monitor)
        try recorder.start()

        let exporter = AlacExporter(outputDir: outputDir)
        let session = SessionController(
            recorder: recorder,
            exporter: exporter,
            mp3Encoder: Mp3Encoder(ffmpegURL: ffmpegURL),
            organizer: LibraryOrganizer(root: libraryDir),
            outputDir: outputDir
        )

        let notifications = MusicNotifications()
        notifications.onEvent = { session.handle($0) }
        notifications.start()

        Log.info("AudioConvert iniciado.")
        Log.info("  Saída:      \(outputDir.path)")
        Log.info("  Biblioteca: \(libraryDir.path)")
        Log.info("  ffmpeg:     \(ffmpegURL.path)")
        Log.info("  Monitor:    \(monitor ? "on (alto-falantes)" : "off (mudo)")")
        Log.info("  Teclas:     [m] monitor on/off   [q] sair")

        // Música já tocando ao iniciar? Começa a gravar já (será parcial).
        if let state = MusicScripting.currentState(), state.playing {
            Log.info("Faixa em andamento detectada — gravação desta faixa será parcial.")
            session.handle(.playing(state.metadata))
        }

        let terminal = TerminalInput()

        let shutdown = {
            Log.info("Encerrando — finalizando faixa corrente e conversões…")
            session.shutdownAndWait()
            recorder.stop()
            notifications.stop()
            terminal.restore()
            Foundation.exit(0)
        }

        // Ctrl+C
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler(handler: shutdown)
        sigintSource.resume()

        terminal.onKey = { key in
            switch key {
            case "m":
                let enabled = !recorder.monitorEnabled
                recorder.setMonitor(enabled)
                Log.info("▲ Monitor: \(enabled ? "on" : "off")")
            case "q":
                shutdown()
            default:
                break
            }
        }
        terminal.start()

        withExtendedLifetime((sigintSource, terminal)) {
            RunLoop.main.run()
        }
    }
}

/// Leitura de teclas em raw mode (sem Enter), com restauração do terminal.
final class TerminalInput {
    var onKey: ((Character) -> Void)?

    private var originalTermios = termios()
    private var rawModeActive = false
    private var source: DispatchSourceRead?

    func start() {
        guard isatty(STDIN_FILENO) == 1 else { return }

        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        rawModeActive = true

        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) == 1 {
                self?.onKey?(Character(UnicodeScalar(byte)))
            }
        }
        source.resume()
        self.source = source
    }

    func restore() {
        if rawModeActive {
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
            rawModeActive = false
        }
        source?.cancel()
        source = nil
    }
}

AudioConvertCommand.main()
