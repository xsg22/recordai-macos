import Foundation

/// 新片段定稿与待处理队列一起保存，重试不重复追加已成功的片段。
enum MeetingRecordingAppend {
    /// 持续录音的时间轴来自采集时的真实片段起点，不能用片段时长相加代替静音间隔。
    static func applyContinuous(_ output: TranscriptionOutput, file: String, start: Double,
                                to record: inout MeetingRecord) throws {
        guard start.isFinite, start >= 0, record.pendingAudioFiles.contains(file),
              record.audioFiles.contains(file) else {
            throw TranscriptionError.message("持续录音片段状态已变化，未重复追加。")
        }
        if !record.text.isEmpty && !record.hasCurrentParagraphs {
            record.transcriptParagraphs = [TranscriptParagraph(text: record.text)]
        }
        record.transcriptOrigin = .local
        let prior = record.text.isEmpty ? "" : "\n\n"
        if !output.text.isEmpty {
            var rows = output.paragraphs.isEmpty ? [TranscriptParagraph(text: output.text)] : output.paragraphs
            for index in rows.indices {
                rows[index].audioFile = file
                rows[index].applyAudioOffset(start)
            }
            rows[0].separator = prior + rows[0].separator
            record.transcriptParagraphs.append(contentsOf: rows)
            record.text += prior + output.text
        }
        record.subtitles = try appendSRT(output.subtitles, to: record.subtitles, offset: start)
        record.pendingAudioFiles.removeAll { $0 == file }
    }

    static func apply(outputs: [TranscriptionOutput], files: [String], durations: [Double],
                      appending: Bool, to record: inout MeetingRecord) throws {
        guard outputs.count == files.count, files.count == durations.count,
              !files.isEmpty, Set(files).count == files.count,
              files.allSatisfy({ record.audioFiles.contains($0) }),
              durations.allSatisfy({ $0.isFinite && $0 >= 0 }),
              !appending || files == record.pendingAudioFiles else {
            throw TranscriptionError.message("录音片段状态已变化，未追加文字，请重试。")
        }
        record.transcriptOrigin = .local
        var paragraphs = appending && record.hasCurrentParagraphs ? record.transcriptParagraphs : []
        if appending && !record.text.isEmpty && paragraphs.isEmpty { paragraphs = [TranscriptParagraph(text: record.text)] }
        var text = appending ? record.text : ""
        var subtitles = appending ? record.subtitles : ""
        let recordedPendingDuration = files.enumerated().reduce(0.0) { total, item in
            total + (record.audioDurations[item.element] ?? durations[item.offset])
        }
        let previousDuration = appending ? max(0, record.duration - recordedPendingDuration) : 0
        var offset = previousDuration
        for (index, output) in outputs.enumerated() {
            if !output.text.isEmpty {
                let prefix = text.isEmpty ? "" : "\n\n"
                var rows = output.paragraphs
                if rows.isEmpty { rows = [TranscriptParagraph(text: output.text)] }
                for rowIndex in rows.indices {
                    rows[rowIndex].audioFile = files[index]
                    rows[rowIndex].applyAudioOffset(offset)
                }
                rows[0].separator = prefix + rows[0].separator
                paragraphs += rows
                text += prefix + output.text
            }
            subtitles = try appendSRT(output.subtitles, to: subtitles, offset: offset)
            offset += durations[index]
        }
        record.text = text; record.subtitles = subtitles; record.transcriptParagraphs = paragraphs
        for (index, file) in files.enumerated() { record.audioDurations[file] = durations[index] }
        record.pendingAudioFiles.removeAll { files.contains($0) }
        record.duration = previousDuration + durations.reduce(0, +)
    }

    static func applySpeakerParagraphs(_ rows: [TranscriptParagraph], base: TranscriptionOutput,
                                       file: String, to record: inout MeetingRecord) throws {
        let old = record.transcriptParagraphs.filter { $0.audioFile == file }
        if rows.isEmpty && base.text.isEmpty { return }
        let stored = old.enumerated().map { $0.offset == 0 ? $0.element.text : $0.element.separator + $0.element.text }.joined()
        guard record.hasCurrentParagraphs, let first = old.first, stored == base.text,
              rows.map({ $0.separator + $0.text }).joined() == base.text else {
            throw TranscriptionError.message("正文已变化，未覆盖人工编辑或添加过期标签。")
        }
        let offset: Double
        if let part = record.audioFiles.firstIndex(of: file), record.audioFiles.prefix(part).allSatisfy({ record.audioDurations[$0] != nil }) {
            offset = record.audioFiles.prefix(part).reduce(0) { $0 + (record.audioDurations[$1] ?? 0) }
        } else if let globalStart = first.start, let localStart = base.paragraphs.first?.start { offset = globalStart - localStart }
        else { throw TranscriptionError.message("音频片段时间尚未确认，正文已保留。") }
        var scoped = rows
        for i in scoped.indices {
            scoped[i].audioFile = file
            scoped[i].applyAudioOffset(offset)
            scoped[i].speakerIDs = scoped[i].speakerIDs.map { file + ":" + $0 }
            for speaker in scoped[i].speakerIDs where record.speakerNames[speaker] == nil {
                record.speakerNames[speaker] = "发言人 \(record.speakerNames.count + 1)"
            }
        }
        if !scoped.isEmpty { scoped[0].separator = first.separator + scoped[0].separator }
        guard let index = record.transcriptParagraphs.firstIndex(where: { $0.audioFile == file }) else { return }
        record.transcriptParagraphs.removeAll { $0.audioFile == file }
        record.transcriptParagraphs.insert(contentsOf: scoped, at: index)
        guard record.paragraphText == record.text else { throw TranscriptionError.message("发言人分段与正文不一致，正文已保留。") }
        if record.transcriptParagraphs.allSatisfy({ $0.start != nil && $0.end != nil }) {
            func stamp(_ time: Double) -> String {
                let ms = Int((time * 1000).rounded())
                return String(format: "%02d:%02d:%02d,%03d", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
            }
            record.subtitles = record.transcriptParagraphs.enumerated().map { i, p in "\(i+1)\n\(stamp(p.start!)) --> \(stamp(p.end!))\n\(p.text)" }.joined(separator: "\n\n") + "\n\n"
        }

    }

    static func sliceSRT(_ source:String,beforeEnd:Double?=nil,afterStart:Double?=nil) throws -> String {
        let regex=try NSRegularExpression(pattern:"(\\d{2,}):(\\d{2}):(\\d{2}),(\\d{3})")
        var result=""
        for block in source.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n\n") where !block.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let lines=block.components(separatedBy:"\n")
            guard lines.count>=3 else { throw BalancedAudioError.invalidManifest }
            let times=regex.matches(in:lines[1],range:NSRange(lines[1].startIndex...,in:lines[1])).map { match -> Double in
                let parts=(1...4).map{Double((lines[1]as NSString).substring(with:match.range(at:$0)))!}
                return parts[0]*3600+parts[1]*60+parts[2]+parts[3]/1000
            }
            guard times.count==2 else { throw BalancedAudioError.invalidManifest }
            if let beforeEnd,times[1]>beforeEnd+0.001 {continue}
            if let afterStart,times[0]<afterStart-0.001 {continue}
            result=try appendSRT(block,to:result,offset:0)
        }
        return result
    }

    /// SRT 使用整场累计时间轴与连续序号，保留已有字幕正文。
    static func appendSRT(_ new: String, to previous: String, offset: Double) throws -> String {
        let regex = try NSRegularExpression(pattern: "(\\d{2,}):(\\d{2}):(\\d{2}),(\\d{3})")
        var blocks = previous.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for block in new.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 3 else {
                if lines == [""] { continue }
                throw TranscriptionError.message("字幕格式异常，已有转录已保留。")
            }
            let timeline = lines[1]
            let matches = regex.matches(in: timeline, range: NSRange(timeline.startIndex..., in: timeline))
            guard matches.count == 2 else { throw TranscriptionError.message("字幕时间格式异常。") }
            var adjusted = timeline
            for match in matches.reversed() {
                let parts = (1...4).map { Int((timeline as NSString).substring(with: match.range(at: $0)))! }
                let milliseconds = Int((offset * 1000).rounded()) + ((parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000 + parts[3])
                let stamp = String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000,
                                   milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
                adjusted = (adjusted as NSString).replacingCharacters(in: match.range, with: stamp)
            }
            blocks.append(([String(blocks.count + 1), adjusted] + lines.dropFirst(2)).joined(separator: "\n"))
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n\n"
    }
}
