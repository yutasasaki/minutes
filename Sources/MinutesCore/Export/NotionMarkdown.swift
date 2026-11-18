import Foundation

/// Notion 向けの議事録の Markdown（SPEC §9.3）。
/// - `.paste`: 「Notion 用にコピー」。Notion に貼ると見出し・箇条書き・ToDo に変わる素の Markdown。タイトルを `#` で入れる。
/// - `.api`: Notion API に送る Notion-flavored Markdown（markdown_version v2）。タイトルはページのタイトルに入れるので本文に入れず、
///   全文は見出し付きのトグルに畳む。文中の `<` は Notion のタグと読まれないよう `\<` にする。
/// 根拠は Notion から開けない minutes:// のリンクにせず、発言の時刻で示す。
public enum NotionMarkdown {
    public enum Flavor: Sendable {
        case paste, api
    }

    public static func render(_ view: MeetingExporter.Presentation, flavor: Flavor) -> String {
        let ja = view.language == .ja
        let meeting = view.meeting
        let notes = view.notes
        let segmentsById = view.segmentsById
        func text(_ value: String) -> String { flavor == .api ? escapeTags(value) : value }
        func evidence(_ ids: [Int]) -> String {
            let times = ids.compactMap { segmentsById[$0].map { TimeFormatting.hms($0.tStart) } }
            guard !times.isEmpty else { return "" }
            return ja ? "（\(times.joined(separator: ", "))）" : " (\(times.joined(separator: ", ")))"
        }

        var blocks: [String] = []
        if flavor == .paste { blocks.append("# \(meeting.title)") }

        // 日時・長さ・参加者
        var meta = [MeetingHTMLRenderer.dateText(meeting, language: view.language)]
        if let duration = MeetingHTMLRenderer.durationText(meeting, segments: view.segments, language: view.language) { meta.append(duration) }
        if let platform = MeetingHTMLRenderer.platformName(meeting.meetingPlatform) { meta.append(platform) }
        var metaLines = [meta.joined(separator: " · ")]
        let people = !meeting.attendees.isEmpty ? meeting.attendees.map(\.name) : view.speakerNames
        if !people.isEmpty { metaLines.append((ja ? "参加者: " : "Attendees: ") + people.joined(separator: ja ? "、" : ", ")) }
        if !meeting.tags.isEmpty { metaLines.append((ja ? "タグ: " : "Tags: ") + meeting.tags.map { "#\($0)" }.joined(separator: " ")) }
        // 行を分けるには行末に \ を置く（CommonMark の改行。Notion もこれで改行になる）
        blocks.append(metaLines.map(text).joined(separator: "\\\n"))

        // 要約（中の見出しは一段下げる）
        blocks.append("## " + (ja ? "要約" : "Summary"))
        if let summary = notes?.summaryMd?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            blocks.append(text(demoteHeadings(summary)))
        } else {
            blocks.append(ja ? "（要約なし）" : "(No summary)")
        }

        let none = ja ? "（なし）" : "(None)"
        let decisions = notes?.decisions ?? []
        blocks.append("## " + (ja ? "決定事項" : "Decisions"))
        blocks.append(decisions.isEmpty ? none : decisions.enumerated().map { "\($0.offset + 1). \(text(oneLine($0.element.text)))\(evidence($0.element.evidence))" }.joined(separator: "\n"))

        let actions = notes?.actionItems ?? []
        blocks.append("## " + (ja ? "アクション" : "Action items"))
        blocks.append(actions.isEmpty ? none : actions.map { action in
            var details: [String] = [kindLabel(action.kind, ja: ja)]
            if !action.owner.isEmpty, !(action.owner == "me" && action.kind == .ownCommitment), !(action.owner == "agent" && action.kind == .delegable) {
                details.append((ja ? "担当: " : "Owner: ") + (action.owner == "agent" ? (ja ? "エージェント" : "Agent") : view.ownerName(action.owner)))
            }
            if let due = action.due, !due.isEmpty { details.append((ja ? "期限: " : "Due: ") + due) }
            let detail = ja ? "（\(details.joined(separator: " / "))）" : " (\(details.joined(separator: " / ")))"
            return "- [\(action.done == true ? "x" : " ")] \(text(oneLine(action.text)))\(text(detail))\(evidence(action.evidence))"
        }.joined(separator: "\n"))

        let questions = notes?.openQuestions ?? []
        blocks.append("## " + (ja ? "未決・論点" : "Open questions"))
        blocks.append(questions.isEmpty ? none : questions.map { "- \(text(oneLine($0.text)))\(evidence($0.evidence))" }.joined(separator: "\n"))

        if let userNotes = notes?.userNotesMd?.trimmingCharacters(in: .whitespacesAndNewlines), !userNotes.isEmpty {
            blocks.append("## " + (ja ? "メモ" : "Notes"))
            blocks.append(text(demoteHeadings(userNotes)))
        }

        // 全文
        let transcriptTitle = (ja ? "全文" : "Transcript") + (ja ? "（\(view.segments.count) 発言）" : " (\(view.segments.count))")
        let lines = view.segments.map { segment in
            "**\(TimeFormatting.hms(segment.tStart)) \(text(escapeInline(view.displayName(segment))))**　\(text(escapeInline(oneLine(segment.text))))"
        }
        switch flavor {
        case .paste:
            blocks.append("## " + transcriptTitle)
            blocks.append(lines.isEmpty ? none : lines.joined(separator: "\n\n"))
        case .api:
            // タイトルは開きタグの直後、子は空行のあと。タグに空行を接しない（Notion-flavored Markdown の決まり）
            let children = lines.isEmpty ? none : lines.joined(separator: "\n\n")
            blocks.append("<toggle heading=\"h2\">\(transcriptTitle)\n\n\(children)\n</toggle>")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func kindLabel(_ kind: MinutesSummary.ActionKind, ja: Bool) -> String {
        switch kind {
        case .ownCommitment: ja ? "自分のタスク" : "Mine"
        case .theirTask: ja ? "相手のタスク" : "Theirs"
        case .delegable: ja ? "委任できる" : "Delegable"
        }
    }

    /// 要約・メモの見出しを `##` の下に収める（`#` → `###`、`##` → `###`、`###` 以下はそのまま）。
    static func demoteHeadings(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            guard let range = line.range(of: #"^#{1,2}\s+"#, options: .regularExpression) else { return line }
            return "### " + line[range.upperBound...]
        }.joined(separator: "\n")
    }

    /// 1 行に収める（項目の文に改行が入ると、Notion で別のブロックに分かれる）。
    static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 発言の文を Markdown の記号として読ませない（`*` `_` `` ` `` `[` `]` `\`）。
    static func escapeInline(_ value: String) -> String {
        var result = ""
        for character in value {
            if "\\*_`[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Notion-flavored Markdown で `<` をタグと読ませない（コードの中は除く）。
    static func escapeTags(_ value: String) -> String {
        var result: [String] = []
        var inFence = false
        for line in value.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); result.append(line); continue }
            if inFence { result.append(line); continue }
            // 行内のコード（`...`）の中は変えない
            var out = ""
            var inCode = false
            var previous: Character?
            for character in line {
                if character == "`", previous != "\\" { inCode.toggle() }
                defer { previous = character }
                if character == "<", !inCode { out += "\\<" } else { out.append(character) }
            }
            result.append(out)
        }
        return result.joined(separator: "\n")
    }
}
