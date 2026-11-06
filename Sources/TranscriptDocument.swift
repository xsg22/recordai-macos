import Foundation

enum TranscriptPhase: String { case idle, saving, recognizing, diarizing, aligning, completed, failed }
enum SpeakerAnalysisStatus: String, Codable { case notStarted, processing, completed, partial, failed, cancelled }

/// separator属于正文，按段编辑不会丢失原有空格、标点和换行。
struct TranscriptParagraph: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var separator = ""
    var start: Double? = nil
    var end: Double? = nil
    var audioFile: String? = nil
    var speakerIDs: [String] = []
    var localStart: Double? = nil
    /// 仅本段上一次人工归属，支持重启后撤销；旧记录没有此字段。
    var previousSpeakerIDs: [String]? = nil
}
struct LiveUtterance: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}

extension MeetingRecord {
    var paragraphText: String { transcriptParagraphs.map { $0.separator + $0.text }.joined() }
    var hasCurrentParagraphs: Bool { !transcriptParagraphs.isEmpty && paragraphText == text }
    func canonicalSpeaker(_ id: String) -> String {
        var result = id, visited = Set<String>()
        while let next = speakerAliases[result], visited.insert(result).inserted { result = next }
        return result
    }
    func speakerName(_ id: String) -> String { speakerNames[canonicalSpeaker(id)] ?? "未命名发言人" }
    func displaySpeakerName(_ id: String) -> String {
        let key = canonicalSpeaker(id), name = speakerName(id)
        guard !customSpeakerNameIDs.contains(key) else { return name }
        if speakerNames[key] == nil || name.range(of: #"^发言人 [0-9]+$"#, options: .regularExpression) != nil { return L10n.text(name) }
        return name
    }
    func displayParagraphSpeaker(_ paragraph: TranscriptParagraph) -> String {
        let ids = Array(Set(paragraph.speakerIDs.map { canonicalSpeaker($0) })).sorted()
        if ids.isEmpty { return L10n.text(paragraph.start == nil && paragraph.audioFile == nil ? "原有正文" : "发言人未确定") }
        return (ids.count > 1 ? L10n.text("重叠发言 · ") : "") + ids.map { displaySpeakerName($0) }.joined(separator: " / ")
    }
    func paragraphSpeaker(_ paragraph: TranscriptParagraph) -> String {
        let ids = Array(Set(paragraph.speakerIDs.map { canonicalSpeaker($0) })).sorted()
        if ids.isEmpty { return paragraph.start == nil && paragraph.audioFile == nil ? "原有正文" : "发言人未确定" }
        return (ids.count > 1 ? "重叠发言 · " : "") + ids.map { speakerName($0) }.joined(separator: " / ")
    }
}

/// 全局时间只用于展示；播放器始终使用当前续录音频的局部时间。
struct TranscriptPlaybackRange: Equatable {
    let start: Double
    let end: Double
    init?(paragraph: TranscriptParagraph, record: MeetingRecord, duration: Double? = nil) {
        guard let file = paragraph.audioFile, let index = record.audioFiles.firstIndex(of: file),
              let globalStart = paragraph.start, let globalEnd = paragraph.end,
              globalStart.isFinite, globalEnd.isFinite, globalEnd > globalStart else { return nil }
        let earlier = record.audioFiles.prefix(index).reduce(0.0) { $0 + (record.audioDurations[$1] ?? 0) }
        // 无localStart时，只有前置片段时长齐全才能安全换算，不能猜测。
        if paragraph.localStart == nil && !record.audioFiles.prefix(index).allSatisfy({ record.audioDurations[$0] != nil }) { return nil }
        let localStart = paragraph.localStart ?? (globalStart - earlier)
        guard localStart.isFinite, localStart >= 0 else { return nil }
        let localEnd = localStart + (globalEnd - globalStart)
        let limit = duration ?? record.audioDurations[file]
        if let limit, !limit.isFinite || limit <= localStart { return nil }
        self.start = localStart
        self.end = limit.map { min(localEnd, $0) } ?? localEnd
        guard end > start else { return nil }
    }
}

/// 阅读层分组保留原始段落与 ID；混合归属不伪称同时发言。
struct TranscriptReadingGroup: Identifiable {
    var paragraphs: [TranscriptParagraph]
    var id: UUID { paragraphs[0].id }
    var combined: TranscriptParagraph {
        var result = paragraphs[0]
        for row in paragraphs.dropFirst() {
            result.text += row.separator + row.text
            result.end = row.end
            if Set(result.speakerIDs) != Set(row.speakerIDs) { result.speakerIDs = [] }
        }
        return result
    }
}
enum TranscriptReadability {
    /// Reading structure is independent of recognition windows and alignment.
    /// Every original character belongs to exactly one stable stored paragraph.
    static func fallback(_ text: String, hotwords: [String] = []) -> [TranscriptParagraph] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        var prefix = [0]
        for c in chars { prefix.append(prefix.last! + ((c.isLetter || c.isNumber) ? 1 : 0)) }
        let protected = hotwords.flatMap { word -> [Range<Int>] in
            guard !word.isEmpty else { return [] }
            var result: [Range<Int>] = [], cursor = text.startIndex
            while cursor < text.endIndex, let found = text.range(of: word, options: .caseInsensitive, range: cursor..<text.endIndex) {
                result.append(text.distance(from: text.startIndex, to: found.lowerBound)..<text.distance(from: text.startIndex, to: found.upperBound)); cursor = found.upperBound
            }
            return result
        }
        var result: [TranscriptParagraph] = [], start = 0
        while start < chars.count {
            let weight: (Int) -> Int = { prefix[$0] - prefix[start] }
            var stop = chars.count
            if weight(chars.count) > 50 {
                let endings = (start..<chars.count).filter { "。！？!?；;".contains(chars[$0]) || (chars[$0] == "." && ($0 + 1 == chars.count || chars[$0+1].isWhitespace)) }
                if let sentence = endings.first(where: { weight($0+1) >= 50 }), weight(sentence+1) <= 75 { stop = sentence+1 }
                else {
                    let clauses = (start..<chars.count).filter { "，,、：:".contains(chars[$0]) && (25...75).contains(weight($0+1)) }
                    stop = clauses.min(by: { abs(weight($0+1)-50) < abs(weight($1+1)-50) }).map { $0+1 } ?? (start..<chars.count).first(where: { weight($0+1) >= 50 }).map { $0+1 } ?? chars.count
                }
            }
            while stop < chars.count && chars[stop-1].isASCII && chars[stop].isASCII && (chars[stop-1].isLetter || chars[stop-1].isNumber) && (chars[stop].isLetter || chars[stop].isNumber || chars[stop] == "'") { stop += 1 }
            for span in protected where span.lowerBound < stop && stop < span.upperBound { stop = span.upperBound }
            while stop < chars.count && (chars[stop].isWhitespace || "”’\"'」』）)]}".contains(chars[stop])) { stop += 1 }
            result.append(TranscriptParagraph(text: String(chars[start..<stop])))
            start = stop
        }
        return result
    }

    static func groups(_ rows: [TranscriptParagraph]) -> [TranscriptReadingGroup] {
        var result: [TranscriptReadingGroup] = []
        for row in rows {
            if let last = result.last, last.paragraphs.allSatisfy({ $0.previousSpeakerIDs == nil }),
               canJoin(last.combined, row, combinedLength: last.combined.text.count) {
                result[result.count - 1].paragraphs.append(row)
            } else { result.append(TranscriptReadingGroup(paragraphs: [row])) }
        }
        return result
    }
    private static func canJoin(_ a: TranscriptParagraph, _ b: TranscriptParagraph, combinedLength: Int) -> Bool {
        guard a.audioFile == b.audioFile,
              a.speakerIDs.count == 1, Set(a.speakerIDs) == Set(b.speakerIDs),
              a.previousSpeakerIDs == nil, b.previousSpeakerIDs == nil,
              let end = a.end, let start = b.start, let aStart = a.start, let bEnd = b.end,
              [start, end, aStart, bEnd].allSatisfy(\.isFinite),
              start >= end - 0.15, start - end <= 0.45,
              !b.separator.contains("\n"),
              !a.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "”’\"'」』）)]}"))).hasSuffix(where: { "。！？!?；;.".contains($0) }),
              combinedLength + b.text.count <= 180 else { return false }
        let letters: (String) -> Int = { $0.filter { $0.isLetter || $0.isNumber }.count }
        // 短暂归属抖动只影响阅读分组；正常长句和完整短答保留各自边界。
        return (letters(a.text) <= 2 && end - aStart < 0.8) || (letters(b.text) <= 2 && bEnd - start < 0.8)
    }
}
private extension String {
    func hasSuffix(where predicate: (Character) -> Bool) -> Bool { last.map(predicate) ?? false }
}
