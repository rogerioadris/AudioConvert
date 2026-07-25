import Foundation

enum PlayerEvent {
    case playing(TrackMetadata)
    case paused
    case stopped
}

/// Escuta as distributed notifications do Apple Music
/// (`com.apple.Music.playerInfo`) e as traduz para eventos tipados.
/// O Music emite essa notificação em troca de faixa, play, pause, stop e seek.
final class MusicNotifications {
    var onEvent: ((PlayerEvent) -> Void)?

    private var observer: NSObjectProtocol?

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handle(notification)
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    private func handle(_ notification: Notification) {
        guard let info = notification.userInfo,
              let state = info["Player State"] as? String
        else { return }

        switch state {
        case "Playing":
            let metadata = TrackMetadata(
                name: info["Name"] as? String ?? "Faixa desconhecida",
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                totalTimeMS: (info["Total Time"] as? NSNumber)?.intValue
            )
            onEvent?(.playing(metadata))
        case "Paused":
            onEvent?(.paused)
        case "Stopped":
            onEvent?(.stopped)
        default:
            break
        }
    }
}

/// Consulta única do estado atual via AppleScript — usada só na inicialização,
/// para o caso de o Music já estar tocando quando o gravador sobe.
enum MusicScripting {
    static func currentState() -> (metadata: TrackMetadata, playing: Bool)? {
        let script = """
        tell application "Music"
            if not running then return ""
            if player state is stopped then return ""
            set t to current track
            return (name of t) & linefeed & (artist of t) & linefeed & \
        (album of t) & linefeed & ((duration of t) as text) & linefeed & \
        (player state as text)
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty
        else { return nil }

        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 5 else { return nil }

        // "duration as text" usa o separador decimal do locale (vírgula em pt-BR)
        let seconds = Double(lines[3].replacingOccurrences(of: ",", with: "."))
        let metadata = TrackMetadata(
            name: lines[0],
            artist: lines[1],
            album: lines[2],
            totalTimeMS: seconds.map { Int($0 * 1000) }
        )
        let playing = lines[4].lowercased().contains("playing")
            || lines[4].lowercased().contains("reproduzindo")
        return (metadata, playing)
    }
}
