import Foundation

/// 議事録を 1 ファイルの HTML にする（SPEC §7.3 の `meeting.html`）。
/// ブラウザで開いてそのまま読め、人に渡せるよう、CSS と小さなスクリプトを埋め込み、外部のフォント・画像・スクリプトは読まない。
/// ライト・ダークは OS の設定に従い、印刷では全文も開いて出す。根拠の発言（#123）は同じページの全文へ飛ぶ。
public enum MeetingHTMLRenderer {
    public struct Input: Sendable {
        public var meeting: MeetingRecord
        /// 除外した話者（背景の声）を除いた話者の表示名。参加者がいないときに見出しに並べる。
        public var speakerNames: [String]
        /// 除外した話者の発言を除いた発言。
        public var segments: [SegmentRecord]
        public var notes: NotesRecord?
        /// アクションの担当 "me" の表示名。
        public var selfName: String
        /// 話者のラベル（spk_0 など）→ 表示名。要約が担当を話者のラベルで返したときに使う。
        public var ownerNames: [String: String] = [:]
        public var displayName: @Sendable (SegmentRecord) -> String
        public var generatedBy: String

        public init(meeting: MeetingRecord, speakerNames: [String], segments: [SegmentRecord], notes: NotesRecord?, selfName: String, generatedBy: String, displayName: @escaping @Sendable (SegmentRecord) -> String) {
            self.meeting = meeting
            self.speakerNames = speakerNames
            self.segments = segments
            self.notes = notes
            self.selfName = selfName
            self.generatedBy = generatedBy
            self.displayName = displayName
        }
    }

    public static func render(_ input: Input, now: Date = Date()) -> String {
        let meeting = input.meeting
        let label = Labels(meeting.summaryOutputLanguage)
        let notes = input.notes
        let decisions = notes?.decisions ?? []
        let actions = notes?.actionItems ?? []
        let questions = notes?.openQuestions ?? []
        let segmentIds = Set(input.segments.compactMap { $0.id.map(Int.init) })

        // 話者ごとの色（出てきた順）
        var speakerOrder: [String] = []
        for segment in input.segments {
            let name = input.displayName(segment)
            if !speakerOrder.contains(name) { speakerOrder.append(name) }
        }
        func speakerClass(_ name: String) -> String { "s\((speakerOrder.firstIndex(of: name) ?? 0) % 8)" }

        func evidence(_ ids: [Int]) -> String {
            let links = ids.map { id in
                segmentIds.contains(id)
                    ? "<a class=\"ev\" href=\"#seg-\(id)\" title=\"\(escape(label.jumpToEvidence))\">#\(id)</a>"
                    : "<span class=\"ev ev-missing\">#\(id)</span>"
            }
            return links.isEmpty ? "" : "<span class=\"evs\">\(links.joined())</span>"
        }

        var html: [String] = []
        html.append("<!doctype html>")
        html.append("<html lang=\"\(meeting.summaryOutputLanguage.rawValue)\">")
        html.append("<head>")
        html.append("<meta charset=\"utf-8\">")
        html.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        html.append("<meta name=\"color-scheme\" content=\"light dark\">")
        html.append("<meta name=\"generator\" content=\"\(escape(input.generatedBy))\">")
        html.append("<title>\(escape(meeting.title))</title>")
        html.append("<style>\(stylesheet)</style>")
        html.append("</head>")
        html.append("<body>")
        html.append("<main class=\"page\">")

        // ヘッダー
        html.append("<header class=\"hero\">")
        html.append("<p class=\"eyebrow\">\(escape(label.eyebrow))</p>")
        html.append("<h1>\(escape(meeting.title))</h1>")
        var meta: [String] = ["<span>\(escape(dateText(meeting, language: meeting.summaryOutputLanguage)))</span>"]
        if let duration = durationText(meeting, segments: input.segments, language: meeting.summaryOutputLanguage) {
            meta.append("<span>\(escape(duration))</span>")
        }
        if let platform = platformName(meeting.meetingPlatform) { meta.append("<span>\(escape(platform))</span>") }
        html.append("<p class=\"meta\">\(meta.joined(separator: "<span class=\"dot\">·</span>"))</p>")
        let people = !meeting.attendees.isEmpty ? meeting.attendees.map(\.name) : input.speakerNames
        if !people.isEmpty || !meeting.tags.isEmpty {
            html.append("<div class=\"chips\">")
            for name in people { html.append("<span class=\"chip person\">\(escape(name))</span>") }
            for tag in meeting.tags { html.append("<span class=\"chip tag\">#\(escape(tag))</span>") }
            html.append("</div>")
        }
        html.append("</header>")

        // 数の一覧
        html.append("<nav class=\"stats\" aria-label=\"\(escape(label.contents))\">")
        html.append(stat(count: decisions.count, title: label.decisions, href: "#decisions"))
        html.append(stat(count: actions.count, title: label.actions, href: "#actions"))
        html.append(stat(count: questions.count, title: label.openQuestions, href: "#questions"))
        html.append(stat(count: input.segments.count, title: label.utterances, href: "#transcript"))
        html.append("</nav>")

        // 要約
        html.append("<section class=\"card\" id=\"summary\">")
        html.append("<h2>\(escape(label.summary))</h2>")
        if let summary = notes?.summaryMd, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            html.append("<div class=\"prose\">\(markdownToHTML(summary))</div>")
        } else {
            html.append("<p class=\"empty\">\(escape(label.noSummary))</p>")
        }
        html.append("</section>")

        // 決定事項
        html.append("<section class=\"card\" id=\"decisions\">")
        html.append("<h2>\(escape(label.decisions))<span class=\"count\">\(decisions.count)</span></h2>")
        if decisions.isEmpty {
            html.append("<p class=\"empty\">\(escape(label.none))</p>")
        } else {
            html.append("<ol class=\"items decisions\">")
            for decision in decisions {
                html.append("<li><span class=\"text\">\(inlineMarkdown(decision.text))</span>\(evidence(decision.evidence))</li>")
            }
            html.append("</ol>")
        }
        html.append("</section>")

        // アクション
        html.append("<section class=\"card\" id=\"actions\">")
        html.append("<h2>\(escape(label.actions))<span class=\"count\">\(actions.count)</span></h2>")
        if actions.isEmpty {
            html.append("<p class=\"empty\">\(escape(label.none))</p>")
        } else {
            html.append("<ul class=\"items actions\">")
            for action in actions {
                let done = action.done == true
                var badges: [String] = ["<span class=\"badge kind-\(action.kind.rawValue)\">\(escape(label.kind(action.kind)))</span>"]
                if let owner = label.owner(input.ownerNames[action.owner] ?? action.owner, kind: action.kind, selfName: input.selfName) {
                    badges.append("<span class=\"badge owner\">\(escape(owner))</span>")
                }
                if let due = action.due, !due.isEmpty {
                    badges.append("<span class=\"badge due\">\(escape(label.due)) \(escape(due))</span>")
                }
                html.append("<li class=\"\(done ? "done" : "")\">")
                html.append("<span class=\"check\" aria-label=\"\(escape(done ? label.doneLabel : label.todoLabel))\">\(done ? "✓" : "")</span>")
                html.append("<div class=\"body\"><span class=\"text\">\(inlineMarkdown(action.text))</span>")
                html.append("<div class=\"badges\">\(badges.joined())\(evidence(action.evidence))</div></div>")
                html.append("</li>")
            }
            html.append("</ul>")
        }
        html.append("</section>")

        // 未決・論点
        html.append("<section class=\"card\" id=\"questions\">")
        html.append("<h2>\(escape(label.openQuestions))<span class=\"count\">\(questions.count)</span></h2>")
        if questions.isEmpty {
            html.append("<p class=\"empty\">\(escape(label.none))</p>")
        } else {
            html.append("<ul class=\"items questions\">")
            for question in questions {
                html.append("<li><span class=\"text\">\(inlineMarkdown(question.text))</span>\(evidence(question.evidence))</li>")
            }
            html.append("</ul>")
        }
        html.append("</section>")

        // メモ
        if let userNotes = notes?.userNotesMd, !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            html.append("<section class=\"card\" id=\"notes\">")
            html.append("<h2>\(escape(label.notes))</h2>")
            html.append("<div class=\"prose\">\(markdownToHTML(userNotes))</div>")
            html.append("</section>")
        }

        // 全文
        html.append("<section class=\"card transcript\" id=\"transcript\">")
        html.append("<details\(input.segments.count <= 40 ? " open" : "")>")
        html.append("<summary><h2>\(escape(label.transcript))<span class=\"count\">\(input.segments.count)</span></h2><span class=\"toggle\" aria-hidden=\"true\"></span></summary>")
        if input.segments.isEmpty {
            html.append("<p class=\"empty\">\(escape(label.none))</p>")
        } else {
            html.append("<div class=\"filter\"><input type=\"search\" id=\"filter\" placeholder=\"\(escape(label.filterPlaceholder))\" aria-label=\"\(escape(label.filterPlaceholder))\"><span id=\"filter-count\"></span></div>")
            html.append("<ol class=\"lines\">")
            for segment in input.segments {
                let name = input.displayName(segment)
                let anchor = segment.id.map { " id=\"seg-\($0)\"" } ?? ""
                html.append("<li\(anchor) class=\"\(speakerClass(name))\"><time>\(TimeFormatting.hms(segment.tStart))</time><b>\(escape(name))</b><span>\(escape(segment.text))</span></li>")
            }
            html.append("</ol>")
        }
        html.append("</details>")
        html.append("</section>")

        // フッター
        html.append("<footer>")
        html.append("<a href=\"minutes://meeting/\(escape(meeting.id))\">\(escape(label.openInMinutes))</a>")
        html.append("<span>\(escape(label.generated(generatedText(now, language: meeting.summaryOutputLanguage))))</span>")
        html.append("</footer>")
        html.append("</main>")
        html.append("<script>\(script)</script>")
        html.append("</body>")
        html.append("</html>")
        return html.joined(separator: "\n") + "\n"
    }

    // MARK: - 部品

    static func stat(count: Int, title: String, href: String) -> String {
        "<a class=\"stat\" href=\"\(href)\"><strong>\(count)</strong><span>\(escape(title))</span></a>"
    }

    static func dateText(_ meeting: MeetingRecord, language: MeetingLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .ja ? "ja_JP" : "en_US")
        formatter.dateFormat = language == .ja ? "yyyy年M月d日（E）H:mm" : "EEE, MMM d, yyyy, h:mm a"
        var text = formatter.string(from: meeting.startedAt)
        if let ended = meeting.endedAt {
            formatter.dateFormat = language == .ja ? "H:mm" : "h:mm a"
            text += " – " + formatter.string(from: ended)
        }
        return text
    }

    static func generatedText(_ date: Date, language: MeetingLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .ja ? "ja_JP" : "en_US")
        formatter.dateFormat = language == .ja ? "yyyy年M月d日 H:mm" : "MMM d, yyyy, h:mm a"
        return formatter.string(from: date)
    }

    static func durationText(_ meeting: MeetingRecord, segments: [SegmentRecord], language: MeetingLanguage) -> String? {
        let seconds = meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) } ?? segments.map(\.tEnd).max()
        guard let seconds, seconds >= 60 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if language == .ja { return minutes >= 60 ? "\(minutes / 60) 時間 \(minutes % 60) 分" : "\(minutes) 分" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func platformName(_ platform: MeetingPlatform?) -> String? {
        switch platform {
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .other, nil: nil
        }
    }

    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - Markdown（要約が使う範囲: 見出し・箇条書き・番号付き・段落・強調・コード・リンク）

    /// 要約とメモの Markdown を HTML にする。生の HTML は通さない（すべてエスケープする）。
    public static func markdownToHTML(_ markdown: String) -> String {
        enum ListKind { case ul, ol }
        var out: [String] = []
        var paragraph: [String] = []
        // 入れ子の箇条書き（インデント 2 文字で 1 段）
        var listStack: [(kind: ListKind, indent: Int)] = []
        var itemOpen: [Bool] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>\(paragraph.map(inlineMarkdown).joined(separator: "<br>"))</p>")
            paragraph = []
        }
        func closeLists(to depth: Int) {
            while listStack.count > depth {
                if itemOpen.removeLast() { out.append("</li>") }
                out.append(listStack.removeLast().kind == .ul ? "</ul>" : "</ol>")
            }
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if trimmed.isEmpty {
                flushParagraph()
                closeLists(to: 0)
                continue
            }
            if let heading = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph()
                closeLists(to: 0)
                let level = min(6, max(3, trimmed[heading].filter { $0 == "#" }.count + 1))
                out.append("<h\(level)>\(inlineMarkdown(String(trimmed[heading.upperBound...])))</h\(level)>")
                continue
            }
            var item: (kind: ListKind, text: String)?
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                item = (.ul, String(trimmed.dropFirst(2)))
            } else if let marker = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                item = (.ol, String(trimmed[marker.upperBound...]))
            }
            if let item {
                flushParagraph()
                // 浅い段へ戻る
                while let last = listStack.last, indent < last.indent { closeLists(to: listStack.count - 1); _ = last }
                if let last = listStack.last, indent > last.indent {
                    // 開いている項目の中に入れ子のリストを始める
                    listStack.append((item.kind, indent))
                    itemOpen.append(false)
                    out.append(item.kind == .ul ? "<ul>" : "<ol>")
                } else if let last = listStack.last, last.kind != item.kind {
                    closeLists(to: listStack.count - 1)
                    listStack.append((item.kind, indent))
                    itemOpen.append(false)
                    out.append(item.kind == .ul ? "<ul>" : "<ol>")
                } else if listStack.isEmpty {
                    listStack.append((item.kind, indent))
                    itemOpen.append(false)
                    out.append(item.kind == .ul ? "<ul>" : "<ol>")
                }
                if itemOpen[itemOpen.count - 1] { out.append("</li>") }
                out.append("<li>\(inlineMarkdown(item.text))")
                itemOpen[itemOpen.count - 1] = true
                continue
            }
            if !listStack.isEmpty, indent > 0, itemOpen.last == true {
                // 項目の続きの行
                out.append("<br>\(inlineMarkdown(trimmed))")
                continue
            }
            closeLists(to: 0)
            if trimmed.hasPrefix(">") {
                flushParagraph()
                out.append("<blockquote>\(inlineMarkdown(String(trimmed.drop(while: { $0 == ">" || $0 == " " }))))</blockquote>")
                continue
            }
            paragraph.append(trimmed)
        }
        flushParagraph()
        closeLists(to: 0)
        return out.joined(separator: "\n")
    }

    /// 行内の Markdown（`code`、**強調**、*斜体*、[文字](https://…)）。先にエスケープしてから置き換える。
    public static func inlineMarkdown(_ text: String) -> String {
        // コードの中身は他の置き換えから外す
        var codes: [String] = []
        var escaped = escape(text)
        escaped = replace(escaped, pattern: "`([^`]+)`") { groups in
            codes.append("<code>\(groups[1])</code>")
            return "\u{0}\(codes.count - 1)\u{0}"
        }
        escaped = replace(escaped, pattern: #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#) { groups in
            "<a href=\"\(groups[2])\" rel=\"noopener noreferrer\">\(groups[1])</a>"
        }
        escaped = replace(escaped, pattern: #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        escaped = replace(escaped, pattern: #"__(.+?)__"#) { "<strong>\($0[1])</strong>" }
        escaped = replace(escaped, pattern: #"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])"#) { "<em>\($0[1])</em>" }
        escaped = replace(escaped, pattern: "\u{0}(\\d+)\u{0}") { codes[Int($0[1])!] }
        return escaped
    }

    static func replace(_ text: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - 言葉

    struct Labels {
        let language: MeetingLanguage
        init(_ language: MeetingLanguage) { self.language = language }
        var ja: Bool { language == .ja }

        var eyebrow: String { ja ? "議事録" : "Meeting notes" }
        var contents: String { ja ? "目次" : "Contents" }
        var summary: String { ja ? "要約" : "Summary" }
        var noSummary: String { ja ? "（要約なし）" : "(No summary)" }
        var decisions: String { ja ? "決定事項" : "Decisions" }
        var actions: String { ja ? "アクション" : "Action items" }
        var openQuestions: String { ja ? "未決・論点" : "Open questions" }
        var notes: String { ja ? "メモ" : "Notes" }
        var transcript: String { ja ? "全文" : "Transcript" }
        var utterances: String { ja ? "発言" : "Utterances" }
        var none: String { ja ? "（なし）" : "(None)" }
        var due: String { ja ? "期限" : "Due" }
        var doneLabel: String { ja ? "完了" : "Done" }
        var todoLabel: String { ja ? "未完了" : "To do" }
        var jumpToEvidence: String { ja ? "根拠の発言へ" : "Jump to the source" }
        var filterPlaceholder: String { ja ? "全文を絞り込む" : "Filter the transcript" }
        var openInMinutes: String { ja ? "Minutes で開く" : "Open in Minutes" }
        func generated(_ date: String) -> String { ja ? "\(date) に Minutes で作成" : "Generated by Minutes on \(date)" }

        func kind(_ kind: MinutesSummary.ActionKind) -> String {
            switch kind {
            case .ownCommitment: ja ? "自分のタスク" : "Mine"
            case .theirTask: ja ? "相手のタスク" : "Theirs"
            case .delegable: ja ? "委任できる" : "Delegable"
            }
        }

        /// 担当の表示。種別と同じことを言うだけのときは出さない（アプリの表示と同じ）。
        func owner(_ owner: String, kind: MinutesSummary.ActionKind, selfName: String) -> String? {
            switch owner {
            case "": return nil
            case "me": return kind == .ownCommitment ? nil : selfName
            case "agent": return kind == .delegable ? nil : (ja ? "エージェント" : "Agent")
            default: return owner
            }
        }
    }

    // MARK: - CSS / JS

    static let stylesheet = """
    :root{--bg:#f7f6f2;--card:#fffefb;--ink:#1f1e1b;--muted:#6b6a64;--faint:#9a988f;--line:#e7e4dc;--soft:#f0eee7;--accent:#c96442;--accent-soft:#f6e6de;--blue:#2f6fd1;--blue-soft:#e3ecfb;--violet:#7a55c7;--violet-soft:#eee7fa;--green:#2f8a57;--mark:#fff1a8;
    --s0:#c96442;--s1:#2f6fd1;--s2:#2f8a57;--s3:#7a55c7;--s4:#b07d12;--s5:#c2417a;--s6:#178a8a;--s7:#6b6a64;
    --radius:14px;font-family:-apple-system,BlinkMacSystemFont,"Hiragino Sans","Hiragino Kaku Gothic ProN","Segoe UI","Noto Sans JP",system-ui,sans-serif;color-scheme:light dark}
    @media (prefers-color-scheme:dark){:root{--bg:#1d1c1a;--card:#262522;--ink:#ecebe6;--muted:#a3a19a;--faint:#77756e;--line:#3a3833;--soft:#2f2e2a;--accent:#e08a68;--accent-soft:#3d2a22;--blue:#7aa7ef;--blue-soft:#22324a;--violet:#b39af0;--violet-soft:#33294a;--green:#6cc493;--mark:#5c5220;
    --s0:#e08a68;--s1:#7aa7ef;--s2:#6cc493;--s3:#b39af0;--s4:#e0b04e;--s5:#ea7fae;--s6:#5ccaca;--s7:#a3a19a}}
    *{box-sizing:border-box}
    html{-webkit-text-size-adjust:100%}
    body{margin:0;background:var(--bg);color:var(--ink);font-size:15.5px;line-height:1.75;-webkit-font-smoothing:antialiased}
    .page{max-width:820px;margin:0 auto;padding:48px 20px 64px}
    a{color:var(--blue);text-decoration:none}
    a:hover{text-decoration:underline}
    .hero{margin-bottom:24px}
    .eyebrow{margin:0 0 6px;font-size:12.5px;font-weight:600;letter-spacing:.08em;color:var(--accent);text-transform:uppercase}
    h1{margin:0 0 8px;font-size:30px;line-height:1.3;font-weight:700;letter-spacing:-.01em;text-wrap:balance}
    .meta{margin:0;color:var(--muted);font-size:14px;display:flex;flex-wrap:wrap;gap:4px 0}
    .meta .dot{margin:0 8px;color:var(--faint)}
    .chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:14px}
    .chip{font-size:12.5px;line-height:1;padding:6px 10px;border-radius:999px;background:var(--soft);color:var(--muted);border:1px solid var(--line)}
    .chip.tag{background:transparent}
    .stats{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:0 0 20px}
    .stat{display:flex;flex-direction:column;gap:2px;padding:14px 16px;border-radius:var(--radius);background:var(--card);border:1px solid var(--line);color:var(--ink);transition:border-color .15s,transform .15s}
    .stat:hover{text-decoration:none;border-color:var(--accent);transform:translateY(-1px)}
    .stat strong{font-size:24px;line-height:1.2;font-variant-numeric:tabular-nums}
    .stat span{font-size:12.5px;color:var(--muted)}
    .card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:22px 24px;margin:0 0 14px;scroll-margin-top:16px}
    h2{display:flex;align-items:center;gap:8px;margin:0 0 12px;font-size:17px;line-height:1.4;font-weight:700}
    .count{font-size:12px;font-weight:600;color:var(--muted);background:var(--soft);border-radius:999px;padding:2px 8px;font-variant-numeric:tabular-nums}
    .empty{margin:0;color:var(--faint)}
    .prose>:first-child{margin-top:0}.prose>:last-child{margin-bottom:0}
    .prose p{margin:0 0 .8em}
    .prose h3,.prose h4,.prose h5,.prose h6{margin:1.2em 0 .4em;font-size:15.5px}
    .prose ul,.prose ol{margin:0 0 .8em;padding-left:1.4em}
    .prose li{margin:.2em 0}
    .prose li::marker{color:var(--faint)}
    .prose blockquote{margin:0 0 .8em;padding:2px 14px;border-left:3px solid var(--line);color:var(--muted)}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.88em;background:var(--soft);padding:1px 5px;border-radius:5px}
    .items{list-style:none;margin:0;padding:0}
    .items>li{position:relative;padding:10px 0;border-top:1px solid var(--line)}
    .items>li:first-child{border-top:0;padding-top:2px}
    .items>li:last-child{padding-bottom:0}
    .decisions{counter-reset:d}
    .decisions>li{padding-left:34px;counter-increment:d}
    .decisions>li::before{content:counter(d);position:absolute;left:0;top:11px;width:22px;height:22px;border-radius:7px;background:var(--accent-soft);color:var(--accent);font-size:12px;font-weight:700;display:grid;place-items:center}
    .decisions>li:first-child::before{top:3px}
    .questions>li{padding-left:22px}
    .questions>li::before{content:"?";position:absolute;left:0;top:10px;font-weight:700;color:var(--violet)}
    .questions>li:first-child::before{top:2px}
    .actions>li{display:flex;gap:12px;align-items:flex-start}
    .check{flex:none;width:18px;height:18px;margin-top:4px;border-radius:5px;border:1.5px solid var(--faint);display:grid;place-items:center;font-size:12px;font-weight:700;color:#fff}
    .done .check{background:var(--green);border-color:var(--green)}
    .done .text{color:var(--muted);text-decoration:line-through;text-decoration-color:var(--faint)}
    .body{min-width:0}
    .badges{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin-top:4px}
    .badge{font-size:11.5px;line-height:1;padding:4px 8px;border-radius:6px;background:var(--soft);color:var(--muted);white-space:nowrap}
    .kind-own_commitment{background:var(--accent-soft);color:var(--accent)}
    .kind-their_task{background:var(--blue-soft);color:var(--blue)}
    .kind-delegable{background:var(--violet-soft);color:var(--violet)}
    .evs{display:inline-flex;flex-wrap:wrap;gap:4px;margin-left:6px;vertical-align:1px}
    .badges .evs{margin-left:0}
    .ev{font-size:11.5px;line-height:1;padding:4px 6px;border-radius:6px;border:1px solid var(--line);color:var(--muted);font-variant-numeric:tabular-nums}
    a.ev:hover{text-decoration:none;color:var(--blue);border-color:var(--blue)}
    .ev-missing{opacity:.6}
    details>summary{list-style:none;cursor:pointer;display:flex;align-items:center;justify-content:space-between}
    details>summary::-webkit-details-marker{display:none}
    details>summary h2{margin:0}
    .toggle{width:9px;height:9px;border-right:2px solid var(--faint);border-bottom:2px solid var(--faint);transform:rotate(45deg);transition:transform .2s;margin-right:4px}
    details[open] .toggle{transform:rotate(-135deg)}
    details[open]>summary{margin-bottom:12px}
    .filter{display:flex;align-items:center;gap:10px;margin-bottom:8px}
    .filter input{flex:1;font:inherit;font-size:14px;padding:8px 12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--ink);outline:none}
    .filter input:focus{border-color:var(--blue)}
    #filter-count{font-size:12.5px;color:var(--muted);white-space:nowrap}
    .lines{list-style:none;margin:0;padding:0}
    .lines li{display:grid;grid-template-columns:64px minmax(0,1fr);column-gap:12px;padding:7px 8px;margin:0 -8px;border-radius:8px;scroll-margin-top:80px;transition:background .3s}
    .lines li[hidden]{display:none}
    .lines time{grid-row:span 2;font-size:12px;color:var(--faint);font-variant-numeric:tabular-nums;padding-top:3px}
    .lines b{font-size:12.5px;font-weight:600;color:var(--sc)}
    .lines span{white-space:pre-wrap;overflow-wrap:anywhere}
    .lines li:target,.lines li.flash{background:var(--mark)}
    .lines mark{background:var(--mark);color:inherit;border-radius:3px;padding:0 1px}
    .s0{--sc:var(--s0)}.s1{--sc:var(--s1)}.s2{--sc:var(--s2)}.s3{--sc:var(--s3)}.s4{--sc:var(--s4)}.s5{--sc:var(--s5)}.s6{--sc:var(--s6)}.s7{--sc:var(--s7)}
    footer{display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;margin-top:24px;font-size:12.5px;color:var(--faint)}
    @media (max-width:600px){.page{padding:28px 16px 48px}h1{font-size:24px}.stats{grid-template-columns:repeat(2,1fr)}.card{padding:18px}.lines li{grid-template-columns:52px minmax(0,1fr)}}
    @media print{:root{--bg:#fff;--card:#fff}body{font-size:11pt}.page{padding:0;max-width:none}.stats,.filter,footer a,.toggle{display:none}.card{break-inside:avoid-page;border-color:#ddd}.transcript{break-inside:auto}a{color:inherit}.lines li{break-inside:avoid}}
    """

    /// 根拠のリンクで全文を開き、すぐその発言へ移って光らせる（全文は数百行あるので流さない）。全文の絞り込み（大文字小文字を区別しない）。
    static let script = """
    (function(){
    var d=document.querySelector('#transcript details');
    function reveal(){var h=decodeURIComponent(location.hash.slice(1));if(h.indexOf('seg-')!==0)return;var el=document.getElementById(h);if(!el)return;if(d&&!d.open)d.open=true;var f=document.getElementById('filter');if(f&&f.value){f.value='';f.dispatchEvent(new Event('input'))}el.hidden=false;el.classList.remove('flash');void el.offsetWidth;el.classList.add('flash');requestAnimationFrame(function(){el.scrollIntoView({block:'center',behavior:'instant'})});setTimeout(function(){el.classList.remove('flash')},2400)}
    window.addEventListener('hashchange',reveal);reveal();
    window.addEventListener('beforeprint',function(){if(d)d.open=true});
    var input=document.getElementById('filter');if(!input)return;
    var rows=[].slice.call(document.querySelectorAll('.lines li'));
    rows.forEach(function(r){var s=r.querySelector('span');r._t=s.textContent;r._s=s});
    var count=document.getElementById('filter-count');
    function esc(t){return t.replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
    input.addEventListener('input',function(){var q=input.value.trim().toLowerCase();var n=0;
    rows.forEach(function(r){var name=r.querySelector('b').textContent.toLowerCase();var t=r._t;var i=q?t.toLowerCase().indexOf(q):-1;var hit=!q||i>=0||name.indexOf(q)>=0;r.hidden=!hit;if(hit)n++;
    if(q&&i>=0){var out='',p=0,lt=t.toLowerCase();while((i=lt.indexOf(q,p))>=0){out+=esc(t.slice(p,i))+'<mark>'+esc(t.slice(i,i+q.length))+'</mark>';p=i+q.length}r._s.innerHTML=out+esc(t.slice(p))}else{r._s.textContent=t}});
    count.textContent=q?n+' / '+rows.length:''});
    })();
    """
}
