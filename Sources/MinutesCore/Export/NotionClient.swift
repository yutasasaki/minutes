import Foundation

// Notion API（Notion-Version 2026-03-11。developers.notion.com で 2026-11-18 に確認）:
// - GET  /v1/databases/{id}           → `data_sources: [{id, name}]`（列の定義は持たない）
// - GET  /v1/data_sources/{id}        → `properties: {名前: {id, name, type}}`、`title`（rich text）
// - POST /v1/pages                    → parent `{"type": "data_source_id", "data_source_id": ...}`、`properties`、
//                                       `markdown`（`children` とは排他）＋ `markdown_version: "v2"`。応答は page（`id`、`url`）
// - PATCH /v1/pages/{id}              → `properties`、`in_trash`（2026-03-11 で `archived` から改名）
// - PATCH /v1/pages/{id}/markdown     → `{"type": "replace_content", "replace_content": {"new_str": ...}, "markdown_version": "v2"}`
// - 認証は `Authorization: Bearer <token>`。rich text の 1 要素は 2000 文字まで。429 は Retry-After 秒だけ待つ。
// - エラーの本文は `{"object": "error", "status", "code", "message"}`。

/// Notion API の最小のクライアント（議事録のページを作る・更新する・ゴミ箱に移す）。
public struct NotionClient: Sendable {
    public static let apiVersion = "2026-03-11"
    public static let baseURL = URL(string: "https://api.notion.com/v1/")!

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public var token: String
    public var transport: Transport

    public init(token: String, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.token = token
        self.transport = transport
    }

    /// データソースの列（名前 → 型）。
    public struct DataSource: Sendable, Equatable {
        public var id: String
        public var name: String
        public var properties: [String: String]

        public init(id: String, name: String, properties: [String: String]) {
            self.id = id
            self.name = name
            self.properties = properties
        }
    }

    public struct Page: Sendable, Equatable {
        public var id: String
        public var url: String?
        public var inTrash: Bool
    }

    // MARK: - ID

    /// Notion の URL か ID から 32 桁の ID を取り出して UUID の形にする。
    /// URL は `https://www.notion.so/<ws>/<タイトル>-<32 桁>?v=<ビューの 32 桁>` の形で、ビューの ID ではなくパスの末尾を使う。
    public static func extractID(_ reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if let url = URL(string: trimmed), url.scheme != nil {
            candidate = url.path
        }
        let hex = Set("0123456789abcdefABCDEF")
        // 末尾から、ハイフンを除いて 32 桁の 16 進を集める
        var digits: [Character] = []
        for character in candidate.reversed() {
            if hex.contains(character) {
                digits.append(character)
                if digits.count == 32 { break }
            } else if character == "-" {
                continue
            } else {
                if !digits.isEmpty { break }
            }
        }
        guard digits.count == 32 else { return nil }
        let raw = String(digits.reversed()).lowercased()
        let parts = [raw.prefix(8), raw.dropFirst(8).prefix(4), raw.dropFirst(12).prefix(4), raw.dropFirst(16).prefix(4), raw.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    // MARK: - API

    /// データベース（またはデータソース）の URL・ID から、ページを作るデータソースを読む。
    /// データベースに複数のデータソースがあるときは最初のもの。
    public func resolveDataSource(_ reference: String) async throws -> DataSource {
        guard let id = Self.extractID(reference) else { throw NotionError.invalidReference(reference) }
        let dataSourceId: String
        do {
            let database = try await request("GET", "databases/\(id)")
            guard let sources = database["data_sources"] as? [[String: Any]], let first = sources.first, let firstId = first["id"] as? String else {
                throw NotionError.noDataSource
            }
            dataSourceId = firstId
        } catch let NotionError.api(status, _, _) where status == 404 || status == 400 {
            // データソースの ID・URL を直接渡されたとき
            dataSourceId = id
        }
        let source = try await request("GET", "data_sources/\(dataSourceId)")
        var properties: [String: String] = [:]
        for (name, value) in source["properties"] as? [String: Any] ?? [:] {
            if let type = (value as? [String: Any])?["type"] as? String { properties[name] = type }
        }
        let title = (source["title"] as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
        return DataSource(id: dataSourceId, name: title, properties: properties)
    }

    public func createPage(dataSourceId: String, properties: [String: Any], markdown: String) async throws -> Page {
        let body: [String: Any] = [
            "parent": ["type": "data_source_id", "data_source_id": dataSourceId],
            "properties": properties,
            "markdown": markdown,
            "markdown_version": "v2",
        ]
        return try Self.page(from: await request("POST", "pages", body: body))
    }

    public func updateProperties(pageId: String, properties: [String: Any]) async throws -> Page {
        try Self.page(from: await request("PATCH", "pages/\(pageId)", body: ["properties": properties]))
    }

    public func replaceContent(pageId: String, markdown: String) async throws {
        _ = try await request("PATCH", "pages/\(pageId)/markdown", body: [
            "type": "replace_content",
            "replace_content": ["new_str": markdown, "allow_deleting_content": false],
            "markdown_version": "v2",
        ])
    }

    public func trashPage(pageId: String) async throws {
        _ = try await request("PATCH", "pages/\(pageId)", body: ["in_trash": true])
    }

    static func page(from json: [String: Any]) throws -> Page {
        guard let id = json["id"] as? String else { throw NotionError.unexpectedResponse }
        return Page(id: id, url: json["url"] as? String, inTrash: (json["in_trash"] as? Bool) ?? (json["archived"] as? Bool) ?? false)
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil, attempt: Int = 0) async throws -> [String: Any] {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw NotionError.unexpectedResponse }
        if http.statusCode == 429, attempt < 3 {
            let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
            try await Task.sleep(for: .seconds(min(max(wait, 0.5), 30)))
            return try await self.request(method, path, body: body, attempt: attempt + 1)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw NotionError.api(status: http.statusCode, code: json["code"] as? String ?? "", message: json["message"] as? String ?? "")
        }
        return json
    }
}

public enum NotionError: Error, LocalizedError, Equatable {
    case invalidReference(String)
    case noDataSource
    case noTitleProperty
    case unexpectedResponse
    case notConfigured
    case api(status: Int, code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidReference: "Notion のデータベースの URL か ID を読み取れません"
        case .noDataSource: "Notion のデータベースにデータソースがありません"
        case .noTitleProperty: "Notion のデータベースにタイトルの列がありません"
        case .unexpectedResponse: "Notion から予期しない応答がありました"
        case .notConfigured: "Notion の連携トークンとデータベースを設定してください"
        case let .api(status, code, message):
            switch code {
            case "unauthorized": "Notion の連携トークンが正しくありません"
            case "object_not_found": "Notion のデータベースが見つかりません。データベースの「接続」にこのインテグレーションを追加してください"
            case "restricted_resource": "このインテグレーションには、そのデータベースへの権限がありません"
            default: "Notion の API がエラーを返しました（\(status) \(code)）: \(Log.preview(message, limit: 120))"
            }
        }
    }

    /// ページが Notion で消された・見つからない（作り直す）。
    var isMissingPage: Bool {
        if case let .api(status, code, _) = self { return status == 404 || code == "object_not_found" }
        return false
    }
}

// MARK: - 列の割り当て

/// データベースの列に会議の情報を入れる。列は型と名前で自動で選ぶ（ないものは入れない）。
/// - タイトル: title の列（必ず 1 つある）
/// - 日時: date の列（「日付」「日時」「Date」などの名前を優先）
/// - タグ: multi_select の列（「タグ」「Tags」など）
/// - 参加者: multi_select か rich_text の列（「参加者」「Attendees」など）
public struct NotionPropertyMapping: Sendable, Equatable {
    public var title: String
    public var date: String?
    public var tags: String?
    public var attendees: String?
    public var attendeesType: String?

    static let dateNames = ["日付", "日時", "開催日", "会議日", "date", "when", "meeting date"]
    static let tagNames = ["タグ", "tags", "tag", "ラベル", "labels"]
    static let attendeeNames = ["参加者", "出席者", "attendees", "participants", "people"]

    public init(properties: [String: String]) throws {
        func find(_ names: [String], types: [String]) -> String? {
            let candidates = properties.filter { types.contains($0.value) }.map(\.key).sorted()
            return candidates.first { names.contains($0.lowercased()) } ?? candidates.first { name in names.contains { name.lowercased().contains($0) } }
        }
        guard let title = properties.first(where: { $0.value == "title" })?.key else { throw NotionError.noTitleProperty }
        self.title = title
        // 日付は名前が合わなくても、date の列が 1 つだけならそれを使う
        let dates = properties.filter { $0.value == "date" }.map(\.key)
        date = find(Self.dateNames, types: ["date"]) ?? (dates.count == 1 ? dates[0] : nil)
        tags = find(Self.tagNames, types: ["multi_select"])
        attendees = find(Self.attendeeNames, types: ["multi_select", "rich_text"]).flatMap { $0 == tags ? nil : $0 }
        attendeesType = attendees.flatMap { properties[$0] }
    }

    /// 割り当ての説明（設定画面に出す）。
    public var summary: String {
        var parts = ["タイトル → \(title)"]
        if let date { parts.append("日時 → \(date)") }
        if let tags { parts.append("タグ → \(tags)") }
        if let attendees { parts.append("参加者 → \(attendees)") }
        return parts.joined(separator: "、")
    }

    public func properties(for meeting: MeetingRecord, attendees names: [String]) -> [String: Any] {
        func richText(_ value: String) -> [[String: Any]] { [["type": "text", "text": ["content": String(value.prefix(2000))]]] }
        // multi_select の選択肢の名前にカンマは使えない
        func options(_ values: [String]) -> [[String: Any]] {
            var seen = Set<String>()
            return values.map { $0.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .prefix(100).map { ["name": String($0.prefix(100))] }
        }
        var result: [String: Any] = [title: ["title": richText(meeting.title)]]
        if let date {
            var value: [String: Any] = ["start": JSONCoding.iso8601Local(meeting.startedAt)]
            if let ended = meeting.endedAt { value["end"] = JSONCoding.iso8601Local(ended) }
            result[date] = ["date": value]
        }
        if let tags { result[tags] = ["multi_select": options(meeting.tags)] }
        if let attendees {
            result[attendees] = attendeesType == "rich_text"
                ? ["rich_text": richText(names.joined(separator: "、"))]
                : ["multi_select": options(names)]
        }
        return result
    }
}

// MARK: - 同期先

/// 議事録を Notion のデータベースにページとして作る（SPEC §9.3）。会議が終わったら書き出しの続きで送り、
/// 2 回目からは同じページを更新する（中身が同じなら送らない）。ページを Notion で消していたら作り直す。
public struct NotionSyncTarget: SyncTarget {
    public static let targetId = "notion"
    public let id = NotionSyncTarget.targetId
    public var client: NotionClient
    public var database: String
    public var store: Store
    public var selfName: String?
    public var cacheIdentity: String { id + "/" + (NotionClient.extractID(database) ?? database) }

    public init(client: NotionClient, database: String, store: Store, selfName: String?) {
        self.client = client
        self.database = database
        self.store = store
        self.selfName = selfName
    }

    public func upload(folder: URL, manifest: ExportManifest) async throws -> SyncReceipt {
        let url = try await share(meetingId: manifest.meetingId)
        return SyncReceipt(targetId: id, location: url ?? "", checksum: manifest.checksum, uploadedAt: Date())
    }

    /// 会議を Notion に送る（作る・更新する）。ページの URL を返す。ローカル専用の会議は送らない。
    @discardableResult
    public func share(meetingId: String, force: Bool = false) async throws -> String? {
        let input = try store.exportInput(meetingId: meetingId)
        guard input.meeting.privacy == .cloudOk else { throw PipelineError.localOnlyExport }
        let view = MeetingExporter.presentation(input, selfName: selfName)
        let markdown = NotionMarkdown.render(view, flavor: .api)
        let source = try await client.resolveDataSource(database)
        let mapping = try NotionPropertyMapping(properties: source.properties)
        let attendeeNames = !input.meeting.attendees.isEmpty ? input.meeting.attendees.map(\.name) : view.speakerNames
        let properties = mapping.properties(for: input.meeting, attendees: attendeeNames)
        let propertiesData = try JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys])
        let hash = MeetingExporter.sha256Hex(Data(markdown.utf8) + propertiesData + Data(source.id.utf8))

        if let ref = try store.syncRef(meetingId: meetingId, target: id) {
            if !force, ref.contentHash == hash { return ref.url }
            do {
                let page = try await client.updateProperties(pageId: ref.remoteId, properties: properties)
                if !page.inTrash {
                    try await client.replaceContent(pageId: ref.remoteId, markdown: markdown)
                    try store.saveSyncRef(SyncRefRecord(meetingId: meetingId, target: id, remoteId: ref.remoteId, url: page.url ?? ref.url, contentHash: hash))
                    Log.network.info("notion: updated \(meetingId, privacy: .public)")
                    return page.url ?? ref.url
                }
            } catch let error as NotionError where error.isMissingPage {
                // Notion でページを消した・権限を外した → 作り直す
            }
        }
        let page = try await client.createPage(dataSourceId: source.id, properties: properties, markdown: markdown)
        try store.saveSyncRef(SyncRefRecord(meetingId: meetingId, target: id, remoteId: page.id, url: page.url, contentHash: hash))
        Log.network.info("notion: created \(meetingId, privacy: .public)")
        return page.url
    }

    /// ローカル専用に切り替えたとき、Notion のページをゴミ箱に移す（30 日は Notion から戻せる）。
    public func remove(meeting: MeetingRecord) async throws -> [String] {
        guard let ref = try store.syncRef(meetingId: meeting.id, target: id) else { return [] }
        do {
            try await client.trashPage(pageId: ref.remoteId)
        } catch let error as NotionError where error.isMissingPage {}
        try store.deleteSyncRef(meetingId: meeting.id, target: id)
        return [ref.url ?? "notion:\(ref.remoteId)"]
    }
}
