import Foundation
import SwiftTerm

private final class RenderDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class TerminalRenderer {
    private let cols: Int
    private let rows: Int

    init(cols: Int = 160, rows: Int = 50) {
        self.cols = cols
        self.rows = rows
    }

    func render(_ raw: String) -> String {
        let delegate = RenderDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, convertEol: true)
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.feed(text: raw)
        return extractScreenText(from: terminal)
    }

    private func extractScreenText(from terminal: Terminal) -> String {
        var lines: [String] = []

        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else {
                lines.append("")
                continue
            }

            var lineText = ""
            for col in 0..<cols {
                let charData = line[col]
                let char = charData.getCharacter()
                lineText.append(char == "\0" ? " " : char)
            }

            lines.append(lineText.trimmingCharacters(in: CharacterSet(charactersIn: " \t\0")))
        }

        return lines
            .reversed()
            .drop(while: { $0.isEmpty })
            .reversed()
            .joined(separator: "\n")
    }
}
