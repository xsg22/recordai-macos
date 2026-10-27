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
    func paragraphSpeaker(_ paragraph: TranscriptParagraph) -> String {
        let ids = Array(Set(paragraph.speakerIDs.map { canonicalSpeaker($0) })).sorted()
        if ids.isEmpty { return paragraph.start == nil ? "原有正文" : "发言人未确定" }
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
