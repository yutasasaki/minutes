import Foundation
import MinutesCore
import Testing

@Suite("MeetingHTMLRenderer")
struct MeetingHTMLRendererTests {
    func sampleInput(summaryLanguage: MeetingLanguage? = nil, excluded: Bool = false) -> MeetingExporter.Input {
        let meeting = MeetingRecord(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", title: "週次定例 <Nimbus>", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_003_600), platform: .meet, attendees: [Attendee(name: "田中")], privacyMode: .cloudOk, status: .done, tags: ["定例"], summaryLanguage: summaryLanguage)
        let speakers = [
            SpeakerRecord(id: "s0", meetingId: meeting.id, clusterLabel: "spk_0", displayName: "田中"),
            SpeakerRecord(id: "s1", meetingId: meeting.id, clusterLabel: "me", displayName: "佐藤"),
            SpeakerRecord(id: "s2", meetingId: meeting.id, clusterLabel: "spk_1", displayName: "背景", excluded: excluded),
        ]
        let segments = [
            SegmentRecord(id: 10, meetingId: meeting.id, source: .final, tStart: 0, tEnd: 2, speakerId: "s0", clusterLabel: "spk_0", text: "おはようございます <script>alert(1)</script>"),
            SegmentRecord(id: 11, meetingId: meeting.id, source: .final, tStart: 65, tEnd: 70, speakerId: "s1", clusterLabel: "me", text: "よろしくお願いします"),
            SegmentRecord(id: 12, meetingId: meeting.id, source: .final, tStart: 71, tEnd: 72, speakerId: "s2", clusterLabel: "spk_1", text: "隣の席の雑談"),
        ]
        let summary = MinutesSummary(
            summaryMd: "## 背景\n- **新機能**の方針を決めた\n  - 詳細は `docs` に\n1. 一つめ\n2. 二つめ\n\n普通の段落",
            decisions: [.init(text: "リリースは来週", evidence: [10, 99])],
            actionItems: [
                .init(text: "資料を送る", owner: "田中", kind: .theirTask, due: "2026-09-20", evidence: [11]),
                .init(text: "見積もりを出す", owner: "me", kind: .ownCommitment, due: nil, evidence: [10], done: true),
            ],
            openQuestions: [.init(text: "予算は？", evidence: [])],
            keytermsLearned: []
        )
        let notes = NotesRecord(meetingId: meeting.id, summary: summary, model: "fake / prompt v0", userNotesMd: "手書きのメモ")
        return .init(meeting: meeting, speakers: speakers, segments: segments, notes: notes, providerDescription: "elevenlabs.scribe_v2")
    }

    @Test("見出し・項目・根拠のリンク・全文を出し、本文はエスケープする")
    func rendersSections() {
        let html = MeetingExporter.renderHTML(sampleInput(), now: Date(timeIntervalSince1970: 1_800_010_000))
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<html lang=\"ja\">"))
        #expect(html.contains("<title>週次定例 &lt;Nimbus&gt;</title>"))
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("おはようございます &lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("<h2>要約</h2>"))
        #expect(html.contains("<h2>決定事項<span class=\"count\">1</span></h2>"))
        #expect(html.contains("<h2>アクション<span class=\"count\">2</span></h2>"))
        #expect(html.contains("<h2>メモ</h2>"))
        // 根拠: 全文にある発言はリンク、ない発言はリンクにしない
        #expect(html.contains("href=\"#seg-10\""))
        #expect(html.contains("<span class=\"ev ev-missing\">#99</span>"))
        #expect(html.contains("<li id=\"seg-11\" class=\"s1\"><time>00:01:05</time><b>佐藤</b><span>よろしくお願いします</span></li>"))
        // アクション: 種別・担当・期限・完了
        #expect(html.contains("相手のタスク"))
        #expect(html.contains("<span class=\"badge owner\">田中</span>"))
        #expect(html.contains("期限 2026-09-20"))
        #expect(html.contains("<li class=\"done\">"))
        // 外部のリソースを読まない
        #expect(!html.contains("<link"))
        #expect(!html.contains("src=\"http"))
        #expect(html.contains("minutes://meeting/01ARZ3NDEKTSV4RRFFQ69G5FAV"))
    }

    @Test("除外した話者（背景の声）の発言は出さない")
    func excludesBackgroundVoices() {
        #expect(MeetingExporter.renderHTML(sampleInput(excluded: false)).contains("隣の席の雑談"))
        #expect(!MeetingExporter.renderHTML(sampleInput(excluded: true)).contains("隣の席の雑談"))
    }

    @Test("名前のない話者はアプリと同じく「自分」「話者 N」で出す")
    func unnamedSpeakers() {
        var input = sampleInput()
        input.speakers = input.speakers.map { var speaker = $0; speaker.displayName = nil; return speaker }
        input.meeting.attendeesJson = nil
        let html = MeetingExporter.renderHTML(input)
        #expect(html.contains("<b>話者 1</b>"))
        #expect(html.contains("<b>自分</b>"))
        #expect(html.contains("<span class=\"chip person\">話者 1</span>"))
        #expect(!html.contains(">spk_0<"))
        // 要約が担当を話者のラベルで返したとき
        input.notes = NotesRecord(meetingId: input.meeting.id, summary: MinutesSummary(summaryMd: "", decisions: [], actionItems: [.init(text: "確認する", owner: "spk_0", kind: .theirTask, due: nil, evidence: [])], openQuestions: [], keytermsLearned: []), model: "fake")
        #expect(MeetingExporter.renderHTML(input).contains("<span class=\"badge owner\">話者 1</span>"))
        #expect(MeetingExporter.renderHTML(input, selfName: "山田").contains("<b>山田</b>"))
    }

    @Test("英語で要約した会議は英語の見出し")
    func englishLabels() {
        let html = MeetingExporter.renderHTML(sampleInput(summaryLanguage: .en))
        #expect(html.contains("<html lang=\"en\">"))
        #expect(html.contains("<h2>Summary</h2>"))
        #expect(html.contains("Action items"))
        #expect(html.contains("Theirs"))
    }

    @Test("要約の Markdown: 見出し・入れ子の箇条書き・番号・強調・コード・段落")
    func markdown() {
        let html = MeetingHTMLRenderer.markdownToHTML("## 背景\n- **新機能**の方針\n  - 詳細は `a<b>` に\n- 次\n1. 一つめ\n2. 二つめ\n\n段落 [link](https://example.com) と *斜体*\n続き")
        #expect(html == """
        <h3>背景</h3>
        <ul>
        <li><strong>新機能</strong>の方針
        <ul>
        <li>詳細は <code>a&lt;b&gt;</code> に
        </li>
        </ul>
        </li>
        <li>次
        </li>
        </ul>
        <ol>
        <li>一つめ
        </li>
        <li>二つめ
        </li>
        </ol>
        <p>段落 <a href="https://example.com" rel="noopener noreferrer">link</a> と <em>斜体</em><br>続き</p>
        """)
        // 生の HTML と javascript: のリンクは通さない
        let unsafe = MeetingHTMLRenderer.markdownToHTML("<img src=x onerror=alert(1)> [x](javascript:alert(1))")
        #expect(!unsafe.contains("<img"))
        #expect(!unsafe.contains("href=\"javascript"))
    }
}
