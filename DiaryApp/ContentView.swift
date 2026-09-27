import SwiftUI

struct ContentView: View {
    private enum DiaryEditorTarget: String, Identifiable {
        case currentDraft, savedEntry
        var id: String { rawValue }
    }

    @StateObject private var store = EntryStore()
    @StateObject private var recorder = SpeechRecorder()
    @Namespace private var recordingButtonAnimation
    @State private var sessionStarted = false
    @State private var shouldPolish = false
    @State private var isPolishing = false
    @State private var mergedWithEarlier = false
    @State private var isSupplementingDraft = false
    @State private var transcriptBeforeSupplement = ""
    @State private var polishedTitle = ""
    @State private var polishedText = ""
    @State private var polishedTags: [String] = []
    @State private var diaryEditorTarget: DiaryEditorTarget?
    @State private var showingDiaryList = false
    @State private var selectedDiary: DiaryEntry?
    @State private var showingCalendar = false
    @State private var pendingCalendarEntry: DiaryEntry?
    @State private var showingSettings = false
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var sessionCreatedAt = Date()
    @State private var summarizingDayKey: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                DiaryStyle.paper.ignoresSafeArea()
                if showingDiaryList {
                    savedDiaryBrowser
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .leading))
                        .zIndex(2)
                } else {
                    VStack(spacing: 0) {
                        header
                        Group {
#if os(macOS)
                            if recorder.isRecording || recorder.isStarting { macRecordingContent }
                            else if sessionStarted { liveDiaryContent }
                            else { welcomeContent }
#else
                            if sessionStarted { liveDiaryContent }
                            else { welcomeContent }
#endif
                        }
#if os(macOS)
                        .frame(maxWidth: sessionStarted ? .infinity : 860)
#else
                        .frame(maxWidth: 860)
#endif
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .modifier(HiddenNavigationBar())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if sessionStarted && !showingDiaryList { bottomControl }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
#if os(macOS)
            .sheet(item: $diaryEditorTarget) { diaryEditor(for: $0) }
#else
            .fullScreenCover(item: $diaryEditorTarget) { target in
                diaryEditor(for: target)
            }
#endif
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
            .modifier(DismissKeyboardOnOutsideTap())
        }
    }

    private var selectedDiaryTitle: Binding<String> {
        Binding(get: { selectedDiary?.title ?? "" }, set: { updateSelectedDiary(title: $0) })
    }

    @ViewBuilder
    private func diaryEditor(for target: DiaryEditorTarget) -> some View {
        switch target {
        case .currentDraft:
            FullscreenDiaryEditor(title: $polishedTitle, content: $polishedText, tags: $polishedTags)
        case .savedEntry:
            if selectedDiary != nil {
                FullscreenDiaryEditor(
                    title: selectedDiaryTitle,
                    content: selectedDiaryContent,
                    tags: selectedDiaryTags,
                    onSave: saveSelectedDiary
                )
            }
        }
    }

    private var groupedEntries: [(key: String, date: Date, entries: [DiaryEntry])] {
        Dictionary(grouping: store.entries, by: { diaryDayKey($0.createdAt) })
            .values
            .compactMap { values in
                guard let date = values.map(\.createdAt).min() else { return nil }
                return (diaryDayKey(date), date, values.sorted { $0.createdAt > $1.createdAt })
            }
            .sorted { $0.date > $1.date }
    }

    private var selectedDiaryContent: Binding<String> {
        Binding(get: { selectedDiary?.content ?? "" }, set: { updateSelectedDiary(content: $0) })
    }

    private var selectedDiaryTags: Binding<[String]> {
        Binding(get: { selectedDiary?.tags ?? [] }, set: { updateSelectedDiary(tags: $0) })
    }

    private var header: some View {
        HStack {
            Button {
                guard !recorder.isRecording, !recorder.isStarting, !isPolishing, !recorder.isFinalizing else { return }
                selectedDiary = nil
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = true }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .modifier(SystemGlass())
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
        .frame(maxWidth: .infinity)
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
                    .font(.system(.title3, design: .rounded, weight: .semibold))
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
                    Button {
                        diaryEditorTarget = .savedEntry
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .modifier(SystemGlass())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑这篇日记")
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
                            .font(DiaryStyle.diaryDateFont)
                            .foregroundStyle(.secondary)
                        Text(entry.title)
                            .font(DiaryStyle.diaryTitleFont)
                            .foregroundStyle(.primary)
                        if !entry.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(Array(entry.tags.prefix(2).enumerated()), id: \.offset) { _, tag in
                                    memoryTag(tag)
                                }
                            }
                        }
                        Text(entry.content)
                            .font(DiaryStyle.diaryContentFont)
                            .lineSpacing(DiaryStyle.diaryContentLineSpacing)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !entry.rawTranscript.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("口述原文", systemImage: "waveform")
                                    .font(.system(.headline, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Text(entry.rawTranscript)
                                    .font(.system(.body, design: .rounded))
                                    .lineSpacing(6)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.top, 12)
                        }
                    }
                    .padding(32)
                }
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.tertiary)
                    Text("还没有日记")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text(store.syncMessage)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(store.syncMessage.hasPrefix("同步失败") ? Color.red : Color.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("从云端下载") { Task { await store.syncWithNutstore(direction: .download) } }
                            .modifier(SystemProminentButton())
                            .disabled(store.isSyncing)
                        Button("同步设置") { showingSettings = true }
                            .modifier(SystemSecondaryButton())
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedEntries, id: \.key) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.22)) { selectedDiary = entry }
                                } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(entry.createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN"))))
                                            .font(DiaryStyle.historyDateFont)
                                            .foregroundStyle(.secondary)
                                        if let holiday = ChinaHolidayCalendar.label(for: entry.createdAt) {
                                            Text(holiday)
                                                .font(DiaryStyle.historyTagFont)
                                                .foregroundStyle(Color.orange)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.orange.opacity(0.13), in: Capsule())
                                                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.18), lineWidth: 1))
                                        }
                                    }
                                    Text(entry.title)
                                        .font(DiaryStyle.historyTitleFont)
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(DiaryStyle.secondaryPaper.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                        } header: {
                            HStack {
                                Text(group.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN"))))
                                Spacer()
                                if group.entries.count > 1 {
                                    Button {
                                        Task { await summarizeDay(group.entries) }
                                    } label: {
                                        if summarizingDayKey == group.key {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Label("汇总 \(group.entries.count) 篇", systemImage: "arrow.triangle.merge")
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(summarizingDayKey != nil)
                                }
                            }
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiaryStyle.paper.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(SwipeBackGesture {
            if selectedDiary != nil { selectedDiary = nil }
            else { withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = false } }
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
            .keyboardShortcut("r", modifiers: [.command, .shift])
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

#if os(macOS)
    private var macRecordingContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 24) {
                Text("今天的口述")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)

                if recorder.transcript.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(.tertiary)
                        Text(recorder.isStarting ? "正在准备语音识别…" : "正在聆听")
                            .font(.system(.title3, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("想到哪里，就从哪里说起。")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                } else {
                    ScrollView {
                        Text(recorder.transcript)
                            .font(.system(size: 21, design: .rounded))
                            .lineSpacing(9)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(28)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 440)
                    .background(DiaryStyle.secondaryPaper, in: RoundedRectangle(cornerRadius: 22))
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 32)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
#endif

    private var liveDiaryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(polishedText.isEmpty ? "今天的口述" : "原文与整理稿")
#if os(macOS)
                .font(.system(size: polishedText.isEmpty ? 32 : 26, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: polishedText.isEmpty ? .center : .leading)
#else
                .font(.system(.title2, design: .rounded, weight: .medium))
#endif
                .foregroundStyle(.primary)
                .padding(.top, 12)

#if os(macOS)
            if !polishedText.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    originalTranscriptPanel
                        .frame(maxHeight: .infinity)
                    polishedDiaryPanel
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                originalTranscriptPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
#else
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !polishedText.isEmpty {
                        originalTranscriptPanel
                        polishedDiaryPanel
                    } else {
                        Text(recorder.transcript.isEmpty
                             ? (recorder.isStarting ? "正在准备语音识别…" : "你的口述文字会显示在这里。\n想到什么就慢慢说。")
                             : recorder.transcript)
                            .font(.system(.body, design: .rounded))
                            .lineSpacing(7)
                            .foregroundStyle(recorder.transcript.isEmpty ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(DiaryStyle.secondaryPaper, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
                .padding(.bottom, 8)
            }
#endif

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
#if os(macOS)
        .padding(.horizontal, 32)
#else
        .padding(.horizontal, 24)
#endif
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var originalTranscriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本次口述原文", systemImage: "waveform")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button {
                    startSupplementaryRecording()
                } label: {
                    Label("补充口述", systemImage: "mic")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
                .modifier(SystemSecondaryButton())
                .disabled(isPolishing || recorder.isRecording || recorder.isStarting || recorder.isFinalizing)
                .accessibilityLabel("补充口述原文")
            }
#if os(macOS)
            ScrollView { transcriptText }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#else
            transcriptText
#endif
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var transcriptText: some View {
        Text(displayedTranscript.isEmpty
             ? (recorder.isStarting ? "正在准备语音识别…" : "你的口述文字会显示在这里。\n想到什么就慢慢说。")
             : displayedTranscript)
            .font(.system(.body, design: .rounded))
            .lineSpacing(7)
            .foregroundStyle(displayedTranscript.isEmpty ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(18)
    }

    private var polishedDiaryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(mergedWithEarlier ? "合并后的今日日记" : "整理后的日记", systemImage: "text.alignleft")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    diaryEditorTarget = .currentDraft
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("全屏编辑日记")
                .help("全屏编辑日记")
            }
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
#if os(macOS)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
                .frame(minHeight: 300, maxHeight: 420)
#endif
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var bottomControl: some View {
        HStack {
            Spacer(minLength: 0)
            if !polishedText.isEmpty && !recorder.isRecording && !recorder.isStarting && !recorder.isFinalizing && !isPolishing {
                Button(action: saveDiary) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DiaryStyle.paper)
                        .frame(width: 42, height: 42)
                        .background(.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(saved)
                .opacity(saved ? 0.55 : 1)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityLabel("保存整理后的日记")
                .help("保存整理后的日记")
            } else {
#if os(macOS)
                VStack(spacing: 12) {
                    Button(action: bottomButtonAction) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 72, height: 72)
                            .modifier(SystemGlass())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .matchedGeometryEffect(id: "recording-button", in: recordingButtonAnimation)
                    .buttonStyle(.plain)
                    .disabled(isPolishing || recorder.isFinalizing || recorder.isStarting)
                    .accessibilityLabel(recorder.isRecording ? "结束口述" : "开始口述")

                    Text(bottomButtonTitle)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
#else
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
#endif
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var bottomButtonTitle: String {
        if recorder.isRecording { return "轻点结束口述" }
        if recorder.isStarting { return "正在准备…" }
        if recorder.isFinalizing { return "正在完成转写…" }
        if isPolishing { return "DeepSeek 正在整理…" }
        if errorMessage != nil && !recorder.transcript.isEmpty { return "重试 AI 整理" }
        return "重新开始口述"
    }

    private var displayedTranscript: String {
        guard isSupplementingDraft else { return recorder.transcript }
        return [transcriptBeforeSupplement, recorder.transcript]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private func startSupplementaryRecording() {
        guard !polishedText.isEmpty, !isPolishing, !recorder.isRecording, !recorder.isStarting, !recorder.isFinalizing else { return }
        transcriptBeforeSupplement = recorder.transcript
        isSupplementingDraft = true
        errorMessage = nil
        recorder.start()
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
            .font(DiaryStyle.historyTagFont)
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
        isSupplementingDraft = false
        transcriptBeforeSupplement = ""
        saved = false
        sessionCreatedAt = Date()
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
            errorMessage = recorder.hasDetectedAudibleSignal
                ? "麦克风已收到清晰声音，但系统没有返回文字。请检查网络和系统语音识别设置后再试。"
                : "没有检测到清晰的麦克风声音。若正在用 Xcode 查看手机画面，请关闭远程显示或改用无线调试；也请检查麦克风权限、音量和耳机连接。"
            return
        }
        isPolishing = true
        errorMessage = nil
        let spokenAt = recorder.recordingStartedAt ?? Date()
        do {
            let service = DeepSeekService()
            let result: PolishedDiary
            if isSupplementingDraft {
                let previous = "此前标题（仅作线索，需重新选择）：\(polishedTitle)\n此前特别记忆：\(polishedTags.joined(separator: "、"))\n此前日记正文：\(polishedText)"
                result = try await service.merge(existingDiary: previous, newRawText: displayedTranscript, spokenAt: spokenAt)
            } else {
                result = try await service.polish(rawText, spokenAt: spokenAt)
                mergedWithEarlier = false
            }
            polishedTitle = result.title
            polishedText = result.content
            polishedTags = result.tags
            if isSupplementingDraft {
                recorder.transcript = displayedTranscript
                isSupplementingDraft = false
                transcriptBeforeSupplement = ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isPolishing = false
    }

    private func saveDiary() {
        guard !saved else { return }
        let entry = DiaryEntry(createdAt: sessionCreatedAt, title: polishedTitle, content: polishedText, tags: polishedTags, rawTranscript: displayedTranscript)
        store.add(entry)
        Task { await store.syncWithNutstore() }
        saved = true
        recorder.stop()
        shouldPolish = false
        mergedWithEarlier = false
        isSupplementingDraft = false
        transcriptBeforeSupplement = ""
        polishedTitle = ""
        polishedText = ""
        polishedTags = []
        errorMessage = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { sessionStarted = false }
    }

    private func updateSelectedDiary(title: String? = nil, content: String? = nil, tags: [String]? = nil) {
        guard let entry = selectedDiary else { return }
        selectedDiary = DiaryEntry(
            id: entry.id,
            createdAt: entry.createdAt,
            title: title ?? entry.title,
            content: content ?? entry.content,
            tags: tags ?? entry.tags,
            rawTranscript: entry.rawTranscript,
            mergedEntryIDs: entry.mergedEntryIDs
        )
    }

    private func saveSelectedDiary() {
        guard let entry = selectedDiary else { return }
        store.upsert(entry)
        Task { await store.syncWithNutstore() }
    }

    private func summarizeDay(_ dayEntries: [DiaryEntry]) async {
        guard dayEntries.count > 1, let first = dayEntries.min(by: { $0.createdAt < $1.createdAt }) else { return }
        let key = diaryDayKey(first.createdAt)
        summarizingDayKey = key
        defer { summarizingDayKey = nil }
        let orderedEntries = dayEntries.sorted { $0.createdAt < $1.createdAt }
        let records = orderedEntries.map { entry in
            let transcript = entry.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.isEmpty { return "现有日记正文：\n\(entry.content)" }
            return "口述原文：\n\(transcript)\n\n此前整理稿：\n\(entry.content)"
        }
        do {
            let result = try await DeepSeekService().summarize(records: records, spokenAt: first.createdAt)
            let transcript = orderedEntries
                .map { $0.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.content : $0.rawTranscript }
                .joined(separator: "\n\n")
            let summary = DiaryEntry(
                createdAt: first.createdAt,
                title: result.title,
                content: result.content,
                tags: result.tags,
                rawTranscript: transcript,
                mergedEntryIDs: dayEntries.flatMap { $0.mergedEntryIDs + [$0.id] }
            )
            store.replaceDay(first.createdAt, with: summary)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FullscreenDiaryEditor: View {
    private enum Field: Hashable {
        case title, content, tags
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @Binding var title: String
    @Binding var content: String
    @Binding var tags: [String]
    var onSave: () -> Void = {}
    @State private var draftTitle = ""
    @State private var draftContent = ""
    @State private var draftTags = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("日记标题", text: $draftTitle)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .title)
                    .accessibilityLabel("编辑日记标题")

                TextEditor(text: $draftContent)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(8)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .content)
                    .accessibilityLabel("编辑日记正文")
                    .overlay(alignment: .topLeading) {
                        if draftContent.isEmpty {
                            Text("在这里修改整理后的日记…")
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                TextField("特别记忆标签（用逗号分隔）", text: $draftTags)
                    .font(.system(.subheadline, design: .rounded))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .tags)
                    .accessibilityLabel("编辑日记标签")
            }
            .padding(20)
            .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DiaryStyle.paper)
            .navigationTitle("编辑今日日记")
            .modifier(InlineNavigationTitle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        let parsedTags = draftTags
                            .split(whereSeparator: { $0 == "," || $0 == "，" })
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        tags = []
                        for tag in parsedTags {
                            if tags.count == 2 { break }
                            tags.append(tag)
                        }
                        onSave()
                        dismiss()
                    }
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { focusedField = nil }
                }
#endif
            }
        }
        .onAppear {
            draftTitle = title
            draftContent = content
            draftTags = tags.joined(separator: "，")
        }
    }
}
