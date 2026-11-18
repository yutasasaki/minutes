import Foundation
import MinutesCore

/// 保存済みの会議を議事録の HTML（書き出しの meeting.html と同じもの）か、Notion 用の Markdown にする。
/// アプリが使っている DB を読み取り専用で開く（マイグレーション・回復をしない）ので、アプリの起動中でも使える。
enum HTMLCommand {
    static let spec = ArgumentSpec(options: ["db", "out", "latest", "format"], flags: [])

    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        let store = try Store.openReadOnly(at: parsed.value("db").map { URL(fileURLWithPath: $0) } ?? Store.defaultURL())
        let ids: [String]
        if parsed.positionals.isEmpty {
            let latest = try parsed.int("latest") ?? 1
            ids = try store.listMeetings(.all, limit: max(1, latest)).map(\.id)
        } else {
            ids = parsed.positionals
        }
        let out = URL(fileURLWithPath: parsed.value("out") ?? "html", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // 名前のない「自分」はアプリの設定の表示名で出す
        let selfName = AppSettings.load().resolvedSelfName
        // html: 書き出しの meeting.html。notion: 「Notion 用にコピー」の Markdown。notion-api: Notion API に送る Markdown
        let format = parsed.value("format") ?? "html"
        guard ["html", "notion", "notion-api"].contains(format) else {
            throw ArgumentError.invalidValue(option: "format", value: format, expected: "html | notion | notion-api")
        }
        for id in ids {
            let input = try store.exportInput(meetingId: id)
            let name = MeetingExporter.folderName(meeting: input.meeting)
            let (fileName, text): (String, String) = switch format {
            case "notion": (name + ".notion.md", NotionMarkdown.render(MeetingExporter.presentation(input, selfName: selfName), flavor: .paste))
            case "notion-api": (name + ".notion-api.md", NotionMarkdown.render(MeetingExporter.presentation(input, selfName: selfName), flavor: .api))
            default: (name + ".html", MeetingExporter.renderHTML(input, selfName: selfName))
            }
            let url = out.appendingPathComponent(fileName)
            try Data(text.utf8).write(to: url, options: .atomic)
            Console.out(url.path)
        }
    }
}
