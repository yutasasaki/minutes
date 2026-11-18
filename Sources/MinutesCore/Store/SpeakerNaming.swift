import Foundation

/// 話者の表示名。未割当のクラスタは "spk_0" ではなく「話者 1」と出す（アプリの画面と議事録の HTML で同じ名前にする）。
public enum SpeakerNaming {
    public static func title(for speaker: SpeakerRecord?, clusterLabel: String?, selfName: String, language: MeetingLanguage = .ja) -> String {
        if let name = speaker?.displayName, !name.isEmpty { return name }
        let label = speaker?.clusterLabel ?? clusterLabel
        guard let label else { return "?" }
        let speakerWord = language == .ja ? "話者 " : "Speaker "
        if label == TrackMerger.micSpeakerLabel { return selfName }
        if label.hasPrefix("spk_"), let index = Int(label.dropFirst(4)) { return "\(speakerWord)\(index + 1)" }
        if label.hasPrefix("manual_") { return language == .ja ? "（名前なし）" : "(Unnamed)" }
        if label.hasPrefix("c"), let underscore = label.firstIndex(of: "_") { return "\(speakerWord)\(label[label.index(after: underscore)...])" }
        return label
    }
}
