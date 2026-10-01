import Foundation

/// Finds inline Markdown image destinations without interpreting the rest of
/// the document. The ranges are UTF-16 based so they can be used directly with
/// `NSTextStorage` and the rest of the AppKit text system.
enum MarkdownImage {
    struct Match: Equatable {
        let range: NSRange
        let altText: String
        /// The destination exactly as written, excluding optional `<` and `>`.
        let urlString: String
        let url: URL
    }

    static func matches(in source: String) -> [Match] {
        // Every image starts with `![`; skip the code-range scan for the
        // common note that has none (this runs on every edit).
        guard source.contains("![") else { return [] }
        // Text from AppKit is a bridged NSString; walking its characters is
        // several times slower than walking a native UTF-8 copy.
        var markdown = source
        markdown.makeContiguousUTF8()
        var matches: [Match] = []
        var cursor = markdown.startIndex
        // Sorted and non-overlapping; `cursor` only moves forward, so one
        // forward-moving position replaces a scan of every range per `!`.
        let codeRanges = codeRanges(in: markdown)
        var codeRangeIndex = 0

        while cursor < markdown.endIndex,
              let imageStart = markdown[cursor...].firstIndex(of: "!") {
            let nextCursor = markdown.index(after: imageStart)
            while codeRangeIndex < codeRanges.count, codeRanges[codeRangeIndex].upperBound <= imageStart {
                codeRangeIndex += 1
            }
            let inCode = codeRangeIndex < codeRanges.count && codeRanges[codeRangeIndex].contains(imageStart)

            guard !inCode,
                  !isEscaped(imageStart, in: markdown),
                  nextCursor < markdown.endIndex,
                  markdown[nextCursor] == "[",
                  let parsed = parseImage(startingAt: imageStart, in: markdown),
                  let url = renderableURL(from: parsed.urlString) else {
                cursor = nextCursor
                continue
            }

            matches.append(
                Match(
                    range: NSRange(imageStart..<parsed.endIndex, in: markdown),
                    altText: parsed.altText,
                    urlString: parsed.urlString,
                    url: url
                )
            )
            cursor = parsed.endIndex
        }

        return matches
    }

    /// Notes are global rather than file-backed, so a relative destination has
    /// no stable base URL. Only destinations the preview loader can resolve
    /// unambiguously are treated as renderable images.
    private static func renderableURL(from destination: String) -> URL? {
        guard let url = URL(string: destination) else { return nil }
        if url.isFileURL { return url }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    // MARK: - Code exclusion

    /// Image-like text in examples must stay source text, not become a preview.
    /// Fences are identified first so their backticks are never mistaken for
    /// inline-code delimiters.
    private static func codeRanges(in markdown: String) -> [Range<String.Index>] {
        let fenced = fencedCodeRanges(in: markdown)
        let inline = inlineCodeRanges(in: markdown, excluding: fenced)
        return (fenced + inline).sorted { $0.lowerBound < $1.lowerBound }
    }

    private struct OpenFence {
        let character: Character
        let length: Int
        let start: String.Index
    }

    private static func fencedCodeRanges(in markdown: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var openFence: OpenFence?
        var lineStart = markdown.startIndex

        while lineStart < markdown.endIndex {
            let newline = markdown[lineStart...].firstIndex(of: "\n")
            let lineContentEnd = newline ?? markdown.endIndex
            let lineEnd = newline.map { markdown.index(after: $0) } ?? markdown.endIndex
            let line = markdown[lineStart..<lineContentEnd]

            if let activeFence = openFence {
                if isClosingFence(
                    line,
                    character: activeFence.character,
                    minimumLength: activeFence.length
                ) {
                    ranges.append(activeFence.start..<lineEnd)
                    openFence = nil
                }
            } else if let marker = openingFence(in: line) {
                openFence = OpenFence(
                    character: marker.character,
                    length: marker.length,
                    start: lineStart
                )
            }

            lineStart = lineEnd
        }

        if let openFence {
            ranges.append(openFence.start..<markdown.endIndex)
        }
        return ranges
    }

    private static func openingFence(
        in line: Substring
    ) -> (character: Character, length: Int)? {
        guard let run = fenceRun(in: line), run.length >= 3 else { return nil }
        if run.character == "`", line[run.remainder...].contains("`") {
            return nil
        }
        return (run.character, run.length)
    }

    private static func isClosingFence(
        _ line: Substring,
        character: Character,
        minimumLength: Int
    ) -> Bool {
        guard let run = fenceRun(in: line),
              run.character == character,
              run.length >= minimumLength else {
            return false
        }
        return line[run.remainder...].allSatisfy {
            $0 == " " || $0 == "\t" || $0 == "\r"
        }
    }

    private static func fenceRun(
        in line: Substring
    ) -> (character: Character, length: Int, remainder: String.Index)? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }
        guard indentation <= 3,
              index < line.endIndex,
              line[index] == "`" || line[index] == "~" else {
            return nil
        }

        let character = line[index]
        var length = 0
        while index < line.endIndex, line[index] == character {
            length += 1
            index = line.index(after: index)
        }
        return (character, length, index)
    }

    private static func inlineCodeRanges(
        in markdown: String,
        excluding fencedRanges: [Range<String.Index>]
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = markdown.startIndex
        // `fencedRanges` is sorted and non-overlapping, and both `cursor` and
        // `search` only move forward, so each keeps a forward-moving position
        // into it instead of scanning every fence per character.
        var fenceIndex = 0
        func fence(containing index: String.Index, from position: inout Int) -> Range<String.Index>? {
            while position < fencedRanges.count, fencedRanges[position].upperBound <= index {
                position += 1
            }
            guard position < fencedRanges.count, fencedRanges[position].contains(index) else { return nil }
            return fencedRanges[position]
        }

        while cursor < markdown.endIndex {
            if let fence = fence(containing: cursor, from: &fenceIndex) {
                cursor = fence.upperBound
                continue
            }
            guard markdown[cursor] == "`", !isEscaped(cursor, in: markdown) else {
                cursor = markdown.index(after: cursor)
                continue
            }

            let openingStart = cursor
            let openingLength = characterRunLength(in: markdown, from: cursor, character: "`")
            cursor = markdown.index(cursor, offsetBy: openingLength)
            var search = cursor
            var searchFenceIndex = fenceIndex
            var closingEnd: String.Index?

            while search < markdown.endIndex {
                if fence(containing: search, from: &searchFenceIndex) != nil {
                    // A fenced block interrupts the surrounding paragraph, so
                    // an inline span cannot pair delimiters across that block.
                    break
                }
                guard markdown[search] == "`", !isEscaped(search, in: markdown) else {
                    search = markdown.index(after: search)
                    continue
                }

                let runLength = characterRunLength(in: markdown, from: search, character: "`")
                let runEnd = markdown.index(search, offsetBy: runLength)
                if runLength == openingLength {
                    closingEnd = runEnd
                    break
                }
                search = runEnd
            }

            if let closingEnd {
                ranges.append(openingStart..<closingEnd)
                cursor = closingEnd
            }
        }
        return ranges
    }

    private static func characterRunLength(
        in text: String,
        from start: String.Index,
        character: Character
    ) -> Int {
        var index = start
        var length = 0
        while index < text.endIndex, text[index] == character {
            length += 1
            index = text.index(after: index)
        }
        return length
    }

    private struct ParsedImage {
        let endIndex: String.Index
        let altText: String
        let urlString: String
    }

    private static func parseImage(
        startingAt imageStart: String.Index,
        in markdown: String
    ) -> ParsedImage? {
        let openingBracket = markdown.index(after: imageStart)
        let altStart = markdown.index(after: openingBracket)
        guard let closingBracket = closingAltBracket(from: altStart, in: markdown) else {
            return nil
        }

        let openingParenthesis = markdown.index(after: closingBracket)
        guard openingParenthesis < markdown.endIndex,
              markdown[openingParenthesis] == "(" else {
            return nil
        }

        var destinationStart = markdown.index(after: openingParenthesis)
        skipHorizontalWhitespace(in: markdown, from: &destinationStart)
        guard destinationStart < markdown.endIndex else { return nil }

        let destination: Substring
        var suffixStart: String.Index

        if markdown[destinationStart] == "<" {
            let urlStart = markdown.index(after: destinationStart)
            guard let closingAngle = closingAngleBracket(from: urlStart, in: markdown) else {
                return nil
            }
            destination = markdown[urlStart..<closingAngle]
            suffixStart = markdown.index(after: closingAngle)
        } else {
            guard let bare = bareDestination(from: destinationStart, in: markdown) else {
                return nil
            }
            destination = markdown[destinationStart..<bare]
            suffixStart = bare
        }

        guard !destination.isEmpty,
              let markupEnd = closingParenthesis(from: &suffixStart, in: markdown) else {
            return nil
        }

        return ParsedImage(
            endIndex: markupEnd,
            altText: String(markdown[altStart..<closingBracket]),
            urlString: String(destination)
        )
    }

    /// Supports escaped brackets and nested brackets in image descriptions.
    private static func closingAltBracket(
        from start: String.Index,
        in markdown: String
    ) -> String.Index? {
        var index = start
        var depth = 1

        while index < markdown.endIndex {
            let character = markdown[index]
            if character == "\\" {
                index = indexAfterEscapedCharacter(at: index, in: markdown)
                continue
            }
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return index }
            } else if character == "\n" || character == "\r" {
                return nil
            }
            index = markdown.index(after: index)
        }

        return nil
    }

    private static func closingAngleBracket(
        from start: String.Index,
        in markdown: String
    ) -> String.Index? {
        var index = start
        while index < markdown.endIndex {
            let character = markdown[index]
            if character == ">" { return index }
            if character == "<" || character == "\n" || character == "\r" {
                return nil
            }
            index = markdown.index(after: index)
        }
        return nil
    }

    private static func bareDestination(
        from start: String.Index,
        in markdown: String
    ) -> String.Index? {
        var index = start
        var parenthesisDepth = 0

        while index < markdown.endIndex {
            let character = markdown[index]
            if character == "\\" {
                index = indexAfterEscapedCharacter(at: index, in: markdown)
                continue
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                if parenthesisDepth == 0 { return index }
                parenthesisDepth -= 1
            } else if character == " " || character == "\t" {
                guard parenthesisDepth == 0 else { return nil }
                return index
            } else if character == "\n" || character == "\r" {
                return nil
            }
            index = markdown.index(after: index)
        }

        return nil
    }

    /// Validates an optional quoted title and returns the index immediately
    /// after the image's final `)`.
    private static func closingParenthesis(
        from suffixStart: inout String.Index,
        in markdown: String
    ) -> String.Index? {
        if suffixStart < markdown.endIndex, markdown[suffixStart] == ")" {
            return markdown.index(after: suffixStart)
        }

        let whitespaceStart = suffixStart
        skipHorizontalWhitespace(in: markdown, from: &suffixStart)
        guard suffixStart != whitespaceStart,
              suffixStart < markdown.endIndex,
              markdown[suffixStart] == "\"" || markdown[suffixStart] == "'" else {
            return nil
        }

        let quote = markdown[suffixStart]
        var index = markdown.index(after: suffixStart)
        var foundClosingQuote = false
        while index < markdown.endIndex {
            let character = markdown[index]
            if character == "\\" {
                index = indexAfterEscapedCharacter(at: index, in: markdown)
                continue
            }
            if character == quote {
                foundClosingQuote = true
                index = markdown.index(after: index)
                break
            }
            if character == "\n" || character == "\r" { return nil }
            index = markdown.index(after: index)
        }

        guard foundClosingQuote else { return nil }
        skipHorizontalWhitespace(in: markdown, from: &index)
        guard index < markdown.endIndex, markdown[index] == ")" else { return nil }
        return markdown.index(after: index)
    }

    private static func skipHorizontalWhitespace(
        in markdown: String,
        from index: inout String.Index
    ) {
        while index < markdown.endIndex,
              markdown[index] == " " || markdown[index] == "\t" {
            index = markdown.index(after: index)
        }
    }

    private static func indexAfterEscapedCharacter(
        at backslash: String.Index,
        in markdown: String
    ) -> String.Index {
        let next = markdown.index(after: backslash)
        guard next < markdown.endIndex else { return next }
        return markdown.index(after: next)
    }

    private static func isEscaped(_ index: String.Index, in markdown: String) -> Bool {
        var cursor = index
        var backslashCount = 0
        while cursor > markdown.startIndex {
            let previous = markdown.index(before: cursor)
            guard markdown[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount.isMultiple(of: 2) == false
    }
}
