import Foundation

enum Log {
    static func info(_ message: String) {
        print(message)
        fflush(stdout)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data(("⚠ " + message + "\n").utf8))
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
