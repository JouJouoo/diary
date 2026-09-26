import SwiftUI
import Speech
import AVFoundation
import Combine
import UIKit
import Security

@main
struct DiaryApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct DiaryEntry: Identifiable, Codable {
    var id = UUID()
    var createdAt = Date()
    var title: String
    var content: String
    var tags: [String] = []

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, title, content, tags
    }

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String, content: String, tags: [String] = []) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.content = content
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        title = try values.decode(String.self, forKey: .title)
        content = try values.decode(String.self, forKey: .content)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    var markdown: String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "今天的日记" : title
        let date = createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN")))
        let tagLine = tags.isEmpty ? "" : "\n\n标签：" + tags.map { "#\($0)" }.joined(separator: " ")
        return "# \(heading)\n\n_\(date)_\(tagLine)\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    var markdownFileName: String {
        "\(diaryDayKey(createdAt)).md"
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

@MainActor
final class EntryStore: ObservableObject {
    @Published var entries: [DiaryEntry] = []
    @Published var isSyncing = false
    @Published var syncMessage = "尚未同步"
    private let fileURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diary-entries.json")

    init() { load() }

    func entries(on date: Date) -> [DiaryEntry] {
        entries.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: date) }
    }

    func upsertDaily(_ entry: DiaryEntry) {
        let sameDay = entries(on: entry.createdAt).sorted { $0.createdAt < $1.createdAt }
        let id = sameDay.first?.id ?? entry.id
        let createdAt = sameDay.first?.createdAt ?? entry.createdAt
        let dailyEntry = DiaryEntry(id: id, createdAt: createdAt, title: entry.title, content: entry.content, tags: entry.tags)
        entries.removeAll { Calendar.current.isDate($0.createdAt, inSameDayAs: createdAt) }
        entries.insert(dailyEntry, at: 0)
        entries.sort { $0.createdAt > $1.createdAt }
        save()
        saveMarkdown(dailyEntry)
    }

    func syncWithNutstore() async {
        guard !isSyncing else { return }
        let username = UserDefaults.standard.string(forKey: "nutstore_username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = NutstoreCredentialStore.password ?? ""
        guard !username.isEmpty, !password.isEmpty else {
            syncMessage = "请先填写坚果云账号和应用密码"
            return
        }
        isSyncing = true
        syncMessage = "正在同步…"
        defer { isSyncing = false }
        do {
            entries = try await NutstoreWebDAV.sync(entries: entries, username: username, password: password)
            entries.sort { $0.createdAt > $1.createdAt }
            save()
            entries.forEach(saveMarkdown)
            syncMessage = "同步完成 · \(Date().formatted(.dateTime.hour().minute()))"
        } catch {
            syncMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DiaryEntry].self, from: data) else { return }
        let groups = Dictionary(grouping: decoded) { entry in
            diaryDayKey(entry.createdAt)
        }
        entries = groups.values.map { group in
            let ordered = group.sorted { $0.createdAt < $1.createdAt }
            guard ordered.count > 1, let first = ordered.first, let latest = ordered.last else { return ordered[0] }
            return DiaryEntry(
                id: first.id,
                createdAt: first.createdAt,
                title: latest.title,
                content: ordered.map(\.content).joined(separator: "\n\n"),
                tags: Array(ordered.flatMap(\.tags).reduce(into: [String]()) { result, tag in
                    if !result.contains(tag) { result.append(tag) }
                }.prefix(2))
            )
        }.sorted { $0.createdAt > $1.createdAt }
        // Normalize older per-save files into one dated Markdown file per day.
        save()
        entries.forEach(saveMarkdown)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func saveMarkdown(_ entry: DiaryEntry) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Markdown", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let markdownURL = folder.appendingPathComponent(entry.markdownFileName)
        if (try? String(contentsOf: markdownURL, encoding: .utf8)) != entry.markdown {
            try? entry.markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        }
        let legacyPrefix = entry.markdownFileName.replacingOccurrences(of: ".md", with: "-")
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(legacyPrefix) && file.pathExtension == "md" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

private enum NutstoreCredentialStore {
    private static let service = "com.diary.liubai.nutstore"
    private static let account = "webdav-password"

    static var password: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NutstoreError.keychain }
    }
}

private enum NutstoreError: LocalizedError {
    case invalidURL, unauthorized(String), folderCreationDenied, forbidden(String), server(String, Int), keychain, invalidFile
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "坚果云 WebDAV 地址无效。"
        case .unauthorized(let method): return "坚果云的\(method)请求收到 HTTP 401，账号验证未通过。请确认用户名是注册邮箱，密码是为本应用生成的应用密码。"
        case .folderCreationDenied: return "账号已连上坚果云，但应用无法自动创建“留白日记”文件夹。请在坚果云根目录手动新建同名文件夹，再点立即同步。"
        case .forbidden(let operation): return "账号已连上坚果云，但没有权限\(operation)。"
        case .server(let operation, let status): return "坚果云\(operation)失败（\(status)）。"
        case .keychain: return "坚果云密码保存失败，请重试。"
        case .invalidFile: return "云端日记文件无法读取。"
        }
    }
}

private struct NutstoreRemoteFile {
    let name: String
    let modifiedAt: Date?
}

private enum NutstoreWebDAV {
    private static let endpoint = "https://dav.jianguoyun.com/dav/"
    private static let folderName = "留白日记"
    private static let markdownFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Markdown", isDirectory: true)

    static func sync(entries: [DiaryEntry], username: String, password: String) async throws -> [DiaryEntry] {
        let endpoint = UserDefaults.standard.string(forKey: "nutstore_endpoint") ?? endpoint
        guard let root = URL(string: endpoint), var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else {
            throw NutstoreError.invalidURL
        }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let normalizedRoot = components.url else { throw NutstoreError.invalidURL }
        let folder = normalizedRoot.appendingPathComponent(folderName, isDirectory: true)
        let (_, rootResponse) = try await request(normalizedRoot, method: "PROPFIND", username: username, password: password, depth: "0")
        guard rootResponse.statusCode == 207 || rootResponse.statusCode == 200 else {
            if rootResponse.statusCode == 403 { throw NutstoreError.forbidden("访问 WebDAV 根目录") }
            throw NutstoreError.server("验证 WebDAV 根目录", rootResponse.statusCode)
        }
        try await ensureFolder(folder, username: username, password: password)
        var localEntries = Dictionary(uniqueKeysWithValues: entries.map { (diaryDayKey($0.createdAt), $0) })
        let remoteFiles = try await listFiles(folder, username: username, password: password)
        var remoteNames = Set<String>()

        for remote in remoteFiles where remote.name.hasSuffix(".md") {
            remoteNames.insert(remote.name)
            let dayKey = String(remote.name.dropLast(3))
            guard dayKey.count == 10 else { continue }
            let localURL = markdownFolder.appendingPathComponent(remote.name)
            let localEntry = localEntries[dayKey]
            let localDate = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.modificationDate]) as? Date
            let remoteIsNewer = remote.modifiedAt.flatMap { remoteDate in localDate.map { remoteDate.timeIntervalSince($0) > 2 } } ?? false

            if localEntry == nil || remoteIsNewer {
                let markdown = try await download(folder.appendingPathComponent(remote.name), username: username, password: password)
                if let entry = parse(markdown, dayKey: dayKey) {
                    localEntries[dayKey] = entry
                    try markdown.write(to: localURL, atomically: true, encoding: .utf8)
                }
            } else if let localEntry {
                let localMarkdown = (try? String(contentsOf: localURL, encoding: .utf8)) ?? localEntry.markdown
                let remoteMarkdown = try await download(folder.appendingPathComponent(remote.name), username: username, password: password)
                if remoteMarkdown != localMarkdown {
                    try await upload(localMarkdown, to: folder.appendingPathComponent(remote.name), username: username, password: password)
                }
            }
        }

        for (dayKey, entry) in localEntries where !remoteNames.contains("\(dayKey).md") {
            try await upload(entry.markdown, to: folder.appendingPathComponent(entry.markdownFileName), username: username, password: password)
        }
        return Array(localEntries.values)
    }

    private static func request(_ url: URL, method: String, username: String, password: String, body: Data? = nil, contentType: String? = nil, depth: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NutstoreError.server("请求", 0) }
        if http.statusCode == 401 { throw NutstoreError.unauthorized(method) }
        return (data, http)
    }

    private static func ensureFolder(_ folder: URL, username: String, password: String) async throws {
        let (_, response) = try await request(folder, method: "PROPFIND", username: username, password: password, depth: "0")
        if response.statusCode == 207 || response.statusCode == 200 { return }
        guard response.statusCode == 404 else {
            if response.statusCode == 403 { throw NutstoreError.forbidden("访问“留白日记”目录") }
            throw NutstoreError.server("检查“留白日记”目录", response.statusCode)
        }
        let (_, createResponse) = try await request(folder, method: "MKCOL", username: username, password: password)
        guard (200..<300).contains(createResponse.statusCode) || createResponse.statusCode == 405 else {
            if createResponse.statusCode == 403 { throw NutstoreError.folderCreationDenied }
            throw NutstoreError.server("创建“留白日记”目录", createResponse.statusCode)
        }
    }

    private static func listFiles(_ folder: URL, username: String, password: String) async throws -> [NutstoreRemoteFile] {
        let body = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:getlastmodified/><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (data, response) = try await request(folder, method: "PROPFIND", username: username, password: password, body: body, contentType: "application/xml; charset=utf-8", depth: "1")
        guard response.statusCode == 207 || response.statusCode == 200 else {
            if response.statusCode == 403 { throw NutstoreError.forbidden("读取“留白日记”目录") }
            throw NutstoreError.server("读取“留白日记”目录", response.statusCode)
        }
        let parser = WebDAVListingParser(folderURL: folder)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw NutstoreError.invalidFile }
        return parser.files
    }

    private static func download(_ url: URL, username: String, password: String) async throws -> String {
        let (data, response) = try await request(url, method: "GET", username: username, password: password)
        guard response.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw NutstoreError.server("下载日记", response.statusCode)
        }
        return text
    }

    private static func upload(_ markdown: String, to url: URL, username: String, password: String) async throws {
        let (_, response) = try await request(url, method: "PUT", username: username, password: password, body: Data(markdown.utf8), contentType: "text/markdown; charset=utf-8")
        guard response.statusCode == 200 || response.statusCode == 201 || response.statusCode == 204 else {
            if response.statusCode == 403 { throw NutstoreError.forbidden("上传日记") }
            throw NutstoreError.server("上传日记", response.statusCode)
        }
    }

    private static func parse(_ markdown: String, dayKey: String) -> DiaryEntry? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("# "),
              let date = dateFromKey(dayKey) else { return nil }
        let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        var contentStart = 1
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("标签：") {
                tags = line.dropFirst("标签：".count).split(whereSeparator: \.isWhitespace)
                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                contentStart = index + 1
            } else if line.hasPrefix("_") && line.hasSuffix("_") {
                contentStart = index + 1
            }
        }
        while contentStart < lines.count && lines[contentStart].isEmpty { contentStart += 1 }
        let content = lines.dropFirst(contentStart).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return DiaryEntry(createdAt: date, title: title.isEmpty ? "今天的日记" : title, content: content, tags: Array(tags.prefix(2)))
    }

    private static func dateFromKey(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}

private final class WebDAVListingParser: NSObject, XMLParserDelegate {
    private let folderURL: URL
    private var currentElement = ""
    private var href = ""
    private var lastModified = ""
    private var isCollection = false
    private var responseDepth = 0
    private(set) var files: [NutstoreRemoteFile] = []

    init(folderURL: URL) { self.folderURL = folderURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        if currentElement == "response" { responseDepth += 1; href = ""; lastModified = ""; isCollection = false }
        if currentElement == "collection" { isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "href": href += string
        case "getlastmodified": lastModified += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        if name == "response" {
            defer { responseDepth = max(0, responseDepth - 1) }
            guard !isCollection, let url = URL(string: href, relativeTo: folderURL),
                  url.deletingLastPathComponent().standardizedFileURL == folderURL.standardizedFileURL else { return }
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            files.append(NutstoreRemoteFile(name: url.lastPathComponent, modifiedAt: dateFormatter.date(from: lastModified.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        currentElement = ""
    }
}

@MainActor
final class SpeechRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isFinalizing = false
    @Published var errorMessage: String?
    @Published private(set) var recordingStartedAt: Date?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard !isRecording, !isStarting, !isFinalizing else { return }
        errorMessage = nil
        transcript = ""
        recordingStartedAt = nil
        isStarting = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.isStarting = false
                    self.errorMessage = "请在系统设置中允许语音识别。"
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.isStarting = false
                            self.errorMessage = "请在系统设置中允许麦克风访问。"
                            return
                        }
                        self.beginRecognition()
                    }
                }
            }
        }
    }

    private func beginRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            isStarting = false
            errorMessage = "语音识别暂时不可用，请稍后重试。"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            recordingStartedAt = Date()
            isRecording = true
            isStarting = false
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let result { self?.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true || error != nil {
                        if let error, self?.isRecording == true {
                            self?.errorMessage = error.localizedDescription
                        }
                        self?.isRecording = false
                        self?.isStarting = false
                        self?.isFinalizing = false
                        self?.request = nil
                        self?.task = nil
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    }
                }
            }
        } catch {
            isStarting = false
            errorMessage = "无法开始录音，请检查麦克风权限。"
            stop()
        }
    }

    func stop() {
        guard isRecording else {
            isStarting = false
            return
        }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
        if task != nil {
            isFinalizing = true
            task?.finish()
        } else {
            isFinalizing = false
            request = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

enum DeepSeekError: LocalizedError {
    case missingKey, invalidResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在设置中填写 DeepSeek API Key。"
        case .invalidResponse: return "AI 返回内容暂时无法读取，请重试。"
        case .server(let message): return message
        }
    }
}

struct DeepSeekService {
    private let diaryStyle = """
    你是一位细腻、克制的中文日记编辑，也帮助用户学习更丰富的表达。把口语和零散内容整理成朴实、自然、清楚、有余味的第一人称日记。用准确、具体、有变化的词句，避免空泛的“哇，好美”“特别好”；只在原文依据充分时，才把感受写得更细致、更有层次，不得添加原文没有的事实、景物、感官细节或情绪，也不要堆砌辞藻。
    """
    private let jsonInstruction = """
    根据整理后的全文提炼一个简短、有辨识度的中文标题。标题只选当天最有代表性、最能与其他日子区分开的一个事件、感受或关键词；即使日记里有多个并列事件，也不要把它们全部拼在标题里。不要用“普通的一天”“上班的一天”等泛泛标题，也不能编造内容。另提炼0到2个“特别记忆”标签，只标记日记明确提到的第一次、重要尝试、人生节点或独特经历；没有明确依据时返回空数组。不要生成节假日标签，节日由应用单独标记。标签要短、具体、彼此区别。请严格输出 JSON，格式为 {"title":"日记标题","content":"整理后的日记正文","tags":["特别记忆"]}，不要输出其他文字。
    """
    private let timeInstruction = """
    每次口述附带的开始时间是本段原文里“现在、此刻、正在”等说法的时间参照。整理时把这些当前状态自然地落到对应时段，例如“中午”“下午”“傍晚”，必要时写具体几点；只给确实指向当前时刻的事情补时间，不要把整段口述里的所有事件都写成发生在开始时间。用户明确说了其他时间的经历时，以原文为准。合并日记时保留旧稿和新口述里已有的时间线索，避免把不同时段的事情混在一起。
    """

    func polish(_ rawText: String, spokenAt: Date) async throws -> PolishedDiary {
        let userText = """
        本次口述开始时间：\(formattedTimestamp(spokenAt))

        本次口述原文：
        \(rawText)
        """
        return try await generate(systemPrompt: "\(diaryStyle)\n\(timeInstruction)\n\(jsonInstruction)", userText: userText)
    }

    func merge(existingDiary: String, newRawText: String, spokenAt: Date) async throws -> PolishedDiary {
        let systemPrompt = """
        \(diaryStyle)
        \(timeInstruction)
        用户会给你一篇已经保存的今日整理稿、本次口述的开始时间和新的口述原文。请把两部分合并成一篇完整的今日第一人称日记：保留旧稿和新口述中的重要事实、经历、感受和时间线索；去掉重复内容，让叙述自然连贯；不要把新内容简单粘在末尾，也不要重写到丢失旧内容。\(jsonInstruction)
        """
        let userText = """
        已保存的今日整理稿：
        \(existingDiary)

        本次口述开始时间：\(formattedTimestamp(spokenAt))

        本次新的口述原文：
        \(newRawText)
        """
        return try await generate(systemPrompt: systemPrompt, userText: userText)
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(Locale(identifier: "zh_CN")))
    }

    private func generate(systemPrompt: String, userText: String) async throws -> PolishedDiary {
        let key = UserDefaults.standard.string(forKey: "deepseek_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw DeepSeekError.missingKey }
        let model = UserDefaults.standard.string(forKey: "deepseek_model") ?? "deepseek-chat"
        let endpointText = UserDefaults.standard.string(forKey: "deepseek_endpoint") ?? "https://api.deepseek.com/chat/completions"
        guard let url = URL(string: endpointText) else { throw DeepSeekError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.7,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.server("整理失败（\(http.statusCode)），请检查 API 设置后重试。\(body.prefix(180))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let resultData = content.data(using: .utf8),
              let result = try? JSONDecoder().decode(PolishedDiary.self, from: resultData) else {
            throw DeepSeekError.invalidResponse
        }
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let diary = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !diary.isEmpty else { throw DeepSeekError.invalidResponse }
        var tags: [String] = []
        for rawTag in result.tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !tag.isEmpty, tag.count <= 12, !tags.contains(tag) else { continue }
            tags.append(tag)
            if tags.count == 2 { break }
        }
        return PolishedDiary(title: title, content: diary, tags: tags)
    }
}

private func diaryDayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private enum DiaryStyle {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let paper = Color(uiColor: .systemBackground)
    static let green = Color.primary
    static let line = Color(uiColor: .separator)
}

private struct SystemGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct ContentView: View {
    @StateObject private var store = EntryStore()
    @StateObject private var recorder = SpeechRecorder()
    @Namespace private var recordingButtonAnimation
    @State private var sessionStarted = false
    @State private var shouldPolish = false
    @State private var isPolishing = false
    @State private var mergedWithEarlier = false
    @State private var polishedTitle = ""
    @State private var polishedText = ""
    @State private var polishedTags: [String] = []
    @State private var showingDiaryList = false
    @State private var selectedDiary: DiaryEntry?
    @State private var showingCalendar = false
    @State private var pendingCalendarEntry: DiaryEntry?
    @State private var showingSettings = false
    @State private var errorMessage: String?
    @State private var saved = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                DiaryStyle.paper.ignoresSafeArea()
                if showingDiaryList {
                    savedDiaryBrowser
                        .transition(.move(edge: .leading))
                        .zIndex(2)
                } else {
                    VStack(spacing: 0) {
                        header
                        if sessionStarted { liveDiaryContent }
                        else { welcomeContent }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if sessionStarted && !showingDiaryList { bottomControl }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
            .sheet(isPresented: $showingCalendar, onDismiss: openPendingCalendarEntry) {
                DiaryCalendarPicker(entries: store.entries) { entry in
                    pendingCalendarEntry = entry
                    showingCalendar = false
                }
            }
            .onChange(of: recorder.isFinalizing) { _, finalizing in
                guard !finalizing, shouldPolish else { return }
                shouldPolish = false
                Task { await polishTranscript() }
            }
            .onChange(of: recorder.errorMessage) { _, message in
                if let message { errorMessage = message }
            }
            .onDisappear { recorder.stop() }
            .task { await store.syncWithNutstore() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.syncWithNutstore() } }
            }
        }
        .tint(DiaryStyle.green)
    }

    private var header: some View {
        HStack {
            Button {
                guard !recorder.isRecording, !recorder.isStarting, !isPolishing, !recorder.isFinalizing else { return }
                selectedDiary = nil
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = true }
            } label: {
                Text("过往")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isRecording || recorder.isStarting || isPolishing || recorder.isFinalizing)
            .accessibilityLabel("查看所有日记")
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 46, height: 46)
                    .modifier(SystemGlass())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var savedDiaryBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if selectedDiary != nil {
                        withAnimation(.easeInOut(duration: 0.22)) { selectedDiary = nil }
                    } else {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = false }
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .modifier(SystemGlass())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selectedDiary == nil ? "返回主页" : "返回日记列表")
                Spacer()
                Text(selectedDiary == nil ? "所有日记" : "日记详情")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Spacer()
                if selectedDiary == nil {
                    Button {
                        showingCalendar = true
                    } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .modifier(SystemGlass())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("按日历查找日记")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }

            if let entry = selectedDiary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(entry.createdAt.formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(entry.title)
                            .font(.system(.largeTitle, design: .serif, weight: .medium))
                            .foregroundStyle(.primary)
                        if !entry.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(Array(entry.tags.prefix(2).enumerated()), id: \.offset) { _, tag in
                                    memoryTag(tag)
                                }
                            }
                        }
                        Text(entry.content)
                            .font(.system(.body, design: .serif))
                            .lineSpacing(8)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(24)
                }
            } else if store.entries.isEmpty {
                ContentUnavailableView("还没有日记", systemImage: "book.closed", description: Text("保存后的日记会出现在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.entries) { entry in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) { selectedDiary = entry }
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(entry.createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN"))))
                                            .font(.system(.footnote, design: .rounded))
                                            .foregroundStyle(.secondary)
                                        if let holiday = ChinaHolidayCalendar.label(for: entry.createdAt) {
                                            Text(holiday)
                                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                                .foregroundStyle(Color.orange)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.orange.opacity(0.13), in: Capsule())
                                                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.18), lineWidth: 1))
                                        }
                                    }
                                    Text(entry.title)
                                        .font(.system(.body, design: .rounded, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    if !entry.tags.isEmpty {
                                        HStack(spacing: 6) {
                                            ForEach(Array(entry.tags.prefix(2).enumerated()), id: \.offset) { _, tag in
                                                memoryTag(tag)
                                            }
                                        }
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(DiaryStyle.paper.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -100 {
                if selectedDiary != nil { selectedDiary = nil }
                else { withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = false } }
            }
        })
    }

    private var welcomeContent: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("把今天说给我听")
                .font(.system(.largeTitle, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
            Text("不用想好怎么写，开始说就好。")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: beginDiary) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.045)).frame(width: 204, height: 204)
                    Circle().fill(.ultraThinMaterial)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
                        .frame(width: 164, height: 164)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .frame(width: 204, height: 204)
                .modifier(SystemGlass())
                .contentShape(Circle())
            }
            .matchedGeometryEffect(id: "recording-button", in: recordingButtonAnimation)
            .buttonStyle(.plain)
            .accessibilityLabel("开始口述")
            .padding(.top, 18)
            Text("轻点开始口述")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            Text("你的日记会先保存在这台设备上")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
    }

    private var liveDiaryContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(polishedText.isEmpty ? "今天的口述" : "原文与整理稿")
                .font(.system(.title2, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.top, 26)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !polishedText.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("本次口述原文", systemImage: "waveform")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(recorder.transcript)
                                .font(.system(.body, design: .rounded))
                                .lineSpacing(7)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))

                        VStack(alignment: .leading, spacing: 10) {
                            Label(mergedWithEarlier ? "合并后的今日日记" : "整理后的日记", systemImage: "text.alignleft")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("日记标题", text: $polishedTitle)
                                .font(.system(.title3, design: .serif, weight: .semibold))
                                .foregroundStyle(.primary)
                                .textFieldStyle(.plain)
                                .accessibilityLabel("编辑日记标题")
                            TextEditor(text: $polishedText)
                                .font(.system(.body, design: .serif))
                                .lineSpacing(8)
                                .foregroundStyle(.primary)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 200, maxHeight: 320)
                                .accessibilityLabel("编辑整理后的日记正文")
                            if !polishedTags.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(Array(polishedTags.enumerated()), id: \.offset) { _, tag in
                                        memoryTag(tag)
                                    }
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    } else {
                        Text(recorder.transcript.isEmpty
                             ? (recorder.isStarting ? "正在准备语音识别…" : "你的口述文字会显示在这里。\n想到什么就慢慢说。")
                             : recorder.transcript)
                            .font(.system(.body, design: .rounded))
                            .lineSpacing(7)
                            .foregroundStyle(recorder.transcript.isEmpty ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    }
                }
                .padding(.bottom, 8)
            }

            if isPolishing || recorder.isFinalizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(recorder.isFinalizing ? "正在完成语音转写…" : "DeepSeek 正在整理日记…")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bottomControl: some View {
        VStack(spacing: 10) {
            if !polishedText.isEmpty {
                Button(action: saveDiary) {
                    Label("保存整理后的日记", systemImage: "square.and.arrow.down")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(saved)
                .opacity(saved ? 0.55 : 1)
                Text("每天只保存一篇 Markdown；后续口述会合并进今天的日记")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Button(action: bottomButtonAction) {
                    HStack(spacing: 12) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 58, height: 58)
                            .modifier(SystemGlass())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                            .matchedGeometryEffect(id: "recording-button", in: recordingButtonAnimation)
                        Text(bottomButtonTitle)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPolishing || recorder.isFinalizing || recorder.isStarting)
                .accessibilityLabel(recorder.isRecording ? "结束口述" : "开始口述")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var bottomButtonTitle: String {
        if recorder.isRecording { return "轻点结束口述" }
        if recorder.isStarting { return "正在准备…" }
        if recorder.isFinalizing { return "正在完成转写…" }
        if isPolishing { return "DeepSeek 正在整理…" }
        if errorMessage != nil && !recorder.transcript.isEmpty { return "重试 AI 整理" }
        return "重新开始口述"
    }

    private func bottomButtonAction() {
        if !recorder.isRecording, !recorder.transcript.isEmpty, errorMessage != nil {
            Task { await polishTranscript() }
        } else {
            toggleRecording()
        }
    }

    private func openPendingCalendarEntry() {
        guard let entry = pendingCalendarEntry else { return }
        pendingCalendarEntry = nil
        withAnimation(.easeInOut(duration: 0.22)) { selectedDiary = entry }
    }

    private func memoryTag(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .foregroundStyle(Color.indigo)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.indigo.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.indigo.opacity(0.17), lineWidth: 1))
    }

    private func beginDiary() {
        errorMessage = nil
        mergedWithEarlier = false
        polishedTitle = ""
        polishedText = ""
        polishedTags = []
        saved = false
        withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { sessionStarted = true }
        recorder.start()
    }

    private func toggleRecording() {
        if recorder.isRecording {
            errorMessage = nil
            shouldPolish = true
            recorder.stop()
            if !recorder.isFinalizing {
                shouldPolish = false
                Task { await polishTranscript() }
            }
        } else {
            errorMessage = nil
            recorder.start()
        }
    }

    @MainActor
    private func polishTranscript() async {
        let rawText = recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            errorMessage = "没有识别到口述内容，请再试一次。"
            return
        }
        isPolishing = true
        errorMessage = nil
        let spokenAt = recorder.recordingStartedAt ?? Date()
        do {
            let existingToday = store.entries(on: Date())
            let service = DeepSeekService()
            let result: PolishedDiary
            if existingToday.isEmpty {
                result = try await service.polish(rawText, spokenAt: spokenAt)
                mergedWithEarlier = false
            } else {
                let previous = existingToday
                    .sorted { $0.createdAt < $1.createdAt }
                    .map(\.content)
                    .joined(separator: "\n\n")
                result = try await service.merge(existingDiary: previous, newRawText: rawText, spokenAt: spokenAt)
                mergedWithEarlier = true
            }
            polishedTitle = result.title
            polishedText = result.content
            polishedTags = result.tags
        } catch {
            errorMessage = error.localizedDescription
        }
        isPolishing = false
    }

    private func saveDiary() {
        guard !saved else { return }
        let entry = DiaryEntry(title: polishedTitle, content: polishedText, tags: polishedTags)
        store.upsertDaily(entry)
        Task { await store.syncWithNutstore() }
        saved = true
        recorder.stop()
        shouldPolish = false
        mergedWithEarlier = false
        polishedTitle = ""
        polishedText = ""
        polishedTags = []
        errorMessage = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { sessionStarted = false }
    }
}

private struct ChinaHolidayCalendar {
    private struct HolidayPeriod {
        let start: String
        let end: String
        let name: String
    }

    private static let festivalNames: [String: String] = [
        "2024-01-01": "元旦", "2024-02-10": "春节", "2024-04-04": "清明节",
        "2024-05-01": "劳动节", "2024-06-10": "端午节", "2024-09-17": "中秋节", "2024-10-01": "国庆节",
        "2025-01-01": "元旦", "2025-01-29": "春节", "2025-04-04": "清明节",
        "2025-05-01": "劳动节", "2025-05-31": "端午节", "2025-10-01": "国庆节", "2025-10-06": "中秋节",
        "2026-01-01": "元旦", "2026-02-17": "春节", "2026-04-05": "清明节",
        "2026-05-01": "劳动节", "2026-06-19": "端午节", "2026-09-25": "中秋节", "2026-10-01": "国庆节"
    ]

    private static let holidayPeriods = [
        HolidayPeriod(start: "2024-01-01", end: "2024-01-01", name: "元旦"),
        HolidayPeriod(start: "2024-02-10", end: "2024-02-17", name: "春节"),
        HolidayPeriod(start: "2024-04-04", end: "2024-04-06", name: "清明"),
        HolidayPeriod(start: "2024-05-01", end: "2024-05-05", name: "劳动"),
        HolidayPeriod(start: "2024-06-10", end: "2024-06-10", name: "端午"),
        HolidayPeriod(start: "2024-09-15", end: "2024-09-17", name: "中秋"),
        HolidayPeriod(start: "2024-10-01", end: "2024-10-07", name: "国庆"),
        HolidayPeriod(start: "2025-01-01", end: "2025-01-01", name: "元旦"),
        HolidayPeriod(start: "2025-01-28", end: "2025-02-04", name: "春节"),
        HolidayPeriod(start: "2025-04-04", end: "2025-04-06", name: "清明"),
        HolidayPeriod(start: "2025-05-01", end: "2025-05-05", name: "劳动"),
        HolidayPeriod(start: "2025-05-31", end: "2025-06-02", name: "端午"),
        HolidayPeriod(start: "2025-10-01", end: "2025-10-05", name: "国庆"),
        HolidayPeriod(start: "2025-10-07", end: "2025-10-08", name: "中秋"),
        HolidayPeriod(start: "2026-01-01", end: "2026-01-03", name: "元旦"),
        HolidayPeriod(start: "2026-02-15", end: "2026-02-23", name: "春节"),
        HolidayPeriod(start: "2026-04-04", end: "2026-04-06", name: "清明"),
        HolidayPeriod(start: "2026-05-01", end: "2026-05-05", name: "劳动"),
        HolidayPeriod(start: "2026-06-19", end: "2026-06-21", name: "端午"),
        HolidayPeriod(start: "2026-09-25", end: "2026-09-27", name: "中秋"),
        HolidayPeriod(start: "2026-10-01", end: "2026-10-07", name: "国庆")
    ]

    static func label(for date: Date) -> String? {
        let key = diaryDayKey(date)
        if let festival = festivalNames[key] { return festival }
        let monthDay = Calendar.current.dateComponents([.month, .day], from: date)
        if monthDay.month == 1 && monthDay.day == 1 { return "元旦" }
        if monthDay.month == 5 && monthDay.day == 1 { return "劳动节" }
        if monthDay.month == 10 && monthDay.day == 1 { return "国庆节" }

        let lunarCalendar = Calendar(identifier: .chinese)
        let lunarDate = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: date)
        if lunarDate.isLeapMonth != true {
            if lunarDate.month == 1 && lunarDate.day == 1 { return "春节" }
            if lunarDate.month == 5 && lunarDate.day == 5 { return "端午节" }
            if lunarDate.month == 8 && lunarDate.day == 15 { return "中秋节" }
        }

        guard let period = holidayPeriods.first(where: { $0.start <= key && key <= $0.end }) else { return nil }
        return "\(period.name)休"
    }
}

private struct DiaryCalendarPicker: View {
    let entries: [DiaryEntry]
    let onSelect: (DiaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayedMonth: Date
    @State private var selectedDate: Date

    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    init(entries: [DiaryEntry], onSelect: @escaping (DiaryEntry) -> Void) {
        self.entries = entries
        self.onSelect = onSelect
        let initialDate = entries.first?.createdAt ?? Date()
        let initialMonth = Calendar.current.dateInterval(of: .month, for: initialDate)?.start ?? initialDate
        _displayedMonth = State(initialValue: initialMonth)
        _selectedDate = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack {
                    monthButton(systemName: "chevron.left", offset: -1, label: "上个月")
                    Spacer()
                    Text(displayedMonth.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                    Spacer()
                    monthButton(systemName: "chevron.right", offset: 1, label: "下个月")
                }
                .padding(.horizontal, 2)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(weekdays.indices, id: \.self) { index in
                        Text(weekdays[index])
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    }
                    ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayButton(date)
                        } else {
                            Color.clear.frame(height: 48)
                        }
                    }
                }

                if let entry = entry(on: selectedDate) {
                    Label("\(selectedDate.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN")))) · \(entry.title)", systemImage: "book.closed")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("有小点的日期保存过日记", systemImage: "circle.fill")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .navigationTitle("日记日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var monthDays: [Date?] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        var dates = Array<Date?>(repeating: nil, count: calendar.component(.weekday, from: interval.start) - 1)
        for day in dayRange {
            dates.append(calendar.date(byAdding: .day, value: day - 1, to: interval.start))
        }
        return dates
    }

    private func monthButton(systemName: String, offset: Int, label: String) -> some View {
        Button {
            guard let date = Calendar.current.date(byAdding: .month, value: offset, to: displayedMonth),
                  let monthStart = Calendar.current.dateInterval(of: .month, for: date)?.start else { return }
            withAnimation(.easeInOut(duration: 0.18)) { displayedMonth = monthStart }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .modifier(SystemGlass())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ date: Date) -> some View {
        let hasEntry = entry(on: date) != nil
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        return Button {
            selectedDate = date
            if let entry = entry(on: date) { onSelect(entry) }
        } label: {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(.subheadline, design: .rounded, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
                    .frame(width: 36, height: 36)
                    .background {
                        if isSelected { Circle().fill(Color.primary) }
                    }
                Circle()
                    .fill(hasEntry ? Color.primary : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.year().month(.wide).day().locale(Locale(identifier: "zh_CN"))) + (hasEntry ? "，有日记" : "，无日记"))
    }

    private func entry(on date: Date) -> DiaryEntry? {
        entries.first { Calendar.current.isDate($0.createdAt, inSameDayAs: date) }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: EntryStore
    @AppStorage("deepseek_api_key") private var apiKey = ""
    @AppStorage("deepseek_endpoint") private var endpoint = "https://api.deepseek.com/chat/completions"
    @AppStorage("deepseek_model") private var model = "deepseek-chat"
    @AppStorage("nutstore_username") private var nutstoreUsername = ""
    @AppStorage("nutstore_endpoint") private var nutstoreEndpoint = "https://dav.jianguoyun.com/dav/"
    @State private var nutstorePassword = NutstoreCredentialStore.password ?? ""
    @State private var isShowingNutstorePassword = false
    @State private var credentialError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("DeepSeek API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("接口地址", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型名称", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("AI 整理")
                } footer: {
                    Text("填写后即可把口述内容整理成日记。API Key 只保存在这台设备上。")
                }
                Section {
                    TextField("坚果云账号（邮箱）", text: $nutstoreUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    HStack {
                        Group {
                            if isShowingNutstorePassword {
                                TextField("坚果云应用密码", text: $nutstorePassword)
                            } else {
                                SecureField("坚果云应用密码", text: $nutstorePassword)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: nutstorePassword) { _, password in
                            do {
                                try NutstoreCredentialStore.setPassword(password.trimmingCharacters(in: .whitespacesAndNewlines))
                                credentialError = nil
                            } catch {
                                credentialError = error.localizedDescription
                            }
                        }
                        Button {
                            isShowingNutstorePassword.toggle()
                        } label: {
                            Image(systemName: isShowingNutstorePassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isShowingNutstorePassword ? "隐藏坚果云应用密码" : "显示坚果云应用密码")
                    }
                    TextField("WebDAV 地址", text: $nutstoreEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await store.syncWithNutstore() }
                    } label: {
                        HStack {
                            if store.isSyncing { ProgressView().padding(.trailing, 4) }
                            Text(store.isSyncing ? "正在同步…" : "立即同步")
                            Spacer()
                            Text(store.syncMessage)
                                .font(.caption)
                                .foregroundStyle(store.syncMessage.hasPrefix("同步失败") ? Color.red : Color.secondary)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 180, alignment: .trailing)
                                .lineLimit(3)
                        }
                    }
                    .disabled(store.isSyncing)
                    if let credentialError {
                        Text(credentialError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("坚果云同步")
                } footer: {
                    Text("日记保存在坚果云根目录的“留白日记”文件夹中，应用会尝试自动创建。保存日记后会自动上传，打开应用时会同步云端内容。请填写坚果云网页端生成的应用密码，不要填写登录密码；密码仅保存在本机钥匙串。")
                }
                Section {
                    Label("语音识别由 Apple 系统提供", systemImage: "waveform")
                    Text("日记以 Markdown 格式保存在本机和已配置的坚果云。使用 AI 整理时，口述内容会发送至你填写的 DeepSeek 接口；保存时只保留整理后的日记。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .tint(DiaryStyle.green)
    }
}
