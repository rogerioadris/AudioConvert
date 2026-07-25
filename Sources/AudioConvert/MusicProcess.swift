import AppKit
import CoreAudio
import Foundation

enum MusicProcess {
    static let bundleID = "com.apple.Music"

    /// Localiza o processo do Apple Music e traduz o PID para o objeto de
    /// áudio do Core Audio usado pelo process tap.
    static func findAudioObject() throws -> AudioObjectID {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first
        else {
            throw RuntimeError("Apple Music não está aberto. Abra o app Música e rode novamente.")
        }

        var pid = app.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else {
            throw RuntimeError("Falha ao localizar o objeto de áudio do Music (status \(status)).")
        }
        return object
    }
}
