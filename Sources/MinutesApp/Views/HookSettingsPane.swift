import AppKit
import MinutesCore
import SwiftUI

// MARK: - フック

/// 議事録ができたあとに呼ぶフック（Webhook・コマンド）の設定。送るのはクラウド OK の会議だけ。
struct HookSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AppSettings
    @State private var pendingDelete: MeetingHook?

    var body: some View {
        Form {
            Section {
                if draft.hooks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("フックはまだありません")
                            .font(.headline)
                        Text("議事録ができたら、社内のシステムやチャットへ自動で送れます。Webhook（URL に POST）か、この Mac のコマンドを選べます。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Spacer()
                    Menu {
                        Button("Webhook（URL に POST）") { add(.webhook) }
                        Button("コマンド（シェルで実行）") { add(.command) }
                    } label: {
                        Label("フックを追加", systemImage: "plus")
                    }
                    .fixedSize()
                }
            } header: {
                Text("議事録のフック")
            } footer: {
                Text("文字起こしと要約が終わって書き出したあとに送ります。ローカル専用の会議は送りません。送れなかったら 10 分ごとに送り直し、会議の「⋯」>「フックに送る」で手動でも送れます。")
            }
            ForEach($draft.hooks) { $hook in
                HookEditorSection(hook: $hook) { pendingDelete = hook }
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
        .confirmationDialog("フック「\(pendingDelete?.displayName ?? "")」を削除しますか？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("削除", role: .destructive) {
                if let hook = pendingDelete { remove(hook) }
                pendingDelete = nil
            }
        } message: {
            Text("保存した秘密のヘッダーの値も Keychain から消します。")
        }
    }

    private func add(_ kind: MeetingHook.Kind) {
        var hook = MeetingHook(kind: kind)
        if kind == .command { hook.format = .minutesJSON }
        withAnimation(.snappy) { draft.hooks.append(hook) }
    }

    private func remove(_ hook: MeetingHook) {
        try? model.deleteHookSecret(for: hook)
        withAnimation(.snappy) { draft.hooks.removeAll { $0.id == hook.id } }
    }
}

private struct HookEditorSection: View {
    @Environment(AppModel.self) private var model
    @Binding var hook: MeetingHook
    let onDelete: () -> Void

    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    private var extraJSONInvalid: Bool {
        let trimmed = hook.extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] == nil
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: hook.kind == .webhook ? "link" : "terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(hook.enabled ? Color.accentColor : Color.secondary, in: .rect(cornerRadius: 7, style: .continuous))
                TextField("名前", text: $hook.name, prompt: Text(hook.kind == .webhook ? "例: 社内の議事録 DB" : "例: Slack に投稿"))
                    .textFieldStyle(.plain)
                    .font(.headline)
                Toggle("有効", isOn: $hook.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(hook.enabled ? "有効（議事録ができたら送ります）" : "無効")
            }

            Picker("種類", selection: $hook.kind) {
                Text("Webhook").tag(MeetingHook.Kind.webhook)
                Text("コマンド").tag(MeetingHook.Kind.command)
            }
            .pickerStyle(.segmented)

            switch hook.kind {
            case .webhook:
                TextField("URL", text: $hook.url, prompt: Text("https://example.com/api/meetings/import"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                LabeledContent("秘密のヘッダー") {
                    HStack(spacing: 6) {
                        TextField("", text: $hook.secretHeaderName, prompt: Text("Authorization"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 150)
                        HookSecretField(hook: hook)
                    }
                }
                if hook.secretHeaderName.caseInsensitiveCompare("Authorization") == .orderedSame {
                    Toggle("値の前に「Bearer 」を付ける", isOn: $hook.bearerPrefix)
                }
            case .command:
                VStack(alignment: .leading, spacing: 6) {
                    Text("コマンド")
                    TextField("", text: $hook.command, prompt: Text("curl -sf -H 'Content-Type: application/json' --data @\"$MINUTES_PAYLOAD\" https://…"), axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Text("ログインシェル（zsh -lc）で書き出しフォルダを作業場所にして実行します。本文は標準入力と $MINUTES_PAYLOAD（JSON ファイル）。ほかに $MINUTES_MEETING_ID・$MINUTES_MEETING_TITLE・$MINUTES_EXPORT_DIR・$MINUTES_HOOK_SECRET。終了コード 0 で成功、2 分で打ち切ります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("秘密の値") { HookSecretField(hook: hook) }
            }

            Picker("本文", selection: $hook.format) {
                Text("会議・要約・全文の JSON").tag(MeetingHook.Format.minutesJSON)
                Text("書き出しファイル（files）").tag(MeetingHook.Format.exportFiles)
            }
            .help("「書き出しファイル」は meeting.md・summary.json・transcript.json・manifest.json を {\"files\": {\"<フォルダ>/<ファイル>\": 中身}} で送ります。minutes の書き出しを取り込める受け手向け")
            Picker("送るとき", selection: $hook.trigger) {
                Text("議事録ができたときに 1 回").tag(MeetingHook.Trigger.once)
                Text("議事録を直すたびに（中身が変わったら）").tag(MeetingHook.Trigger.everyUpdate)
            }
            Toggle("全文（transcript.json）を含める", isOn: $hook.includeTranscript)
            VStack(alignment: .leading, spacing: 6) {
                Text("本文に足す JSON（任意）")
                TextField("", text: $hook.extraJSON, prompt: Text("{\"tags\": [\"定例\"]}"), axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                if extraJSONInvalid {
                    Label("JSON のオブジェクト（{ … }）にしてください", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.amber)
                }
            }

            HStack(spacing: 10) {
                Button {
                    runTest()
                } label: {
                    Label(testing ? "送信中…" : "テスト送信", systemImage: "paperplane")
                }
                .disabled(testing || !hook.isConfigured || extraJSONInvalid)
                .help("架空の会議を 1 件送ります（本物の会議の内容は送りません）")
                if let testResult {
                    Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(testResult.ok ? Palette.mint : Palette.record)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("削除…", role: .destructive, action: onDelete)
            }
        } header: {
            HStack {
                Text(hook.displayName)
                if !hook.isConfigured {
                    Text("送り先が未設定")
                        .font(.caption)
                        .foregroundStyle(Palette.amber)
                }
            }
        }
        .onChange(of: hook) { _, _ in testResult = nil }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let snapshot = hook
        Task {
            let result = await model.testHook(snapshot)
            testing = false
            switch result {
            case let .success(detail): testResult = (true, "送れました（\(detail)）")
            case let .failure(error): testResult = (false, error.localizedDescription)
            }
        }
    }
}

/// フックの秘密の値（トークンなど）。Keychain に置き、設定ファイルには書かない。
private struct HookSecretField: View {
    @Environment(AppModel.self) private var model
    let hook: MeetingHook
    @State private var input = ""
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 6) {
            if editing || !model.hasHookSecret(hook) {
                SecureField("", text: $input, prompt: Text("トークンを貼り付け（任意）"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(save)
                Button("保存", action: save)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editing {
                    Button("キャンセル") {
                        editing = false
                        input = ""
                    }
                }
            } else {
                Label("Keychain に保存済み", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("変更") { editing = true }
                Button("削除", role: .destructive) { try? model.deleteHookSecret(for: hook) }
            }
        }
        .help(error ?? "値は Keychain に保存します")
    }

    private func save() {
        do {
            try model.saveHookSecret(input, for: hook)
            input = ""
            editing = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
