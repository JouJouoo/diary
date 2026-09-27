import Combine
import Foundation
import Security

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

    func add(_ entry: DiaryEntry) {
        entries.insert(entry, at: 0)
        entries.sort { $0.createdAt > $1.createdAt }
        save()
        saveMarkdown(entry)
    }

    func upsert(_ entry: DiaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.insert(entry, at: 0) }
        entries.sort { $0.createdAt > $1.createdAt }
        save()
        saveMarkdown(entry)
    }

    func deleteEntries(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let deletedEntries = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        save()

        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Markdown", isDirectory: true)
        for entry in deletedEntries {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.markdownFileName))
        }
    }

    @discardableResult
    func replaceSelectedEntries(_ ids: Set<UUID>, with entry: DiaryEntry) -> Bool {
        guard ids.count > 1 else { return false }
        let selected = entries.filter { ids.contains($0.id) }
        guard selected.count == ids.count,
              Set(selected.map { diaryDayKey($0.createdAt) }).count == 1,
              diaryDayKey(selected[0].createdAt) == diaryDayKey(entry.createdAt) else { return false }

        entries.removeAll { ids.contains($0.id) }
        entries.insert(entry, at: 0)
        entries.sort { $0.createdAt > $1.createdAt }
        save()
        saveMarkdown(entry)

        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Markdown", isDirectory: true)
        for replaced in selected {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(replaced.markdownFileName))
        }
        return true
    }

    func syncWithNutstore(direction: NutstoreSyncDirection = .both) async {
        guard !isSyncing else { return }
        let username = UserDefaults.standard.string(forKey: "nutstore_username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = NutstoreCredentialStore.password ?? ""
        guard !username.isEmpty, !password.isEmpty else {
            syncMessage = "请先填写坚果云账号和应用密码"
            return
        }
        isSyncing = true
        syncMessage = "正在\(direction.action)…"
        defer { isSyncing = false }
        do {
            let result = try await NutstoreWebDAV.sync(entries: entries, username: username, password: password, direction: direction)
            entries = result.entries
            entries.sort { $0.createdAt > $1.createdAt }
            save()
            entries.forEach(saveMarkdown)
            let skippedNote = result.skippedCount > 0 ? " · \(result.skippedCount) 篇两端不同，因无法确认较新版本而跳过" : ""
            let unreadableNote = result.unreadableCount > 0 ? " · \(result.unreadableCount) 个云端文件无法识别" : ""
            syncMessage = "\(direction.action)完成 · 下载 \(result.downloadedCount) 篇 · 上传 \(result.uploadedCount) 篇\(skippedNote)\(unreadableNote) · \(Date().formatted(.dateTime.hour().minute()))"
        } catch {
            syncMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DiaryEntry].self, from: data) else { return }
        entries = decoded.sorted { $0.createdAt > $1.createdAt }
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
    }
}

enum NutstoreCredentialStore {
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
        guard !password.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NutstoreError.keychain(status)
            }
            return
        }

        let attributes = [kSecValueData as String: Data(password.utf8)] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NutstoreError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw NutstoreError.keychain(addStatus) }
    }
}

private enum NutstoreError: LocalizedError {
    case invalidURL, unauthorized(String), folderCreationDenied, forbidden(String), server(String, Int), keychain(OSStatus), invalidFile
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "坚果云 WebDAV 地址无效。"
        case .unauthorized(let method): return "坚果云的\(method)请求收到 HTTP 401，账号验证未通过。请确认用户名是注册邮箱，密码是为本应用生成的应用密码。"
        case .folderCreationDenied: return "账号已连上坚果云，但应用无法自动创建“留白日记”文件夹。请在坚果云根目录手动新建同名文件夹，再点立即同步。"
        case .forbidden(let operation): return "账号已连上坚果云，但没有权限\(operation)。"
        case .server(let operation, let status): return "坚果云\(operation)失败（\(status)）。"
        case .keychain(let status):
            let reason: String
            switch status {
            case errSecInteractionNotAllowed: reason = "设备当前不允许访问钥匙串，请解锁设备后重试。"
            case errSecNotAvailable: reason = "系统钥匙串暂时不可用，请稍后重试。"
            case errSecMissingEntitlement: reason = "应用没有访问钥匙串的权限。"
            case errSecDuplicateItem: reason = "密码记录已存在，请重新打开设置后重试。"
            default: reason = "系统暂时无法写入钥匙串（错误码 \(status)）。"
            }
            return "坚果云密码保存失败：\(reason)"
        case .invalidFile: return "云端日记文件无法读取。"
        }
    }
}

private struct NutstoreRemoteFile {
    let name: String
    let modifiedAt: Date?
    let url: URL
}

enum NutstoreSyncDirection {
    case both, download, upload

    var action: String {
        switch self {
        case .both: return "双向同步"
        case .download: return "从云端下载"
        case .upload: return "上传到云端"
        }
    }
}

private struct NutstoreSyncResult {
    let entries: [DiaryEntry]
    let downloadedCount: Int
    let uploadedCount: Int
    let skippedCount: Int
    let unreadableCount: Int
}

private enum NutstoreWebDAV {
    private static let endpoint = "https://dav.jianguoyun.com/dav/"
    private static let folderName = "留白日记"
    private static let markdownFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Markdown", isDirectory: true)

    static func sync(entries: [DiaryEntry], username: String, password: String, direction: NutstoreSyncDirection) async throws -> NutstoreSyncResult {
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
        var localEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.markdownFileName, $0) })
        let listing = try await listFiles(folder, username: username, password: password)
        let remoteFiles = listing.files
        try FileManager.default.createDirectory(at: markdownFolder, withIntermediateDirectories: true)
        let markdownFiles = remoteFiles.filter { $0.name.lowercased().hasSuffix(".md") }
        var unreadableCount = 0
        var downloadedCount = 0
        var uploadedCount = 0
        var skippedCount = 0
        var remoteNames = Set<String>()
        var supersededRemoteFiles: [NutstoreRemoteFile] = []

        // Read the remote set first so merge markers are known before processing any
        // individual file. Otherwise a source file listed before its summary could
        // survive cleanup or be uploaded back by another device.
        var remoteMarkdownByName: [String: String] = [:]
        var remoteEntryByName: [String: DiaryEntry] = [:]
        var supersededEntryIDs = Set(localEntries.values.flatMap(\.mergedEntryIDs))
        for remote in markdownFiles {
            let dayKey = String(remote.name.prefix(10))
            guard dayKey.count == 10 else { continue }
            let markdown = try await download(remote.url, username: username, password: password)
            remoteMarkdownByName[remote.name] = markdown
            if let entry = parse(markdown, dayKey: dayKey, fileName: remote.name) {
                remoteEntryByName[remote.name] = entry
                supersededEntryIDs.formUnion(entry.mergedEntryIDs)
            }
        }

        for remote in markdownFiles {
            remoteNames.insert(remote.name)
            let dayKey = String(remote.name.prefix(10))
            guard dayKey.count == 10 else {
                unreadableCount += 1
                continue
            }
            let remoteID = UUID(uuidString: String(remote.name.dropFirst(11).dropLast(3)))
            let replacedBySummary = remoteID.map(supersededEntryIDs.contains) ??
                (remote.name == "\(dayKey).md"
                    && (localEntries.values.contains { diaryDayKey($0.createdAt) == dayKey && !$0.mergedEntryIDs.isEmpty }
                        || remoteEntryByName.values.contains { diaryDayKey($0.createdAt) == dayKey && !$0.mergedEntryIDs.isEmpty }))
            if replacedBySummary {
                if direction != .download { supersededRemoteFiles.append(remote) }
                continue
            }
            let localURL = markdownFolder.appendingPathComponent(remote.name)
            let localEntry = localEntries[remote.name]
            let localDate = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.modificationDate]) as? Date
            let remoteIsNewer = remote.modifiedAt.flatMap { remoteDate in localDate.map { remoteDate.timeIntervalSince($0) > 2 } } ?? false
            let localIsNewer = localDate.flatMap { date in remote.modifiedAt.map { date.timeIntervalSince($0) > 2 } } ?? false
            guard let remoteMarkdown = remoteMarkdownByName[remote.name] else {
                unreadableCount += 1
                continue
            }
            if let localEntry, remoteMarkdown == localEntry.markdown { continue }

            if direction != .upload && (localEntry == nil || remoteIsNewer) {
                if let entry = remoteEntryByName[remote.name] {
                    localEntries[remote.name] = entry
                    try remoteMarkdown.write(to: localURL, atomically: true, encoding: .utf8)
                    downloadedCount += 1
                } else {
                    unreadableCount += 1
                }
            } else if direction != .download, let localEntry, localIsNewer {
                try await upload(localEntry.markdown, to: remote.url, username: username, password: password)
                uploadedCount += 1
            } else {
                skippedCount += 1
            }
        }

        if direction != .download {
            for (fileName, entry) in localEntries where !remoteNames.contains(fileName) {
                guard !supersededEntryIDs.contains(entry.id) else { continue }
                try await upload(entry.markdown, to: folder.appendingPathComponent(entry.markdownFileName), username: username, password: password)
                uploadedCount += 1
            }
            // Publish summaries before removing their source entries, so a failed
            // upload cannot leave the cloud without any copy of that day's diary.
            for remote in supersededRemoteFiles {
                try await delete(remote.url, username: username, password: password)
            }
        }
        return NutstoreSyncResult(entries: Array(localEntries.values), downloadedCount: downloadedCount, uploadedCount: uploadedCount, skippedCount: skippedCount, unreadableCount: unreadableCount)
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

    private static func listFiles(_ folder: URL, username: String, password: String) async throws -> (files: [NutstoreRemoteFile], responseCount: Int) {
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
        return (parser.files, parser.responseCount)
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

    private static func delete(_ url: URL, username: String, password: String) async throws {
        let (_, response) = try await request(url, method: "DELETE", username: username, password: password)
        guard response.statusCode == 200 || response.statusCode == 204 || response.statusCode == 404 else {
            if response.statusCode == 403 { throw NutstoreError.forbidden("删除已汇总的旧日记") }
            throw NutstoreError.server("删除已汇总的旧日记", response.statusCode)
        }
    }

    private static func parse(_ markdown: String, dayKey: String, fileName: String) -> DiaryEntry? {
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
            } else if line.hasPrefix("## 整理后的日记") {
                contentStart = index + 1
                break
            } else if line.hasPrefix("_") && line.hasSuffix("_") {
                contentStart = index + 1
            }
        }
        while contentStart < lines.count && lines[contentStart].isEmpty { contentStart += 1 }
        let contentLines = lines.dropFirst(contentStart).prefix {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !line.hasPrefix("## 口述原文") && !line.hasPrefix("<!-- merged-entry-ids:")
        }
        let content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## 口述原文") })
            .map { index in
                lines.dropFirst(index + 1).prefix { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!-- merged-entry-ids:") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
        let mergedEntryIDs = lines.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!-- merged-entry-ids:") })
            .flatMap { line -> [UUID]? in
                guard let start = line.firstIndex(of: ":"), let end = line.range(of: "-->")?.lowerBound else { return nil }
                return line[line.index(after: start)..<end].split(separator: ",").compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
            } ?? []
        guard !content.isEmpty else { return nil }
        let id = UUID(uuidString: String(fileName.dropFirst(11).dropLast(3))) ?? UUID()
        return DiaryEntry(id: id, createdAt: date, title: title.isEmpty ? "今天的日记" : title, content: content, tags: Array(tags.prefix(2)), rawTranscript: transcript, mergedEntryIDs: mergedEntryIDs)
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
    private(set) var responseCount = 0
    private(set) var files: [NutstoreRemoteFile] = []

    init(folderURL: URL) { self.folderURL = folderURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        if currentElement == "response" { responseDepth += 1; responseCount += 1; href = ""; lastModified = ""; isCollection = false }
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
            guard !isCollection, let url = URL(string: href, relativeTo: folderURL)?.absoluteURL,
                  url.host?.lowercased() == folderURL.host?.lowercased() else { return }
            let fileParentPath = url.deletingLastPathComponent().path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let folderPath = folderURL.absoluteURL.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard fileParentPath == folderPath else { return }
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            files.append(NutstoreRemoteFile(name: url.lastPathComponent, modifiedAt: dateFormatter.date(from: lastModified.trimmingCharacters(in: .whitespacesAndNewlines)), url: url))
        }
        currentElement = ""
    }
}
