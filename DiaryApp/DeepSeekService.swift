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
    static let timeUnderstandingKey = "ai_prompt_time_understanding"
    static let diaryStyleKey = "ai_prompt_diary_style"
    static let creativeWritingKey = "ai_prompt_creative_writing"
    static let titleAndOutputKey = "ai_prompt_title_and_output"
    static let titleGenerationKey = "ai_prompt_title_generation"
    static let specialMemoryTagKey = "ai_prompt_special_memory_tags"
    static let compositionTaskKey = "ai_prompt_composition_task"
    static let summaryTaskKey = "ai_prompt_daily_summary_task"
    private static let defaultsVersionKey = "ai_prompt_defaults_version"

    static let timeUnderstandingDefault = "口述开始时间只用来理解其中的‘现在’‘此刻’；其他时间以素材为准，不要把全天事件都写成发生在口述开始时。"

    static let titleGenerationDefault = "请从素材中选出最值得记住的一个核心重点，制作简短、具体、自然的日记标题。优先突出重要经历、第一次、人生节点、特别的人或关系、显著的情绪变化；不要把多件普通事情并列成标题，不要空泛概括、夸大素材，也不要重复日期。标题应忠实于素材，建议控制在24个汉字以内。"

    static let specialMemoryTagDefault = "请从素材中识别真正值得日后检索的特别记忆，并把它们制作成简短标签。优先选择明确发生的第一次、重要尝试、人生节点、特别经历或具有独特意义的人与事；日常琐事、普通情绪和没有事实依据的推断不要作为标签。最多给出两个标签，每个不超过12个汉字；没有明确特别记忆时返回空数组，不要为了凑数生成标签。"

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
    在素材支持的范围内写出人物的内心、犹豫、愿望和情绪变化，细致呈现心情如何随经历推进；不替人物判断，也不把推测写成事实。让思考和哲思从当天具体发生的事中自然生长，与动作、场景和感受相连，不空谈道理。可使用贴切、克制的比喻增强画面感，避免堆砌形容词和刻意煽情。
    """

    static let titleAndOutputDefault = "只输出 JSON：{\"title\":\"日记标题\",\"content\":\"完成后的日记正文\",\"tags\":[]}。title 使用标题制作提示词选出的重点；tags 使用特别记忆识别提示词确认的标签。JSON 外不要输出文字。"

    static let compositionTaskDefault = "以下是我的原始日记素材。请把这些素材当作创作依据，按上面的写作要求直接写成日记："

    static let summaryTaskDefault = """
    输入是同一天已经保存的多份完整日记 Markdown 文件。请把这些文件合并创作成一篇日记，综合每个文件里的整理稿和口述原文，保留各篇独有的重要事件、动作、人物关系、时间、场景、细节和真实感受。重复内容可以合并，但不可遗漏某一篇提供的新信息；按事件因果和情绪变化重新组织，不要逐文件拼接、罗列，也不要加入新的口述或其他日期的日记。最终只产出一篇自然连贯的第一人称日记。
    """

    static func text(for key: String, default defaultValue: String) -> String {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    static func restoreDefaults() {
        let defaults: [(String, String)] = [
            (timeUnderstandingKey, timeUnderstandingDefault),
            (diaryStyleKey, diaryStyleDefault),
            (creativeWritingKey, creativeWritingDefault),
            (titleAndOutputKey, titleAndOutputDefault),
            (titleGenerationKey, titleGenerationDefault),
            (specialMemoryTagKey, specialMemoryTagDefault),
            (compositionTaskKey, compositionTaskDefault),
            (summaryTaskKey, summaryTaskDefault)
        ]
        for (key, value) in defaults { UserDefaults.standard.set(value, forKey: key) }
    }

    static func upgradeBuiltInPromptsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: defaultsVersionKey) < 3 else { return }
        let oldStyle = "你是善于理解生活、描写内心的日记作者。把口述当创作素材，先判断事件的因果、逻辑和情绪推进，再按自然的叙事结构重构成第一人称日记，不逐句润色或照录音顺序改写。重排重复、跳跃内容，写清重要动作、场景和细节；保留素材明确的事实、实际时间、人物关系和真实感受，可补足衔接但不编造新事件、对话、环境或经历。保持本人语气，不写成总结、鸡汤、新闻或小说。"
        let oldCreative = "让心理和情绪推动叙事：依据处境、行为、念头和选择写出心理变化；对回避、期待、迟疑、释然等保持含蓄，不能把推测写成事实。不要拘泥于口述的先后或录音时间，按事件因果和情绪变化重新编排。让一两处思考从当天经历自然生长，适度使用比喻、对照和细节照应。可以大胆改写结构和措辞，但不增加素材没有的事件或对话。"
        if defaults.string(forKey: diaryStyleKey) == oldStyle { defaults.set(diaryStyleDefault, forKey: diaryStyleKey) }
        let savedCreative = defaults.string(forKey: creativeWritingKey)
        if savedCreative == oldCreative || savedCreative?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            defaults.set(creativeWritingDefault, forKey: creativeWritingKey)
        }
        defaults.removeObject(forKey: "ai_prompt_material_extraction")
        defaults.removeObject(forKey: "ai_prompt_rewrite_copied_text")
        defaults.set(3, forKey: defaultsVersionKey)
    }
}

struct DeepSeekService {
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
    private var writingSystemPrompt: String {
        [diaryStyle, creativeInstruction, titleInstruction, specialMemoryTagInstruction, jsonInstruction]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    func polish(_ rawText: String, spokenAt: Date, improvementPrompt: String = "") async throws -> PolishedDiary {
        AIPromptSettings.upgradeBuiltInPromptsIfNeeded()
        let compositionTask = AIPromptSettings.text(for: AIPromptSettings.compositionTaskKey, default: AIPromptSettings.compositionTaskDefault)
        let userText = """
        \(timeInstruction)
        本次口述开始时间：\(formattedTimestamp(spokenAt))

        \(compositionTask)\(improvementInstructions(improvementPrompt))

        以下是我的原始日记素材：
        \(rawText)
        """
        return try await generate(systemPrompt: writingSystemPrompt, userText: userText)
    }

    func summarize(files: [String], improvementPrompt: String = "") async throws -> PolishedDiary {
        AIPromptSettings.upgradeBuiltInPromptsIfNeeded()
        let summaryTask = AIPromptSettings.text(for: AIPromptSettings.summaryTaskKey, default: AIPromptSettings.summaryTaskDefault)
        let numberedFiles = files.enumerated().map { index, file in
            "日记文件 \(index + 1)：\n```markdown\n\(file)\n```"
        }.joined(separator: "\n\n")
        let userText = """
        \(summaryTask)\(improvementInstructions(improvementPrompt))

        以下是同一天的多份日记文件，请只合并这些文件：
        \(numberedFiles)
        """
        return try await generate(systemPrompt: writingSystemPrompt, userText: userText)
    }

    func supplementDraft(draft: String, newRawText: String, spokenAt: Date, improvementPrompt: String = "") async throws -> PolishedDiary {
        AIPromptSettings.upgradeBuiltInPromptsIfNeeded()
        let userText = """
        \(timeInstruction)
        本次补充口述开始时间：\(formattedTimestamp(spokenAt))

        请把补充口述融入当前尚未保存的同一篇日记草稿，保留原稿中的事实，并依据新增内容调整叙事和标题。不要读取或合并其他已保存的日记文件。\(improvementInstructions(improvementPrompt))

        当前日记草稿：
        \(draft)

        本次补充口述：
        \(newRawText)
        """
        return try await generate(systemPrompt: writingSystemPrompt, userText: userText)
    }

    private func improvementInstructions(_ prompt: String) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return "" }
        return "\n\n本次重新润色的改进建议，请优先遵循：\n\(trimmedPrompt)"
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day().hour().minute().locale(Locale(identifier: "zh_CN")))
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
