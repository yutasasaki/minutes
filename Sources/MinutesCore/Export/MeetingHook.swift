import Foundation

/// 議事録ができたあとに呼ぶフック。後処理の「書き出し・同期」で、書き出しフォルダを作った直後に送る（SPEC §9.1 の同期先の 1 つ）。
/// 送るのはクラウド OK の会議だけ（ローカル専用の会議は書き出しと同じく送らない）。
/// 失敗したら未送信として残し、書き出しの再送（起動時と 10 分ごと）で送り直す。
public struct MeetingHook: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// URL に POST する
        case webhook
        /// シェルのコマンドを実行する（本文を標準入力に渡す）
        case command
    }

    /// 送る本文の形。
    public enum Format: String, Codable, Sendable, CaseIterable {
        /// 会議の情報・要約・全文を 1 つの JSON にまとめる（`HookPayload`）
        case minutesJSON = "minutes_json"
        /// 書き出しフォルダのファイルをそのまま `{"files": {"<フォルダ>/meeting.md": "中身", …}}` で送る。
        /// minutes の書き出しを取り込める受け手（`/api/meetings/import` など）向け
        case exportFiles = "export_files"
    }

    /// いつ送るか。
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        /// 議事録ができたときに 1 回だけ（あとで要約や本文を直しても送らない。手動の「フックに送る」は送る）
        case once
        /// 議事録を直すたびに送り直す（中身が変わったときだけ。受け手は会議 ID で上書きする前提）
        case everyUpdate = "every_update"
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var enabled: Bool
    public var url: String
    public var command: String
    public var format: Format
    public var trigger: Trigger
    /// 秘密のヘッダーの名前（Authorization、X-API-Token など）。値は Keychain（`keychainAccount`）に置く。空なら付けない。
    public var secretHeaderName: String
    /// `secretHeaderName` が Authorization のとき、値の前に "Bearer " を付ける。
    public var bearerPrefix: Bool
    /// 本文に足す JSON（オブジェクト）。受け手の分類などに使う（例: {"tags": ["定例"]}）。空なら足さない。
    public var extraJSON: String
    /// 全文（transcript.json）を本文に含める。
    public var includeTranscript: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String = "", kind: Kind = .webhook, enabled: Bool = true, url: String = "", command: String = "",
                format: Format = .minutesJSON, trigger: Trigger = .once, secretHeaderName: String = "Authorization", bearerPrefix: Bool = true,
                extraJSON: String = "", includeTranscript: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.url = url
        self.command = command
        self.format = format
        self.trigger = trigger
        self.secretHeaderName = secretHeaderName
        self.bearerPrefix = bearerPrefix
        self.extraJSON = extraJSON
        self.includeTranscript = includeTranscript
    }

    /// 足りないキーは既定値で読む（設定の旧い版・手で書いた settings.json）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MeetingHook(id: "")
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? defaults.kind
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        format = (try? container.decodeIfPresent(String.self, forKey: .format)).flatMap(Format.init(rawValue:)) ?? defaults.format
        trigger = (try? container.decodeIfPresent(String.self, forKey: .trigger)).flatMap(Trigger.init(rawValue:)) ?? defaults.trigger
        secretHeaderName = try container.decodeIfPresent(String.self, forKey: .secretHeaderName) ?? defaults.secretHeaderName
        bearerPrefix = try container.decodeIfPresent(Bool.self, forKey: .bearerPrefix) ?? defaults.bearerPrefix
        extraJSON = try container.decodeIfPresent(String.self, forKey: .extraJSON) ?? ""
        includeTranscript = try container.decodeIfPresent(Bool.self, forKey: .includeTranscript) ?? defaults.includeTranscript
    }

    /// export_log の target。
    public var targetId: String { MeetingHook.targetPrefix + id }
    public static let targetPrefix = "hook:"
    /// 秘密のヘッダーの値を置く Keychain のアカウント。
    public var keychainAccount: String { "hook.\(id)" }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .webhook: return URL(string: url)?.host() ?? "Webhook"
        case .command: return "コマンド"
        }
    }

    /// 送れる形になっているか（URL・コマンドが入っているか）。
    public var isConfigured: Bool {
        switch kind {
        case .webhook:
            guard let url = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "https" || scheme == "http") && url.host() != nil
        case .command:
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 送り先が変わったら書き出しをやり直す（`SyncTarget.cacheIdentity`）。
    public var cacheIdentity: String {
        [targetId, kind.rawValue, kind == .webhook ? url : command, format.rawValue, trigger.rawValue, secretHeaderName,
         String(bearerPrefix), extraJSON, String(includeTranscript)].joined(separator: "|")
    }
}

public enum HookError: Error, LocalizedError, Equatable {
    case notConfigured(String)
    case invalidExtraJSON
    case httpStatus(Int, String)
    case commandFailed(Int32, String)
    case timedOut(Int)
    case meetingNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .notConfigured(name): return "フック「\(name)」の送り先が設定されていません"
        case .invalidExtraJSON: return "本文に足す JSON が JSON のオブジェクトになっていません"
        case let .httpStatus(code, body): return "送り先が \(code) を返しました" + (body.isEmpty ? "" : ": \(body)")
        case let .commandFailed(code, stderr): return "コマンドが終了コード \(code) で終わりました" + (stderr.isEmpty ? "" : ": \(stderr)")
        case let .timedOut(seconds): return "\(seconds) 秒で終わりませんでした"
        case let .meetingNotFound(id): return "会議 \(id) が見つかりません"
        }
    }
}

// MARK: - 本文

/// フックに送る本文。
public struct HookPayload: Sendable {
    public static let schemaVersion = 1
    public static let event = "meeting.minutes_ready"

    public var body: Data
    /// 中身の指紋（送った時刻など、送るたびに変わる値を除く）。同じ中身を送り直さないために使う。
    public var contentHash: String

    public init(body: Data, contentHash: String) {
        self.body = body
        self.contentHash = contentHash
    }

    /// 書き出しフォルダ（`MeetingExporter` の出力）から本文を作る。
    public static func build(hook: MeetingHook, meeting: MeetingRecord, folder: URL, now: Date = Date()) throws -> HookPayload {
        var files: [String: String] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[name] = try String(contentsOf: url, encoding: .utf8)
        }
        return try build(hook: hook, meeting: meeting, folderName: folder.lastPathComponent, files: files, now: now)
    }

    /// `files` はファイル名 → 中身（meeting.md / summary.json / transcript.json / manifest.json）。
    public static func build(hook: MeetingHook, meeting: MeetingRecord, folderName: String, files: [String: String], now: Date = Date()) throws -> HookPayload {
        var files = files
        if !hook.includeTranscript { files.removeValue(forKey: "transcript.json") }
        let extra = try extraObject(hook.extraJSON)

        var body: [String: Any]
        switch hook.format {
        case .exportFiles:
            body = ["files": Dictionary(uniqueKeysWithValues: files.map { ("\(folderName)/\($0.key)", $0.value) })]
        case .minutesJSON:
            body = [
                "event": event,
                "schema_version": schemaVersion,
                "meeting": meetingObject(meeting),
                "minutes_markdown": files["meeting.md"] ?? "",
                "summary": files["summary.json"].flatMap(jsonObject) ?? NSNull(),
            ]
            if let transcript = files["transcript.json"].flatMap(jsonObject) { body["transcript"] = transcript }
        }
        for (key, value) in extra where body[key] == nil { body[key] = value }

        let hash = try MeetingExporter.sha256Hex(serialize(stableContent(body, format: hook.format)))
        if hook.format == .minutesJSON {
            body["sent_at"] = JSONCoding.iso8601Local(now)
            body["revision"] = String(hash.prefix(16))
        }
        return HookPayload(body: try serialize(body), contentHash: hash)
    }

    static func meetingObject(_ meeting: MeetingRecord) -> [String: Any] {
        var object: [String: Any] = [
            "id": meeting.id,
            "title": meeting.title,
            "started_at": JSONCoding.iso8601Local(meeting.startedAt),
            "platform": meeting.platform ?? "recording",
            "language": meeting.meetingLanguage.rawValue,
            "attendees": meeting.attendees.map { ["name": $0.name, "email": $0.email ?? ""] },
            "tags": meeting.tags,
            "url": "minutes://meeting/\(meeting.id)",
        ]
        if let ended = meeting.endedAt {
            object["ended_at"] = JSONCoding.iso8601Local(ended)
            object["duration_seconds"] = Int(max(0, ended.timeIntervalSince(meeting.startedAt)).rounded())
        }
        if let calendarTitle = meeting.calendarTitle { object["calendar_title"] = calendarTitle }
        return object
    }

    /// 送るたびに変わる値（書き出しの時刻・全文の sha256）を除いた中身。
    static func stableContent(_ body: [String: Any], format: MeetingHook.Format) -> [String: Any] {
        func stableText(_ name: String, _ text: String) -> Any {
            if name.hasSuffix("meeting.md") {
                return text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("transcript_sha256:") && !$0.hasPrefix("generated_by:") }
                    .joined(separator: "\n")
            }
            if name.hasSuffix("manifest.json") { return "" }
            if name.hasSuffix("transcript.json"), var object = jsonObject(text) as? [String: Any] {
                object.removeValue(forKey: "created_at")
                return object
            }
            return text
        }
        var body = body
        switch format {
        case .exportFiles:
            if let files = body["files"] as? [String: String] {
                body["files"] = Dictionary(uniqueKeysWithValues: files.map { ($0.key, stableText($0.key, $0.value)) })
            }
        case .minutesJSON:
            if let markdown = body["minutes_markdown"] as? String { body["minutes_markdown"] = stableText("meeting.md", markdown) }
            if var transcript = body["transcript"] as? [String: Any] {
                transcript.removeValue(forKey: "created_at")
                body["transcript"] = transcript
            }
        }
        return body
    }

    static func extraObject(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let object = jsonObject(trimmed) as? [String: Any] else { throw HookError.invalidExtraJSON }
        return object
    }

    static func jsonObject(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    static func serialize(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: - 送る

/// フックを 1 回呼ぶ。
public enum HookRunner {
    public static let webhookTimeout: TimeInterval = 60
    public static let commandTimeoutSeconds = 120

    public struct Context: Sendable {
        public var meetingId: String
        public var meetingTitle: String
        /// 書き出しフォルダ（コマンドに `MINUTES_EXPORT_DIR` として渡す）。テスト送信では nil。
        public var exportDirectory: URL?
        public var event: String

        public init(meetingId: String, meetingTitle: String, exportDirectory: URL?, event: String = HookPayload.event) {
            self.meetingId = meetingId
            self.meetingTitle = meetingTitle
            self.exportDirectory = exportDirectory
            self.event = event
        }
    }

    /// 送る。成功したら送り先の短い説明（HTTP の状態など）を返す。
    @discardableResult
    public static func deliver(hook: MeetingHook, payload: HookPayload, secret: String?, context: Context, session: URLSession = .shared) async throws -> String {
        guard hook.isConfigured else { throw HookError.notConfigured(hook.displayName) }
        switch hook.kind {
        case .webhook: return try await post(hook: hook, payload: payload, secret: secret, context: context, session: session)
        case .command: return try await run(hook: hook, payload: payload, secret: secret, context: context)
        }
    }

    /// 送る HTTP リクエスト（テストで中身を確かめる）。
    public static func request(hook: MeetingHook, payload: HookPayload, secret: String?, context: Context) throws -> URLRequest {
        guard let url = URL(string: hook.url.trimmingCharacters(in: .whitespaces)) else { throw HookError.notConfigured(hook.displayName) }
        var request = URLRequest(url: url, timeoutInterval: webhookTimeout)
        request.httpMethod = "POST"
        request.httpBody = payload.body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Minutes", forHTTPHeaderField: "User-Agent")
        request.setValue(context.event, forHTTPHeaderField: "X-Minutes-Event")
        request.setValue(context.meetingId, forHTTPHeaderField: "X-Minutes-Meeting-Id")
        request.setValue("\(context.meetingId)-\(payload.contentHash.prefix(16))", forHTTPHeaderField: "Idempotency-Key")
        let header = hook.secretHeaderName.trimmingCharacters(in: .whitespaces)
        if !header.isEmpty, let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            let needsBearer = hook.bearerPrefix && header.caseInsensitiveCompare("Authorization") == .orderedSame
                && !secret.lowercased().hasPrefix("bearer ")
            request.setValue(needsBearer ? "Bearer \(secret)" : secret, forHTTPHeaderField: header)
        }
        return request
    }

    static func post(hook: MeetingHook, payload: HookPayload, secret: String?, context: Context, session: URLSession) async throws -> String {
        let request = try request(hook: hook, payload: payload, secret: secret, context: context)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HookError.httpStatus(status, Log.preview(text, limit: 120))
        }
        return "HTTP \(status)"
    }

    /// `/bin/zsh -lc <コマンド>`（ログインシェルなので、ターミナルと同じ PATH で動く）。本文は標準入力と `MINUTES_PAYLOAD`（ファイルのパス）で渡す。
    static func run(hook: MeetingHook, payload: HookPayload, secret: String?, context: Context) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-hook-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloadURL = directory.appendingPathComponent("payload.json")
        let stdoutURL = directory.appendingPathComponent("stdout.txt")
        let stderrURL = directory.appendingPathComponent("stderr.txt")
        try payload.body.write(to: payloadURL, options: .atomic)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", hook.command]
        process.currentDirectoryURL = context.exportDirectory ?? directory
        var environment = ProcessInfo.processInfo.environment
        environment["MINUTES_EVENT"] = context.event
        environment["MINUTES_MEETING_ID"] = context.meetingId
        environment["MINUTES_MEETING_TITLE"] = context.meetingTitle
        environment["MINUTES_PAYLOAD"] = payloadURL.path
        environment["MINUTES_EXPORT_DIR"] = context.exportDirectory?.path ?? ""
        environment["MINUTES_HOOK_SECRET"] = secret ?? ""
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: payloadURL)
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        let timeout = commandTimeoutSeconds
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if process.isRunning { process.terminate() }
            }
        }
        if process.terminationReason == .uncaughtSignal { throw HookError.timedOut(timeout) }
        guard status == 0 else {
            let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw HookError.commandFailed(status, Log.preview(stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 120))
        }
        return "exit 0"
    }
}

// MARK: - 同期先として

/// フックを同期先（`SyncTarget`）として後処理の書き出しにつなぐ。
public struct HookSyncTarget: SyncTarget {
    public let hook: MeetingHook
    let store: Store
    let secret: String?

    public init(hook: MeetingHook, store: Store, secret: String?) {
        self.hook = hook
        self.store = store
        self.secret = secret
    }

    public var id: String { hook.targetId }
    public var cacheIdentity: String { hook.cacheIdentity }

    public func upload(folder: URL, manifest: ExportManifest) async throws -> SyncReceipt {
        try await deliver(folder: folder, meetingId: manifest.meetingId, force: false)
    }

    /// `force` は送った記録があっても送る（会議の画面の「フックに送る」）。
    public func deliver(folder: URL, meetingId: String, force: Bool) async throws -> SyncReceipt {
        guard let meeting = try store.meeting(id: meetingId) else { throw HookError.meetingNotFound(meetingId) }
        let payload = try HookPayload.build(hook: hook, meeting: meeting, folder: folder)
        if !force, let receipt = try alreadyDelivered(meetingId: meetingId, contentHash: payload.contentHash) {
            return receipt
        }
        let location = try await HookRunner.deliver(
            hook: hook, payload: payload, secret: secret,
            context: .init(meetingId: meeting.id, meetingTitle: meeting.title, exportDirectory: folder)
        )
        return SyncReceipt(targetId: id, location: location, checksum: payload.contentHash, uploadedAt: Date())
    }

    /// 送らなくてよいなら、前回の受領を返す。1 回だけのフックは送った記録があれば、更新のたびのフックは中身が同じなら送らない。
    func alreadyDelivered(meetingId: String, contentHash: String) throws -> SyncReceipt? {
        let delivered = try store.exportLog(meetingId: meetingId).filter { $0.target == id && $0.exportStatus == .ok }
        guard let last = delivered.last else { return nil }
        switch hook.trigger {
        case .once: break
        case .everyUpdate: guard last.checksum == contentHash else { return nil }
        }
        return SyncReceipt(targetId: id, location: "skipped", checksum: last.checksum ?? contentHash, uploadedAt: last.exportedAt)
    }
}
