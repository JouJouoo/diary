import SwiftUI

struct SettingsView: View {
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
            Group {
#if os(macOS)
                macSettingsContent
#else
                phoneSettingsContent
#endif
            }
                .navigationTitle("设置")
                .modifier(InlineNavigationTitle())
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("设置").font(.appSystem(.headline))
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
        }
    }

    #if os(macOS)
    private var macSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                macSettingsSection("AI 整理") {
                    macSettingsField("DeepSeek API Key") {
                        SecureField("输入 API Key", text: $apiKey)
                            .modifier(NoAutocorrection())
                            .textFieldStyle(.roundedBorder)
                    }
                    macSettingsField("接口地址") {
                        TextField("API 地址", text: $endpoint)
                            .modifier(NoAutocorrection())
                            .textFieldStyle(.roundedBorder)
                    }
                    macSettingsField("模型名称") {
                        TextField("模型名称", text: $model)
                            .modifier(NoAutocorrection())
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("填写后即可把口述内容整理成日记。API Key 只保存在这台设备上。")
                        .font(.appSystem(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink {
                        AIPromptEditorView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "text.quote")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("编辑全部 AI 提示词")
                                    .font(.appSystem(.body, design: .rounded, weight: .medium))
                                Text("按素材、写作、标题和重写规则分组调整")
                                    .font(.appSystem(.footnote))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.appSystem(.caption))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                macSettingsSection("坚果云同步") {
                    macSettingsField("坚果云账号（邮箱）") {
                        TextField("name@example.com", text: $nutstoreUsername)
                            .modifier(NoAutocorrection())
                            .textFieldStyle(.roundedBorder)
                    }
                    macSettingsField("坚果云应用密码") {
                        HStack(spacing: 8) {
                            Group {
                                if isShowingNutstorePassword {
                                    TextField("输入坚果云应用密码", text: $nutstorePassword)
                                } else {
                                    SecureField("输入坚果云应用密码", text: $nutstorePassword)
                                }
                            }
                            .modifier(NoAutocorrection())
                            .textFieldStyle(.roundedBorder)
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
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isShowingNutstorePassword ? "隐藏坚果云应用密码" : "显示坚果云应用密码")
                        }
                    }
                    macSettingsField("WebDAV 地址") {
                        TextField("https://dav.jianguoyun.com/dav/", text: $nutstoreEndpoint)
                            .modifier(NoAutocorrection())
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(alignment: .center, spacing: 10) {
                        Button("双向同步") { Task { await store.syncWithNutstore() } }
                            .modifier(SystemProminentButton())
                        Button("从云端下载") { Task { await store.syncWithNutstore(direction: .download) } }
                            .modifier(SystemSecondaryButton())
                        Button("上传到云端") { Task { await store.syncWithNutstore(direction: .upload) } }
                            .modifier(SystemSecondaryButton())
                    }
                    .disabled(store.isSyncing)
                    Text(store.syncMessage)
                        .font(.appSystem(.footnote))
                        .foregroundStyle(store.syncMessage.hasPrefix("同步失败") ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("只传输本机没有或明确较新的日记；两端同一天内容不同、时间又无法判断时会跳过，避免覆盖。")
                        .font(.appSystem(.footnote))
                        .foregroundStyle(.secondary)
                    if let credentialError {
                        Text(credentialError).font(.appSystem(.footnote)).foregroundStyle(.red)
                    }
                    Text("Mac 版和 iPhone 版的同步配置分开保存。请在两端填写同一坚果云账号和应用密码。打开应用或保存日记后会自动双向同步；也可以手动选择下载或上传。日记存放在坚果云根目录的“留白日记”文件夹中。密码仅保存在本机钥匙串。")
                        .font(.appSystem(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                macSettingsSection("语音与隐私") {
                    Label("语音识别由 Apple 系统提供", systemImage: "waveform")
                    Text("日记以 Markdown 格式保存在本机和已配置的坚果云，每篇同时包含整理稿和口述原文。使用 AI 整理或汇总时，相关口述内容会发送至你填写的 DeepSeek 接口。")
                        .font(.appSystem(.footnote))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 600, idealWidth: 720, minHeight: 540)
        .background(DiaryStyle.paper)
    }

    private func macSettingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.appSystem(.headline, design: .rounded, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(DiaryStyle.secondaryPaper, in: RoundedRectangle(cornerRadius: 16))
    }

    private func macSettingsField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.appSystem(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    #if os(iOS)
    private var phoneSettingsContent: some View {
            Form {
                Section {
                    SecureField("DeepSeek API Key", text: $apiKey)
                    .modifier(NoAutocorrection())
                    TextField("接口地址", text: $endpoint)
                    .modifier(NoAutocorrection())
                    TextField("模型名称", text: $model)
                    .modifier(NoAutocorrection())
                    NavigationLink {
                        AIPromptEditorView()
                    } label: {
                        Label("编辑全部 AI 提示词", systemImage: "text.quote")
                    }
                } header: {
                    Text("AI 整理")
                } footer: {
                    Text("提示词已按用途分组，修改后会用于下一次 AI 整理。API Key 只保存在这台设备上。")
                }
                Section {
                    TextField("坚果云账号（邮箱）", text: $nutstoreUsername)
                        .modifier(NoAutocorrection())
                        .modifier(EmailKeyboard())
                    HStack {
                        Group {
                            if isShowingNutstorePassword {
                                TextField("坚果云应用密码", text: $nutstorePassword)
                            } else {
                                SecureField("坚果云应用密码", text: $nutstorePassword)
                            }
                        }
                        .modifier(NoAutocorrection())
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
                    .modifier(NoAutocorrection())
                    Button("双向同步") { Task { await store.syncWithNutstore() } }
                        .disabled(store.isSyncing)
                    Button("从云端下载") { Task { await store.syncWithNutstore(direction: .download) } }
                        .disabled(store.isSyncing)
                    Button("上传到云端") { Task { await store.syncWithNutstore(direction: .upload) } }
                        .disabled(store.isSyncing)
                    Text(store.syncMessage)
                        .font(.appSystem(.footnote))
                        .foregroundStyle(store.syncMessage.hasPrefix("同步失败") ? Color.red : Color.secondary)
                    Text("只传输本机没有或明确较新的日记；两端同一天内容不同、时间又无法判断时会跳过，避免覆盖。")
                        .font(.appSystem(.footnote))
                        .foregroundStyle(.secondary)
                    if let credentialError {
                        Text(credentialError).font(.appSystem(.footnote)).foregroundStyle(.red)
                    }
                } header: {
                    Text("坚果云同步")
                } footer: {
#if os(macOS)
                    Text("Mac 版和 iPhone 版的同步配置分开保存。请在两端填写同一坚果云账号和应用密码。打开应用或保存日记后会自动双向同步；也可以手动选择下载或上传。日记存放在坚果云根目录的“留白日记”文件夹中。请使用坚果云应用密码；密码仅保存在本机钥匙串。")
#else
                    Text("Mac 和 iPhone 需分别填写同一坚果云账号与应用密码。打开应用或保存日记后会自动双向同步；也可以手动选择下载或上传。日记存放在坚果云根目录的“留白日记”文件夹中，密码仅保存在本机钥匙串。")
#endif
                }
                Section {
                    Label("语音识别由 Apple 系统提供", systemImage: "waveform")
                    Text("日记以 Markdown 格式保存在本机和已配置的坚果云，每篇同时包含整理稿和口述原文。使用 AI 整理或汇总时，相关口述内容会发送至你填写的 DeepSeek 接口。")
                        .font(.appSystem(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
    }
    #endif
}

private struct AIPromptEditorView: View {
    @AppStorage(AIPromptSettings.timeUnderstandingKey)
    private var timeUnderstanding = AIPromptSettings.timeUnderstandingDefault
    @AppStorage(AIPromptSettings.diaryStyleKey)
    private var diaryStyle = AIPromptSettings.diaryStyleDefault
    @AppStorage(AIPromptSettings.creativeWritingKey)
    private var creativeWriting = AIPromptSettings.creativeWritingDefault
    @AppStorage(AIPromptSettings.titleAndOutputKey)
    private var titleAndOutput = AIPromptSettings.titleAndOutputDefault
    @AppStorage(AIPromptSettings.titleGenerationKey)
    private var titleGeneration = AIPromptSettings.titleGenerationDefault
    @AppStorage(AIPromptSettings.specialMemoryTagKey)
    private var specialMemoryTags = AIPromptSettings.specialMemoryTagDefault
    @AppStorage(AIPromptSettings.compositionTaskKey)
    private var compositionTask = AIPromptSettings.compositionTaskDefault
    @AppStorage(AIPromptSettings.summaryTaskKey)
    private var summaryTask = AIPromptSettings.summaryTaskDefault
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                promptEditor(
                    title: "日记标题制作",
                    explanation: "单独决定怎样从当天素材中选出一个值得记住的重点并制作标题。",
                    text: $titleGeneration,
                    minHeight: 130
                )
                promptEditor(
                    title: "特别记忆识别与标签制作",
                    explanation: "单独决定哪些经历值得作为特别记忆，以及如何生成简短标签。",
                    text: $specialMemoryTags,
                    minHeight: 150
                )
                promptEditor(
                    title: "时间理解",
                    explanation: "说明口述开始时间和素材中其他时间应该怎样理解。",
                    text: $timeUnderstanding,
                    minHeight: 90
                )
            } header: {
                Text("提示词 · 标题、标签与时间")
            }

            Section {
                promptEditor(
                    title: "日记整体风格",
                    explanation: "决定第一人称、真实感、画面感、语言气质和事实边界。",
                    text: $diaryStyle,
                    minHeight: 330
                )
                promptEditor(
                    title: "心理、心情与文学表达",
                    explanation: "决定内心描写、情绪变化、哲思、比喻和其他文学手法的力度。",
                    text: $creativeWriting,
                    minHeight: 180
                )
                promptEditor(
                    title: "成稿任务",
                    explanation: "告诉 AI 如何依据本次口述原文创作一篇独立日记。",
                    text: $compositionTask,
                    minHeight: 110
                )
                promptEditor(
                    title: "汇总同一天的日记文件",
                    explanation: "专用于把当天多份已保存的 Markdown 日记文件合并成一篇。",
                    text: $summaryTask,
                    minHeight: 200
                )
            } header: {
                Text("第二步 · 创作日记")
            }

            Section {
                promptEditor(
                    title: "标题、标签与返回格式",
                    explanation: "决定 AI 返回内容的格式。标题和特别记忆标签分别由上面的专用提示词控制；JSON 字段名称不要随意删除。",
                    text: $titleAndOutput,
                    minHeight: 170
                )
            } header: {
                Text("返回格式")
            }

            Section {
                Button("恢复全部默认提示词", role: .destructive) {
                    isConfirmingReset = true
                }
            } footer: {
                Text("修改会自动保存在当前设备，并从下一次 AI 整理开始生效。Mac 和 iPhone 的设置分别保存。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI 提示词")
        .modifier(InlineNavigationTitle())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("AI 提示词").font(.appSystem(.headline))
            }
        }
        .onAppear { AIPromptSettings.upgradeBuiltInPromptsIfNeeded() }
        .alert("恢复默认提示词？", isPresented: $isConfirmingReset) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                AIPromptSettings.restoreDefaults()
            }
        } message: {
            Text("你对全部提示词做过的修改都会被默认内容替换。")
        }
    }

    private func promptEditor(
        title: String,
        explanation: String,
        text: Binding<String>,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.appSystem(.headline, design: .rounded, weight: .semibold))
            Text(explanation)
                .font(.appSystem(.footnote))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: text)
                .font(.appSystem(.body, design: .rounded))
                .frame(minHeight: minHeight)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(DiaryStyle.paper, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                }
        }
        .padding(.vertical, 4)
    }
}
