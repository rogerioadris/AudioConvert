import ArgumentParser

struct AudioConvertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "AudioConvert",
        abstract: "Grava o áudio do Apple Music por faixa e organiza a biblioteca MP3.",
        subcommands: [RecordCommand.self, PlaylistCommand.self, TagsCommand.self],
        // Compat: sem subcomando explícito, `AudioConvert --monitor` continua gravando.
        defaultSubcommand: RecordCommand.self
    )
}

AudioConvertCommand.main()
