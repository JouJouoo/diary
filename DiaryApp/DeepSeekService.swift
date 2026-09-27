import Foundation

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

enum AIPromptSettings {
    static let materialExtractionKey = "ai_prompt_material_extraction"
    static let timeUnderstandingKey = "ai_prompt_time_understanding"
    static let diaryStyleKey = "ai_prompt_diary_style"
    static let creativeWritingKey = "ai_prompt_creative_writing"
    static let titleAndOutputKey = "ai_prompt_title_and_output"
    static let titleGenerationKey = "ai_prompt_title_generation"
    static let specialMemoryTagKey = "ai_prompt_special_memory_tags"
    static let compositionTaskKey = "ai_prompt_composition_task"
    static let summaryTaskKey = "ai_prompt_daily_summary_task"
    static let rewriteCopiedTextKey = "ai_prompt_rewrite_copied_text"
    private static let defaultsVersionKey = "ai_prompt_defaults_version"

    static let materialExtractionDefault = """
    从今天此前保存的日记和本次累计口述中提取创作素材，覆盖当天全部事件、动作、人物、时间、场景、细节、真实感受及心理线索（犹豫、愿望、回避、情绪变化）。口述顺序、分段时间只是线索；结合全部材料判断因果和逻辑，不把录音先后当成叙事顺序。合并重复，不漏旧内容，不复制旧段落，不编造事件、对话或事实；另列1—3条由具体经历引出的思考。
    每次补充后都重新整理当天全部素材。标题只选一个最重要的重点，优先第一次、重要尝试、人生节点、特别经历或独特心境；后续出现更重要内容时改选。对素材明确支持的特别记忆生成1—2个短标签，否则返回空数组。各项写成简短笔记，不写成日记。
    只输出 JSON：{"events":["事件与细节"],"innerLife":["心理与情绪线索"],"reflectionSeeds":["具体经历引出的思考"],"suggestedTitle":"唯一标题重点","milestoneTags":["特别记忆"]}。
    """

    static let timeUnderstandingDefault = """
    口述开始时间只用来理解其中的“现在”“此刻”；其他时间以素材为准，不要把全天事件都写成发生在口述开始时。
    """

    static let titleGenerationDefault = """
    请从当天全部素材中选出最值得记住的一个核心重点，制作简短、具体、自然的日记标题。优先突出重要经历、第一次、人生节点、特别的人或关系、显著的情绪变化；不要把多件普通事情并列成标题，不要空泛概括、夸大素材，也不要重复日期。标题应忠实于素材，建议控制在24个汉字以内。
    """

    static let specialMemoryTagDefault = """
    请从当天全部素材中识别真正值得日后检索的特别记忆，并把它们制作成简短标签。优先选择明确发生的第一次、重要尝试、人生节点、特别经历或具有独特意义的人与事；日常琐事、普通情绪和没有事实依据的推断不要作为标签。最多给出两个标签，每个不超过12个汉字；没有明确特别记忆时返回空数组，不要为了凑数生成标签。
    """

    static let diaryStyleDefault = """
    你是一位善于理解生活、描写人物内心的日记作者。请把我提供的凌乱口述整理创作成一篇自然、真诚、有画面感的第一人称日记。

    请把原始内容当作创作素材，而不是只做语句润色或简单归纳。先理解其中发生了什么、人物做了什么、身处什么场景、心里有什么感受，再重新组织表达，让日记读起来连贯、具体、有温度。

    写作时请注意：
    - 写清重要的动作、场景和事物，让读者能看见这一天是怎样展开的。
    - 在素材支持的范围内，描写人物当时的心理、犹豫、愿望和情绪变化；不要替人物作出没有依据的判断。
    - 可以从具体经历中自然带出一点思考或哲思，让感悟和当天发生的事相连，不要生硬讲道理。
    - 可以使用贴切、克制的比喻，让表达更生动；不要堆砌形容词或刻意煽情。
    - 忠实保留素材中的事实、时间、人物关系和真实感受。可以补足表达与衔接，但不要编造新的事件、对话、环境细节或经历。
    - 保留像本人在讲述生活的语气，不要写成新闻、总结、鸡汤或小说。
    - 对重复、跳跃的内容进行取舍和重组，让叙述自然清楚；重要的细节和感受不要遗漏。
    - 不要解释你的写作过程，也不要列出修改建议；直接输出完成后的日记。
    """

    static let creativeWritingDefault = """

    """

    static let titleAndOutputDefault = """
    只输出 JSON：{"title":"日记标题","content":"完成后的日记正文","tags":[]}。title 使用标题制作提示词选出的重点；tags 使用特别记忆识别提示词确认的标签。JSON 外不要输出文字。
    """

    static let compositionTaskDefault = """
    以下是我的原始日记素材。请把这些素材当作创作依据，按上面的写作要求直接写成日记：
    """

    static let summaryTaskDefault = """
    你正在把同一天的多篇独立日记汇总成一篇完整日记。下面的素材按原记录顺序编号，可能包含重复、补充、跳跃或相互关联的内容。请先综合理解所有记录，再按事件的时间、因果和情绪变化重新组织成一篇自然连贯的第一人称日记。
    必须覆盖每篇记录中独有的重要事件、动作、人物关系、时间、场景、细节和真实感受；相同内容可以合并，但不能因为某篇较短、较早或与其他篇重复就遗漏它提供的新信息。不要按记录逐篇拼接或罗列，也不要提到“汇总”“第几篇”或创作过程。忠实于全部素材，不编造事实。
    """

    static let rewriteCopiedTextDefault = """
    上一稿照搬了旧日记长段落，请保留事实，彻底更换叙事结构和措辞重新创作。
    """

    static func text(for key: String, default defaultValue: String) -> String {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    static func restoreDefaults() {
        let defaults: [(String, String)] = [
            (materialExtractionKey, materialExtractionDefault),
            (timeUnderstandingKey, timeUnderstandingDefault),
            (diaryStyleKey, diaryStyleDefault),
            (creativeWritingKey, creativeWritingDefault),
            (titleAndOutputKey, titleAndOutputDefault),
            (titleGenerationKey, titleGenerationDefault),
            (specialMemoryTagKey, specialMemoryTagDefault),
            (compositionTaskKey, compositionTaskDefault),
            (summaryTaskKey, summaryTaskDefault),
            (rewriteCopiedTextKey, rewriteCopiedTextDefault)
        ]
        for (key, value) in defaults {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    static func upgradeBuiltInPromptsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: defaultsVersionKey) < 2 else { return }
        let oldStyle = "你是善于理解生活、描写内心的日记作者。把口述当创作素材，先判断事件的因果、逻辑和情绪推进，再按自然的叙事结构重构成第一人称日记，不逐句润色或照录音顺序改写。重排重复、跳跃内容，写清重要动作、场景和细节；保留素材明确的事实、实际时间、人物关系和真实感受，可补足衔接但不编造新事件、对话、环境或经历。保持本人语气，不写成总结、鸡汤、新闻或小说。"
        let oldCreative = "让心理和情绪推动叙事：依据处境、行为、念头和选择写出心理变化；对回避、期待、迟疑、释然等保持含蓄，不能把推测写成事实。不要拘泥于口述的先后或录音时间，按事件因果和情绪变化重新编排。让一两处思考从当天经历自然生长，适度使用比喻、对照和细节照应。可以大胆改写结构和措辞，但不增加素材没有的事件或对话。"
        if defaults.string(forKey: diaryStyleKey) == oldStyle { defaults.set(diaryStyleDefault, forKey: diaryStyleKey) }
        if defaults.string(forKey: creativeWritingKey) == oldCreative { defaults.set(creativeWritingDefault, forKey: creativeWritingKey) }
        defaults.set(2, forKey: defaultsVersionKey)
    }
}

struct DeepSeekService {
    private struct DiaryMaterials: Decodable {
        let events: [String]
        let innerLife: [String]
        let reflectionSeeds: [String]
        let suggestedTitle: String
        let milestoneTags: [String]

        private enum CodingKeys: String, CodingKey { case events, innerLife, reflectionSeeds, suggestedTitle, milestoneTags }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            events = try values.decodeIfPresent([String].self, forKey: .events) ?? []
            innerLife = try values.decodeIfPresent([String].self, forKey: .innerLife) ?? []
            reflectionSeeds = try values.decodeIfPresent([String].self, forKey: .reflectionSeeds) ?? []
            suggestedTitle = try values.decodeIfPresent(String.self, forKey: .suggestedTitle) ?? ""
            milestoneTags = try values.decodeIfPresent([String].self, forKey: .milestoneTags) ?? []
        }

        var isEmpty: Bool { events.isEmpty && innerLife.isEmpty && reflectionSeeds.isEmpty }

        var writingNotes: String {
            func lines(_ items: [String]) -> String { items.map { "- \($0)" }.joined(separator: "\n") }
            return """
            今天发生的事和具体细节：
            \(lines(events))

            内心线索与心情变化：
            \(lines(innerLife))

            可以从具体经历生发的思考：
            \(lines(reflectionSeeds))

            今天唯一的标题重点：
            \(suggestedTitle)

            有明确依据的特别记忆标签：
            \(lines(milestoneTags))
            """
        }
    }

    private var diaryStyle: String {
        AIPromptSettings.text(for: AIPromptSettings.diaryStyleKey, default: AIPromptSettings.diaryStyleDefault)
    }
    private var creativeInstruction: String {
        AIPromptSettings.text(for: AIPromptSettings.creativeWritingKey, default: AIPromptSettings.creativeWritingDefault)
    }
    private var jsonInstruction: String {
        AIPromptSettings.text(for: AIPromptSettings.titleAndOutputKey, default: AIPromptSettings.titleAndOutputDefault)
    }
    private var timeInstruction: String {
        AIPromptSettings.text(for: AIPromptSettings.timeUnderstandingKey, default: AIPromptSettings.timeUnderstandingDefault)
    }
    private var titleInstruction: String {
        AIPromptSettings.text(for: AIPromptSettings.titleGenerationKey, default: AIPromptSettings.titleGenerationDefault)
    }
    private var specialMemoryTagInstruction: String {
        AIPromptSettings.text(for: AIPromptSettings.specialMemoryTagKey, default: AIPromptSettings.specialMemoryTagDefault)
    }

    func polish(_ rawText: String, spokenAt: Date) async throws -> PolishedDiary {
        let materials = try await extractMaterials(existingDiary: nil, rawText: rawText, spokenAt: spokenAt)
        return try await composeDiary(from: materials)
    }

    func summarize(records: [String], spokenAt: Date) async throws -> PolishedDiary {
        let numberedRecords = records.enumerated().map { index, record in
            "第\(index + 1)篇原始记录：\n\(record)"
        }.joined(separator: "\n\n")
        let materials = try await extractMaterials(existingDiary: nil, rawText: numberedRecords, spokenAt: spokenAt)
        let firstDraft = try await composeDiary(from: materials, task: AIPromptSettings.text(
            for: AIPromptSettings.summaryTaskKey,
            default: AIPromptSettings.summaryTaskDefault
        ))
        guard records.contains(where: { copiesOldParagraph(from: $0, in: firstDraft.content) }) else { return firstDraft }
        return (try? await composeDiary(from: materials, task: AIPromptSettings.text(
            for: AIPromptSettings.summaryTaskKey,
            default: AIPromptSettings.summaryTaskDefault
        ), retryingCopiedParagraph: true)) ?? firstDraft
    }

    func merge(existingDiary: String, newRawText: String, spokenAt: Date) async throws -> PolishedDiary {
        let materials = try await extractMaterials(existingDiary: existingDiary, rawText: newRawText, spokenAt: spokenAt)
        let firstDraft = try await composeDiary(from: materials)
        guard copiesOldParagraph(from: existingDiary, in: firstDraft.content) else { return firstDraft }
        return (try? await composeDiary(from: materials, retryingCopiedParagraph: true)) ?? firstDraft
    }

    private func extractMaterials(existingDiary: String?, rawText: String, spokenAt: Date) async throws -> DiaryMaterials {
        AIPromptSettings.upgradeBuiltInPromptsIfNeeded()
        let systemPrompt = AIPromptSettings.text(
            for: AIPromptSettings.materialExtractionKey,
            default: AIPromptSettings.materialExtractionDefault
        ) + "\n\n【标题制作提示词】\n\(titleInstruction)\n\n【特别记忆识别与标签制作提示词】\n\(specialMemoryTagInstruction)"
        let userText = """
        \(timeInstruction)

        今天此前保存的日记内容（也需要全部提取）：
        \(existingDiary ?? "无")

        本次口述开始时间：\(formattedTimestamp(spokenAt))

        今天这次记录累计的口述原文（可能包含多段）：
        \(rawText)
        """
        let materials: DiaryMaterials = try await requestJSON(systemPrompt: systemPrompt, userText: userText, temperature: 0.2)
        guard !materials.isEmpty else { throw DeepSeekError.invalidResponse }
        return materials
    }

    private func composeDiary(from materials: DiaryMaterials, task: String? = nil, retryingCopiedParagraph: Bool = false) async throws -> PolishedDiary {
        let retryInstruction = retryingCopiedParagraph
            ? "\n" + AIPromptSettings.text(
                for: AIPromptSettings.rewriteCopiedTextKey,
                default: AIPromptSettings.rewriteCopiedTextDefault
            )
            : ""
        let compositionTask = task ?? AIPromptSettings.text(for: AIPromptSettings.compositionTaskKey, default: AIPromptSettings.compositionTaskDefault)
        let userText = """
        \(compositionTask)\(retryInstruction)

        \(materials.writingNotes)
        """
        let draft = try await generate(systemPrompt: "\(diaryStyle)\n\(creativeInstruction)\n\(jsonInstruction)", userText: userText)
        let suggestedTitle = materials.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !suggestedTitle.isEmpty && suggestedTitle.count <= 24 ? suggestedTitle : draft.title
        var tags: [String] = []
        for rawTag in materials.milestoneTags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !tag.isEmpty, tag.count <= 12, !tags.contains(tag) else { continue }
            tags.append(tag)
            if tags.count == 2 { break }
        }
        return PolishedDiary(title: title, content: draft.content, tags: tags)
    }

    private func copiesOldParagraph(from oldDiary: String, in newDiary: String) -> Bool {
        oldDiary.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 40 }
            .contains { newDiary.contains($0) }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(Locale(identifier: "zh_CN")))
    }

    private func generate(systemPrompt: String, userText: String) async throws -> PolishedDiary {
        let result: PolishedDiary = try await requestJSON(systemPrompt: systemPrompt, userText: userText, temperature: 0.9)
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

    private func requestJSON<T: Decodable>(systemPrompt: String, userText: String, temperature: Double) async throws -> T {
        let key = UserDefaults.standard.string(forKey: "deepseek_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw DeepSeekError.missingKey }
        let model = UserDefaults.standard.string(forKey: "deepseek_model") ?? "deepseek-chat"
        let endpointText = UserDefaults.standard.string(forKey: "deepseek_endpoint") ?? "https://api.deepseek.com/chat/completions"
        guard let url = URL(string: endpointText) else { throw DeepSeekError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": temperature,
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
              let result = try? JSONDecoder().decode(T.self, from: resultData) else {
            throw DeepSeekError.invalidResponse
        }
        return result
    }
}
