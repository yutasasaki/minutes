import Foundation
import MinutesCore
import Synchronization
import Testing

/// Notion API の代わり。受けた要求を記録し、決めた応答を返す。
final class FakeNotion: Sendable {
    struct Call: Sendable {
        var method: String
        var path: String
        var body: [String: String]
    }

    let calls = Mutex<[Call]>([])
    let pages = Mutex<Set<String>>([])
    let trashed = Mutex<Set<String>>([])
    let properties: [String: String]

    init(properties: [String: String] = ["名前": "title", "日付": "date", "タグ": "multi_select", "参加者": "multi_select", "状態": "status"]) {
        self.properties = properties
    }

    var transport: NotionClient.Transport {
        { [self] request in try handle(request) }
    }

    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.path.replacingOccurrences(of: "/v1/", with: "")
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        calls.withLock { $0.append(Call(method: request.httpMethod ?? "", path: path, body: body.mapValues { value in (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)" })) }
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret_test")
        func reply(_ status: Int, _ json: [String: Any]) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        switch (request.httpMethod, path) {
        case ("GET", "databases/11111111-2222-3333-4444-555555555555"):
            return try reply(200, ["object": "database", "data_sources": [["id": "ds-1", "name": "議事録"]]])
        case ("GET", "data_sources/ds-1"):
            return try reply(200, ["object": "data_source", "title": [["plain_text": "議事録"]],
                                   "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.key, ["id": $0.key, "name": $0.key, "type": $0.value]) })])
        case ("POST", "pages"):
            let id = "page-\(pages.withLock { $0.count + 1 })"
            pages.withLock { _ = $0.insert(id) }
            return try reply(200, ["object": "page", "id": id, "url": "https://www.notion.so/\(id)", "in_trash": false])
        default:
            let parts = path.split(separator: "/").map(String.init)
            guard parts.first == "pages", parts.count >= 2, pages.withLock({ $0.contains(parts[1]) }) else {
                return try reply(404, ["object": "error", "status": 404, "code": "object_not_found", "message": "Could not find page"])
            }
            if body["in_trash"] as? Bool == true { _ = trashed.withLock { $0.insert(parts[1]) } }
            if parts.count == 3 { return try reply(200, ["object": "page_markdown", "id": parts[1], "markdown": "", "truncated": false]) }
            return try reply(200, ["object": "page", "id": parts[1], "url": "https://www.notion.so/\(parts[1])", "in_trash": trashed.withLock { $0.contains(parts[1]) }])
        }
    }

    func forgetPages() { pages.withLock { $0.removeAll() } }
    var callList: [String] { calls.withLock { $0.map { "\($0.method) \($0.path)" } } }
}

@Suite("Notion")
struct NotionTests {
    @Test("URL・ID から 32 桁の ID を取り出す（ビューの ID は使わない）")
    func extractID() {
        #expect(NotionClient.extractID("https://www.notion.so/acme/Minutes-1111111122223333444455555555555?v=99999999999999999999999999999999") == nil)
        #expect(NotionClient.extractID("https://www.notion.so/acme/Minutes-11111111222233334444555555555555?v=99999999999999999999999999999999") == "11111111-2222-3333-4444-555555555555")
        #expect(NotionClient.extractID("11111111-2222-3333-4444-555555555555") == "11111111-2222-3333-4444-555555555555")
        #expect(NotionClient.extractID("https://www.notion.so/11111111222233334444555555555555") == "11111111-2222-3333-4444-555555555555")
        #expect(NotionClient.extractID("議事録") == nil)
    }

    @Test("列の割り当て: 型と名前で選び、ないものは入れない")
    func mapping() throws {
        let mapping = try NotionPropertyMapping(properties: ["Name": "title", "When": "date", "Tags": "multi_select", "Attendees": "rich_text", "Memo": "rich_text"])
        #expect(mapping.title == "Name")
        #expect(mapping.date == "When")
        #expect(mapping.tags == "Tags")
        #expect(mapping.attendees == "Attendees")
        let meeting = MeetingRecord(title: "定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000), privacyMode: .cloudOk, status: .done, tags: ["a,b", "c"])
        let properties = mapping.properties(for: meeting, attendees: ["田中", "佐藤"])
        #expect((properties["Tags"] as? [String: Any])?["multi_select"] as? [[String: String]] == [["name": "a b"], ["name": "c"]])
        #expect(((properties["Attendees"] as? [String: Any])?["rich_text"] as? [[String: Any]])?.first?["text"] as? [String: String] == ["content": "田中、佐藤"])
        #expect(try NotionPropertyMapping(properties: ["名前": "title"]).date == nil)
        #expect(throws: NotionError.self) { try NotionPropertyMapping(properties: ["日付": "date"]) }
    }

    func sampleStore() throws -> (Store, MeetingRecord) {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "週次定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_001_800), privacyMode: .cloudOk, status: .done, tags: ["定例"]))
        try store.replaceSpeakers(meetingId: meeting.id, with: [SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0"), SpeakerRecord(meetingId: meeting.id, clusterLabel: "me")])
        let segments = try store.appendSegments([
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 3, tEnd: 6, clusterLabel: "spk_0", text: "資料は *金曜* までに <送ります>"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 70, tEnd: 72, clusterLabel: "me", text: "お願いします"),
        ])
        let first = Int(segments[0].id!)
        let summary = MinutesSummary(summaryMd: "# 概要\n- 方針を決めた", decisions: [.init(text: "来週出す", evidence: [first])],
                                     actionItems: [.init(text: "資料を送る", owner: "spk_0", kind: .theirTask, due: "2026-11-20", evidence: [first]),
                                                   .init(text: "確認する", owner: "me", kind: .ownCommitment, due: nil, evidence: [], done: true)],
                                     openQuestions: [], keytermsLearned: [])
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summary: summary, model: "fake"))
        return (store, meeting)
    }

    @Test("Markdown: 貼る用は素の Markdown、API 用は全文をトグルに畳み < を逃がす")
    func markdown() throws {
        let (store, meeting) = try sampleStore()
        let view = MeetingExporter.presentation(try store.exportInput(meetingId: meeting.id))
        let paste = NotionMarkdown.render(view, flavor: .paste)
        #expect(paste.hasPrefix("# 週次定例\n\n"))
        #expect(paste.contains("## 要約\n\n### 概要\n- 方針を決めた"))
        #expect(paste.contains("1. 来週出す（00:00:03）"))
        #expect(paste.contains("- [ ] 資料を送る（相手のタスク / 担当: 話者 1 / 期限: 2026-11-20）（00:00:03）"))
        #expect(paste.contains("- [x] 確認する（自分のタスク）"))
        #expect(paste.contains("## 全文（2 発言）"))
        #expect(paste.contains("**00:00:03 話者 1**　資料は \\*金曜\\* までに <送ります>"))
        #expect(paste.contains("参加者: 自分、話者 1"))

        let api = NotionMarkdown.render(view, flavor: .api)
        #expect(!api.hasPrefix("# "))
        #expect(api.contains("<toggle heading=\"h2\">全文（2 発言）\n\n**00:00:03 話者 1**"))
        #expect(api.contains("までに \\<送ります>"))
        #expect(api.hasSuffix("お願いします\n</toggle>\n"))
    }

    @Test("同期先: 作る → 同じなら送らない → 変われば同じページを更新 → 消されていたら作り直す → ゴミ箱へ")
    func syncTarget() async throws {
        let (store, meeting) = try sampleStore()
        let fake = FakeNotion()
        let target = NotionSyncTarget(client: NotionClient(token: "secret_test", transport: fake.transport), database: "https://www.notion.so/acme/x-11111111222233334444555555555555?v=1", store: store, selfName: "佐藤")

        let url = try await target.share(meetingId: meeting.id)
        #expect(url == "https://www.notion.so/page-1")
        #expect(fake.callList == ["GET databases/11111111-2222-3333-4444-555555555555", "GET data_sources/ds-1", "POST pages"])
        let create = try #require(fake.calls.withLock { $0.last })
        #expect(create.body["markdown_version"] == "\"v2\"")
        #expect(create.body["parent"]?.contains("ds-1") == true)
        #expect(create.body["properties"]?.contains("佐藤") == true)
        #expect(create.body["properties"]?.contains("状態") == false)
        #expect(try store.syncRef(meetingId: meeting.id, target: "notion")?.remoteId == "page-1")

        // 変わっていなければ送らない（読むだけ）
        _ = try await target.share(meetingId: meeting.id)
        #expect(fake.callList.filter { $0.hasPrefix("POST") || $0.hasPrefix("PATCH") }.count == 1)

        // 変われば同じページを更新
        var renamed = meeting
        renamed.title = "週次定例（改）"
        try store.updateMeeting(renamed)
        _ = try await target.share(meetingId: meeting.id)
        #expect(Array(fake.callList.suffix(2)) == ["PATCH pages/page-1", "PATCH pages/page-1/markdown"])

        // Notion でページが消されていたら作り直す
        fake.forgetPages()
        renamed.title = "週次定例（再）"
        try store.updateMeeting(renamed)
        let recreated = try await target.share(meetingId: meeting.id)
        #expect(recreated == "https://www.notion.so/page-1")
        #expect(fake.callList.last == "POST pages")

        // ローカル専用への切り替え: ゴミ箱へ移して記録を消す
        let removed = try await target.remove(meeting: renamed)
        #expect(removed == ["https://www.notion.so/page-1"])
        #expect(fake.trashed.withLock { $0 } == ["page-1"])
        #expect(try store.syncRef(meetingId: meeting.id, target: "notion") == nil)

        // ローカル専用の会議は送らない
        renamed.privacy = .localOnly
        try store.updateMeeting(renamed)
        await #expect(throws: PipelineError.self) { try await target.share(meetingId: meeting.id) }
    }

    /// 実際の Notion に架空の会議を送る（作る → 更新 → ゴミ箱へ）。
    /// `MINUTES_NOTION_LIVE=1 MINUTES_NOTION_DATABASE=<データベースの URL> swift test --filter NotionTests.liveSmoke`（シークレットは NOTION_API_KEY）。
    @Test("実際の Notion: 作る → 更新 → ゴミ箱へ", .enabled(if: ProcessInfo.processInfo.environment["MINUTES_NOTION_LIVE"] == "1"))
    func liveSmoke() async throws {
        let token = try #require(APIKeys.resolve(APIKeys.notion, useKeychain: false))
        let database = try #require(ProcessInfo.processInfo.environment["MINUTES_NOTION_DATABASE"])
        let (store, meeting) = try sampleStore()
        let target = NotionSyncTarget(client: NotionClient(token: token), database: database, store: store, selfName: "佐藤")
        let url = try #require(try await target.share(meetingId: meeting.id))
        print("notion page: \(url)")
        var renamed = meeting
        renamed.title = "週次定例（Minutes のテスト）"
        try store.updateMeeting(renamed)
        #expect(try await target.share(meetingId: meeting.id) == url)
        if ProcessInfo.processInfo.environment["MINUTES_NOTION_KEEP"] != "1" {
            #expect(try await target.remove(meeting: renamed).count == 1)
        }
    }

    @Test("会議を消すと同期先の記録も消える")
    func cascade() throws {
        let (store, meeting) = try sampleStore()
        try store.saveSyncRef(SyncRefRecord(meetingId: meeting.id, target: "notion", remoteId: "p", url: nil, contentHash: "h"))
        try store.deleteMeeting(id: meeting.id)
        #expect(try store.syncRef(meetingId: meeting.id, target: "notion") == nil)
    }
}
