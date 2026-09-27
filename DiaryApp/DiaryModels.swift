import Foundation

struct DiaryEntry: Identifiable, Codable {
    var id = UUID()
    var createdAt = Date()
    var title: String
    var content: String
    var tags: [String] = []
    var rawTranscript: String = ""
    var mergedEntryIDs: [UUID] = []

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, title, content, tags, rawTranscript, mergedEntryIDs
    }

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String, content: String, tags: [String] = [], rawTranscript: String = "", mergedEntryIDs: [UUID] = []) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.content = content
        self.tags = tags
        self.rawTranscript = rawTranscript
        self.mergedEntryIDs = mergedEntryIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        title = try values.decode(String.self, forKey: .title)
        content = try values.decode(String.self, forKey: .content)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        rawTranscript = try values.decodeIfPresent(String.self, forKey: .rawTranscript) ?? ""
        mergedEntryIDs = try values.decodeIfPresent([UUID].self, forKey: .mergedEntryIDs) ?? []
    }

    var markdown: String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "今天的日记" : title
        let date = createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN")))
        let tagLine = tags.isEmpty ? "" : "\n\n标签：" + tags.map { "#\($0)" }.joined(separator: " ")
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptSection = transcript.isEmpty ? "" : "\n\n## 口述原文\n\n\(transcript)"
        let mergedIDs = mergedEntryIDs.isEmpty ? "" : "\n\n<!-- merged-entry-ids: \(mergedEntryIDs.map(\.uuidString).joined(separator: ",")) -->"
        return "# \(heading)\n\n_\(date)_\(tagLine)\n\n## 整理后的日记\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\(transcriptSection)\(mergedIDs)\n"
    }

    var markdownFileName: String {
        "\(diaryDayKey(createdAt))-\(id.uuidString).md"
    }
}

struct PolishedDiary: Decodable {
    let title: String
    let content: String
    let tags: [String]

    private enum CodingKeys: String, CodingKey { case title, content, tags }

    init(title: String, content: String, tags: [String]) {
        self.title = title
        self.content = content
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        content = try values.decode(String.self, forKey: .content)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

func diaryDayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
