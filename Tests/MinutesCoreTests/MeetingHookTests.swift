import Foundation
import MinutesCore
import Testing

@Suite("議事録のフック")
struct MeetingHookTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 架空の会議（本文・要約つき、完了済み）を作る。
    private func makeMeeting(_ store: Store, privacy: PrivacyMode = .cloudOk) throws -> MeetingRecord {
        let meeting = try store.createMeeting(MeetingRecord(title: "架空の定例", startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: Date(timeIntervalSince1970: 1_790_000_600),
                                                            platform: .zoom, attendees: [Attendee(name: "山田", email: "yamada@example.com")], privacyMode: privacy, status: .done, tags: ["定例"]))
        let segments = try store.appendSegments([
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 2, clusterLabel: "spk_0", text: "始めます"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 2, tEnd: 4, clusterLabel: "me", text: "了解です"),
        ])
        let first = Int(try #require(segments.first?.id))
        let summary = MinutesSummary(summaryMd: "架空の要約", decisions: [.init(text: "決定 A", evidence: [first])],
                                     actionItems: [.init(text: "やること", owner: "me", kind: .ownCommitment, due: nil, evidence: [first])], openQuestions: [], keytermsLearned: [])
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summary: summary, model: "fake"))
        return meeting
    }

    /// 受け取った本文を `received` に 1 行ずつ書くコマンドのフック。
    private func recordingHook(_ received: URL, trigger: MeetingHook.Trigger = .once, format: MeetingHook.Format = .minutesJSON) -> MeetingHook {
        MeetingHook(name: "記録", kind: .command, command: "{ cat; echo; } >> '\(received.path)'", format: format, trigger: trigger)
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func object(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test("会議・要約・全文の JSON: 会議の情報と要約と全文が入り、足した JSON も入る")
    func minutesJSONPayload() throws {
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        var hook = MeetingHook(kind: .webhook, url: "https://example.com/hook")
        hook.extraJSON = #"{"business": "corporate", "event": "上書きしない"}"#
        let files = ["meeting.md": "---\ntranscript_sha256: aaa\n---\n# 架空の定例", "summary.json": #"{"summary_md": "架空の要約"}"#,
                     "transcript.json": #"{"created_at": "2026-01-01T00:00:00Z", "segments": [{"text": "始めます"}]}"#]
        let payload = try HookPayload.build(hook: hook, meeting: meeting, folderName: "f", files: files)
        let body = try object(String(decoding: payload.body, as: UTF8.self))
        #expect(body["event"] as? String == HookPayload.event)
        #expect(body["business"] as? String == "corporate")
        let info = try #require(body["meeting"] as? [String: Any])
        #expect(info["id"] as? String == meeting.id)
        #expect(info["platform"] as? String == "zoom")
        #expect(info["duration_seconds"] as? Int == 600)
        #expect(info["tags"] as? [String] == ["定例"])
        #expect((body["summary"] as? [String: Any])?["summary_md"] as? String == "架空の要約")
        #expect(body["transcript"] != nil)

        // 送るたびに変わる値（送った時刻・全文の作成時刻・sha256）では指紋が変わらない
        var changed = files
        changed["meeting.md"] = "---\ntranscript_sha256: bbb\n---\n# 架空の定例"
        changed["transcript.json"] = #"{"created_at": "2026-02-02T00:00:00Z", "segments": [{"text": "始めます"}]}"#
        let again = try HookPayload.build(hook: hook, meeting: meeting, folderName: "f", files: changed, now: Date().addingTimeInterval(60))
        #expect(again.contentHash == payload.contentHash)
        // 中身が変われば変わる
        changed["summary.json"] = #"{"summary_md": "直した要約"}"#
        #expect(try HookPayload.build(hook: hook, meeting: meeting, folderName: "f", files: changed).contentHash != payload.contentHash)

        hook.includeTranscript = false
        let withoutTranscript = try object(String(decoding: try HookPayload.build(hook: hook, meeting: meeting, folderName: "f", files: files).body, as: UTF8.self))
        #expect(withoutTranscript["transcript"] == nil)
    }

    @Test("書き出しファイル: {\"files\": {\"<フォルダ>/<ファイル>\": 中身}} で送る")
    func exportFilesPayload() throws {
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        let hook = MeetingHook(kind: .webhook, url: "https://example.com/import", format: .exportFiles, extraJSON: #"{"tags": ["議事録"]}"#)
        let payload = try HookPayload.build(hook: hook, meeting: meeting, folderName: "2026-09-21_1000_x_abcd1234",
                                            files: ["meeting.md": "# x", "summary.json": "{}", "manifest.json": "{}"])
        let body = try object(String(decoding: payload.body, as: UTF8.self))
        let files = try #require(body["files"] as? [String: String])
        #expect(Set(files.keys) == ["2026-09-21_1000_x_abcd1234/meeting.md", "2026-09-21_1000_x_abcd1234/summary.json", "2026-09-21_1000_x_abcd1234/manifest.json"])
        #expect(body["tags"] as? [String] == ["議事録"])
        #expect(body["event"] == nil)
    }

    @Test("足す JSON がオブジェクトでなければ送らない")
    func invalidExtraJSON() throws {
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        let hook = MeetingHook(kind: .webhook, url: "https://example.com", extraJSON: "[1, 2]")
        #expect(throws: HookError.invalidExtraJSON) { try HookPayload.build(hook: hook, meeting: meeting, folderName: "f", files: [:]) }
    }

    @Test("Webhook のヘッダー: Authorization には Bearer を付け、ほかのヘッダーにはそのまま")
    func webhookHeaders() throws {
        let payload = HookPayload(body: Data("{}".utf8), contentHash: String(repeating: "a", count: 64))
        let context = HookRunner.Context(meetingId: "M1", meetingTitle: "架空", exportDirectory: nil)
        let bearer = MeetingHook(kind: .webhook, url: "https://example.com/hook")
        let request = try HookRunner.request(hook: bearer, payload: payload, secret: "tok", context: context)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "M1-aaaaaaaaaaaaaaaa")
        #expect(request.httpMethod == "POST")
        let custom = MeetingHook(kind: .webhook, url: "https://example.com/hook", secretHeaderName: "X-API-Token")
        let customRequest = try HookRunner.request(hook: custom, payload: payload, secret: "tok", context: context)
        #expect(customRequest.value(forHTTPHeaderField: "X-API-Token") == "tok")
        #expect(customRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!MeetingHook(kind: .webhook, url: "ftp://example.com").isConfigured)
    }

    @Test("1 回だけのフック: 書き出しを更新しても送り直さず、手動の「フックに送る」では送る")
    func onceTrigger() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        let received = root.appendingPathComponent("received.jsonl")
        let hook = recordingHook(received)
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: nil,
            exportDirectory: root.appendingPathComponent("export"), syncTargets: [HookSyncTarget(hook: hook, store: store, secret: nil)]))

        try await pipeline.refreshExport(meetingId: meeting.id)
        #expect(lines(received).count == 1)
        let first = try object(try #require(lines(received).first))
        #expect((first["meeting"] as? [String: Any])?["title"] as? String == "架空の定例")
        #expect(try store.latestExports(targetPrefix: MeetingHook.targetPrefix).first?.exportStatus == .ok)

        try store.updateUserNotes(meetingId: meeting.id, markdown: "あとで足したメモ")
        try await pipeline.refreshExport(meetingId: meeting.id)
        #expect(lines(received).count == 1)

        let results = try await pipeline.deliverHooks(meetingId: meeting.id)
        #expect(results.count == 1 && results[0].error == nil)
        #expect(lines(received).count == 2)
    }

    @Test("直すたびのフック: 中身が同じなら送らず、変わったら送る")
    func everyUpdateTrigger() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        let received = root.appendingPathComponent("received.jsonl")
        let hook = recordingHook(received, trigger: .everyUpdate, format: .exportFiles)
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: nil,
            exportDirectory: root.appendingPathComponent("export"), syncTargets: [HookSyncTarget(hook: hook, store: store, secret: nil)]))

        try await pipeline.refreshExport(meetingId: meeting.id)
        try await pipeline.refreshExport(meetingId: meeting.id)
        #expect(lines(received).count == 1)
        try store.updateUserNotes(meetingId: meeting.id, markdown: "直したメモ")
        try await pipeline.refreshExport(meetingId: meeting.id)
        #expect(lines(received).count == 2)
        let files = try #require(try object(lines(received)[1])["files"] as? [String: String])
        #expect(files.contains { $0.key.hasSuffix("/meeting.md") && $0.value.contains("直したメモ") })
    }

    @Test("失敗したフックは未送信として残り、再送で送る。ローカル専用の会議は送らない")
    func failureAndPrivacy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        let flag = root.appendingPathComponent("ok")
        let received = root.appendingPathComponent("received.jsonl")
        // flag が無いあいだは失敗する
        let hook = MeetingHook(kind: .command, command: "test -f '\(flag.path)' || { echo 'not yet' >&2; exit 3; }; cat >> '\(received.path)'")
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: nil,
            exportDirectory: root.appendingPathComponent("export"), syncTargets: [HookSyncTarget(hook: hook, store: store, secret: nil)]))

        try await pipeline.refreshExport(meetingId: meeting.id)
        #expect(try store.pendingExports().map(\.target) == [hook.targetId])
        let failed = try await pipeline.deliverHooks(meetingId: meeting.id)
        #expect(failed.first?.error?.contains("not yet") == true)

        FileManager.default.createFile(atPath: flag.path, contents: nil)
        _ = await pipeline.retryPendingExports()
        #expect(try store.pendingExports().isEmpty)
        #expect(lines(received).count == 1)

        let local = try makeMeeting(store, privacy: .localOnly)
        try await pipeline.refreshExport(meetingId: local.id)
        #expect(lines(received).count == 1)
        await #expect(throws: PipelineError.self) { try await pipeline.deliverHooks(meetingId: local.id) }
    }

    @Test("設定: フックの無い旧い設定・壊れたフックでもほかの設定を保つ")
    func settingsDecoding() throws {
        let old = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"audio_retention_days": 7}"#.utf8))
        #expect(old.hooks.isEmpty && old.audioRetentionDays == 7)
        var settings = AppSettings()
        settings.hooks = [MeetingHook(name: "a", kind: .webhook, url: "https://example.com"), MeetingHook(name: "b", kind: .command, enabled: false, command: "true"),
                          MeetingHook(name: "c", kind: .webhook, url: "")]
        let decoded = try JSONCoding.decoder().decode(AppSettings.self, from: JSONCoding.encoder().encode(settings))
        #expect(decoded.hooks == settings.hooks)
        #expect(decoded.activeHooks.map(\.name) == ["a"])
        let broken = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"audio_retention_days": 9, "hooks": "x"}"#.utf8))
        #expect(broken.hooks.isEmpty && broken.audioRetentionDays == 9)
        let partial = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"hooks": [{"id": "h1", "kind": "webhook", "url": "https://example.com"}]}"#.utf8))
        #expect(partial.hooks.first?.trigger == .once && partial.hooks.first?.enabled == true)
    }

    @Test("録音したアプリから会議の場を決める")
    func platformForApp() {
        #expect(MeetingPlatform.forApp(bundleIdentifier: "us.zoom.xos") == .zoom)
        #expect(MeetingPlatform.forApp(bundleIdentifier: "com.microsoft.teams2") == .teams)
        #expect(MeetingPlatform.forApp(bundleIdentifier: "com.google.Chrome") == nil)
        #expect(MeetingPlatform.forApp(bundleIdentifier: nil) == nil)
    }
}
