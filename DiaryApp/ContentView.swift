import SwiftUI

struct ContentView: View {
    private enum DiaryEditorTarget: String, Identifiable {
        case currentDraft
        var id: String { rawValue }
    }

    private enum ImprovementTarget: String, Identifiable, Equatable {
        case currentDraft, mergedDiary
        var id: String { rawValue }
    }

    private struct MergeUndoSnapshot {
        let sourceEntries: [DiaryEntry]
        let mergedEntryID: UUID
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
    @State private var improvementTarget: ImprovementTarget?
    @State private var showingDiaryList = false
    @State private var selectedDiary: DiaryEntry?
    @State private var originalDiaryBeforeEditing: DiaryEntry?
    @State private var isEditingSelectedDiary = false
    @State private var editingSelectedTags = ""
    @State private var showingCalendar = false
    @State private var isSelectingEntriesToMerge = false
    @State private var selectedMergeEntryIDs: Set<UUID> = []
    @State private var isSelectingEntriesToDelete = false
    @State private var selectedDeleteEntryIDs: Set<UUID> = []
    @State private var showingDeleteConfirmation = false
    @State private var pendingCalendarEntry: DiaryEntry?
    @State private var isSummarizingSelection = false
    @State private var mergeErrorMessage: String?
    @State private var mergeUndoSnapshot: MergeUndoSnapshot?
    @State private var showingSettings = false
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var sessionCreatedAt = Date()
    @State private var draftGeneration = UUID()
    @State private var didResetOnLaunch = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                DiaryStyle.paper.ignoresSafeArea()
#if os(macOS)
                if showingDiaryList {
                    savedDiaryBrowser
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .leading))
                        .zIndex(2)
                } else {
                    mainPage
                }
#else
                if showingDiaryList {
                    savedDiaryBrowser
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .leading))
                        .zIndex(2)
                } else {
                    mainPage
                }
#endif
            }
            .modifier(HiddenNavigationBar())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if sessionStarted && !showingDiaryList && diaryEditorTarget == nil { bottomControl }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(store: store) }
#if !os(macOS)
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
            .sheet(item: $improvementTarget) { target in
                ImprovementPromptSheet(
                    title: target == .mergedDiary ? "改进合并结果" : "改进整理稿",
                    onCancel: { improvementTarget = nil },
                    onSubmit: { prompt in
                        improvementTarget = nil
                        switch target {
                        case .currentDraft:
                            Task { await polishTranscript(improvementPrompt: prompt) }
                        case .mergedDiary:
                            Task { await repolishLastMerge(improvementPrompt: prompt) }
                        }
                    }
                )
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
            .onAppear(perform: resetToInitialScreenOnLaunch)
            .task { await store.syncWithNutstore() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.syncWithNutstore() } }
            }
            .modifier(DismissKeyboardOnOutsideTap())
        }
    }

    private var mainPage: some View {
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

    private var selectedDiaryTitle: Binding<String> {
        Binding(get: { selectedDiary?.title ?? "" }, set: { updateSelectedDiary(title: $0) })
    }

    @ViewBuilder
    private func diaryEditor(for target: DiaryEditorTarget) -> some View {
        switch target {
        case .currentDraft:
            FullscreenDiaryEditor(title: $polishedTitle, content: $polishedText, tags: $polishedTags)
        }
    }

    private var groupedEntries: [(key: String, date: Date, entries: [DiaryEntry])] {
        let sortedEntries = store.entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let todayKey = diaryDayKey(Date())
        let todayEntries = sortedEntries.filter { diaryDayKey($0.createdAt) == todayKey }
        let earlierEntries = sortedEntries.filter { diaryDayKey($0.createdAt) != todayKey }

        var groups: [(key: String, date: Date, entries: [DiaryEntry])] = []
        if let firstTodayEntry = todayEntries.first {
            groups.append(("today", firstTodayEntry.createdAt, todayEntries))
        }
        if let firstEarlierEntry = earlierEntries.first {
            groups.append(("earlier", firstEarlierEntry.createdAt, earlierEntries))
        }
        return groups
    }

    private var selectedDiaryContent: Binding<String> {
        Binding(get: { selectedDiary?.content ?? "" }, set: { updateSelectedDiary(content: $0) })
    }

    private var selectedDiaryTags: Binding<[String]> {
        Binding(get: { selectedDiary?.tags ?? [] }, set: { updateSelectedDiary(tags: $0) })
    }

    private var selectedDiaryTagsText: Binding<String> {
        Binding(
            get: { editingSelectedTags },
            set: { value in
                editingSelectedTags = value
                updateSelectedDiary(tags: Array(value
                    .split(whereSeparator: { $0 == "," || $0 == "，" })
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(2)))
            }
        )
    }

    private var header: some View {
        HStack {
            Button {
                if sessionStarted {
                    cancelCurrentSession()
                } else {
                    guard !recorder.isRecording, !recorder.isStarting, !isPolishing, !recorder.isFinalizing else { return }
                    selectedDiary = nil
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = true }
                }
            } label: {
                Image(systemName: sessionStarted ? "xmark" : "list.bullet")
                    .font(.appSystem(size: 19, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .modifier(SystemGlass())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sessionStarted ? "取消本次记录并返回首页" : "查看所有日记")
            .help(sessionStarted ? "取消本次记录" : "查看所有日记")
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.appSystem(size: 17, weight: .medium))
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
                    if isSelectingEntriesToMerge {
                        cancelEntryMergeSelection()
                    } else if isSelectingEntriesToDelete {
                        cancelEntryDeleteSelection()
                    } else if isEditingSelectedDiary {
                        cancelSelectedDiaryEditing()
                    } else if selectedDiary != nil {
                        withAnimation(.easeInOut(duration: 0.22)) { selectedDiary = nil }
                    } else {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = false }
                    }
                } label: {
                    Image(systemName: isSelectingEntriesToMerge || isSelectingEntriesToDelete ? "xmark" : "chevron.left")
                        .font(.appSystem(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .modifier(SystemGlass())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelectingEntriesToMerge ? "取消合并选择" : (isSelectingEntriesToDelete ? "取消删除选择" : (isEditingSelectedDiary ? "取消编辑" : (selectedDiary == nil ? "返回主页" : "返回日记列表"))))
                Spacer()
                Text(isSelectingEntriesToMerge ? (mergeAnchorDayKey.map { "合并日记 · \($0)" } ?? "选择要合并的日记") : (isSelectingEntriesToDelete ? "选择日记" : (selectedDiary == nil ? "" : "日记详情")))
                    .font(.appSystem(.title3, design: .rounded, weight: .semibold))
                Spacer()
                if selectedDiary == nil && isSelectingEntriesToDelete {
                    HStack(spacing: 8) {
                        Button(selectedDeleteEntryIDs.count == store.entries.count ? "取消全选" : "全选") {
                            toggleSelectAllEntries()
                        }
                        .font(.appSystem(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .modifier(SystemGlassCapsule())
                        .buttonStyle(.plain)
                        .accessibilityLabel(selectedDeleteEntryIDs.count == store.entries.count ? "取消全选" : "全选日记")

                        Button {
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.appSystem(size: 17, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(width: 44, height: 40)
                                .modifier(SystemGlassCapsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedDeleteEntryIDs.isEmpty)
                        .accessibilityLabel("删除已选的 \(selectedDeleteEntryIDs.count) 篇日记")
                    }
                } else if selectedDiary == nil && isSelectingEntriesToMerge {
                    Button {
                        Task { await summarizeEntries(selectedMergeEntries) }
                    } label: {
                        if isSummarizingSelection {
                            ProgressView().controlSize(.small).frame(width: 68, height: 40)
                        } else {
                            Text("合并 \(selectedMergeEntryIDs.count)")
                                .font(.appSystem(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(DiaryStyle.paper)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .background(Color.primary, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedMergeEntryIDs.count < 2 || isSummarizingSelection)
                    .accessibilityLabel("合并已选的 \(selectedMergeEntryIDs.count) 篇日记")
                } else if selectedDiary == nil {
                    HStack(spacing: 8) {
                        Button {
                            showingCalendar = true
                        } label: {
                            Image(systemName: "calendar")
                                .font(.appSystem(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .modifier(SystemGlass())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("按日历查找日记")

                        Button {
                            isSelectingEntriesToMerge = true
                            selectedMergeEntryIDs = []
                            mergeErrorMessage = nil
                        } label: {
                            if isSummarizingSelection {
                                ProgressView().controlSize(.small).frame(width: 44, height: 44)
                            } else {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.appSystem(size: 17, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .modifier(SystemGlass())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.entries.count < 2 || isSummarizingSelection)
                        .accessibilityLabel("选择日记进行合并")

                        Button {
                            isSelectingEntriesToDelete = true
                            selectedDeleteEntryIDs = []
                        } label: {
                            Image(systemName: "checklist")
                                .font(.appSystem(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .modifier(SystemGlass())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("选择日记进行删除")
                    }
                } else {
                    if isEditingSelectedDiary {
                        HStack(spacing: 8) {
                            Button {
                                cancelSelectedDiaryEditing()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.appSystem(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 42, height: 42)
                                    .modifier(SystemGlass())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("取消编辑")

                            Button {
                                saveSelectedDiary()
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundStyle(DiaryStyle.paper)
                                    .frame(width: 42, height: 42)
                                    .background(.primary, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("保存日记")
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                guard let entry = selectedDiary else { return }
                                Task { await store.uploadEntryToNutstore(entry.id) }
                            } label: {
                                if store.isSyncing {
                                    ProgressView().controlSize(.small).frame(width: 44, height: 44)
                                } else {
                                    Image(systemName: "icloud.and.arrow.up")
                                        .font(.appSystem(size: 16, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .frame(width: 44, height: 44)
                                        .modifier(SystemGlass())
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isSyncing)
                            .accessibilityLabel("仅上传这篇日记到云端")
                            .help("仅上传这篇日记到云端")

                            Button {
                                beginSelectedDiaryEditing()
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.appSystem(size: 16, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .modifier(SystemGlass())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("编辑这篇日记")
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }

            if isSelectingEntriesToMerge {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mergeAnchorDayKey == nil
                         ? "先选一篇日记确定日期，再选同一天的记录。"
                         : "已选 \(selectedMergeEntryIDs.count) 篇；只能选择同一天的日记。")
                    if let mergeErrorMessage {
                        Text(mergeErrorMessage).foregroundStyle(.red)
                    }
                }
                .font(.appSystem(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            } else if isSelectingEntriesToDelete {
                Text("已选 \(selectedDeleteEntryIDs.count) 篇日记")
                    .font(.appSystem(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            } else if let mergeErrorMessage {
                Text(mergeErrorMessage)
                    .font(.appSystem(.footnote, design: .rounded))
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }

            if let entry = selectedDiary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if store.lastSingleUploadEntryID == entry.id &&
                            (store.syncMessage.hasPrefix("正在上传这篇日记") || store.syncMessage.hasPrefix("单篇上传")) {
                            Text(store.syncMessage)
                                .font(.appSystem(.footnote, design: .rounded))
                                .foregroundStyle(store.syncMessage.hasPrefix("单篇上传失败") ? Color.red : Color.secondary)
                        }
                        if mergeUndoSnapshot?.mergedEntryID == entry.id {
                            HStack(spacing: 10) {
                                Label("合并结果", systemImage: "arrow.triangle.merge")
                                    .font(.appSystem(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button {
                                    undoLastMerge()
                                } label: {
                                    Label("撤回", systemImage: "arrow.uturn.backward")
                                        .font(.appSystem(.subheadline, design: .rounded, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .disabled(isSummarizingSelection)
                                .accessibilityLabel("撤回这次合并")

                                Button {
                                    improvementTarget = .mergedDiary
                                } label: {
                                    if isSummarizingSelection {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("重新润色", systemImage: "sparkles")
                                            .font(.appSystem(.subheadline, design: .rounded, weight: .medium))
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isSummarizingSelection)
                                .accessibilityLabel("让 AI 重新润色这次合并")
                            }
                            .padding(14)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        }
                        Text(entry.createdAt.formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                            .font(DiaryStyle.diaryDateFont)
                            .foregroundStyle(.secondary)
                        if isEditingSelectedDiary {
                            TextField("日记标题", text: selectedDiaryTitle)
                                .font(DiaryStyle.diaryTitleFont)
                                .textFieldStyle(.plain)
                                .accessibilityLabel("编辑日记标题")
                            TextField("标签（用逗号分隔）", text: selectedDiaryTagsText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("编辑日记标签")
                            TextEditor(text: selectedDiaryContent)
                                .font(DiaryStyle.diaryContentFont)
                                .lineSpacing(DiaryStyle.diaryContentLineSpacing)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 360)
                                .padding(12)
                                .background(DiaryStyle.secondaryPaper.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityLabel("编辑日记正文")
                        } else {
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
                        }
                        if !entry.rawTranscript.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("口述原文", systemImage: "waveform")
                                    .font(.appSystem(.headline, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Text(entry.rawTranscript)
                                    .font(.appSystem(.body, design: .rounded))
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
                        .font(.appSystem(size: 34, weight: .regular))
                        .foregroundStyle(.tertiary)
                    Text("还没有日记")
                        .font(.appSystem(.title3, design: .rounded, weight: .semibold))
                    Text(store.syncMessage)
                        .font(.appSystem(.body, design: .rounded))
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
                    if let todayGroup = groupedEntries.first(where: { $0.key == "today" }) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar")
                                    .font(.appSystem(.subheadline, weight: .semibold))
                                Text("今天")
                                    .font(.appSystem(.headline, design: .rounded, weight: .bold))
                                Spacer()
                                Text("\(todayGroup.entries.count) 篇")
                                    .font(.appSystem(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 8)

                            ForEach(Array(todayGroup.entries.enumerated()), id: \.offset) { index, entry in
                                if index > 0 {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.16))
                                        .frame(height: 1)
                                        .padding(.leading, 14)
                                }
                                diaryEntryButton(entry, inTodayGroup: true)
                            }
                        }
                        .padding(8)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                    }

                    ForEach(groupedEntries.first(where: { $0.key == "earlier" })?.entries ?? []) { entry in
                        diaryEntryButton(entry, inTodayGroup: false)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
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
            if isSelectingEntriesToMerge { cancelEntryMergeSelection() }
            else if isSelectingEntriesToDelete { cancelEntryDeleteSelection() }
            else if isEditingSelectedDiary { cancelSelectedDiaryEditing() }
            else if selectedDiary != nil { selectedDiary = nil }
            else { withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { showingDiaryList = false } }
        })
        .alert("删除已选的 \(selectedDeleteEntryIDs.count) 篇日记？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) { deleteSelectedEntries() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private func diaryEntryButton(_ entry: DiaryEntry, inTodayGroup: Bool) -> some View {
        Button {
            if isSelectingEntriesToDelete {
                toggleDeleteSelection(entry)
            } else if isSelectingEntriesToMerge {
                toggleMergeSelection(entry)
            } else {
                isEditingSelectedDiary = false
                originalDiaryBeforeEditing = nil
                withAnimation(.easeInOut(duration: 0.22)) { selectedDiary = entry }
            }
        } label: {
            HStack(spacing: 14) {
                if isSelectingEntriesToMerge || isSelectingEntriesToDelete {
                    let isSelected = isSelectingEntriesToMerge
                        ? selectedMergeEntryIDs.contains(entry.id)
                        : selectedDeleteEntryIDs.contains(entry.id)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.appSystem(size: 22))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
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
                if isSelectingEntriesToMerge {
                    if mergeAnchorDayKey != nil && diaryDayKey(entry.createdAt) != mergeAnchorDayKey {
                        Text("不同日期")
                            .font(.appSystem(.caption2, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                } else if !isSelectingEntriesToDelete {
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                inTodayGroup ? Color.clear : DiaryStyle.secondaryPaper.opacity(0.62),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(Rectangle())
        }
        .disabled(isSelectingEntriesToMerge && mergeAnchorDayKey != nil && diaryDayKey(entry.createdAt) != mergeAnchorDayKey)
        .opacity(isSelectingEntriesToMerge && mergeAnchorDayKey != nil && diaryDayKey(entry.createdAt) != mergeAnchorDayKey ? 0.4 : 1)
        .buttonStyle(.plain)
    }

    private var welcomeContent: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("把今天说给我听")
                .font(.appSystem(.largeTitle, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
            Text("不用想好怎么写，开始说就好。")
                .font(.appSystem(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: beginDiary) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.045)).frame(width: 204, height: 204)
                    Circle().fill(.ultraThinMaterial)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
                        .frame(width: 164, height: 164)
                    Image(systemName: "mic.fill")
                        .font(.appSystem(size: 48, weight: .regular))
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
                .font(.appSystem(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.appSystem(.footnote)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            Text("你的日记会先保存在这台设备上")
                .font(.appSystem(.footnote, design: .rounded))
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
                    .font(.appSystem(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)

                if recorder.transcript.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.appSystem(size: 30, weight: .regular))
                            .foregroundStyle(.tertiary)
                        Text(recorder.isStarting ? "正在准备语音识别…" : "正在聆听")
                            .font(.appSystem(.title3, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("想到哪里，就从哪里说起。")
                            .font(.appSystem(.body, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                } else {
                    ScrollView {
                        Text(recorder.transcript)
                            .font(.appSystem(size: 21, design: .rounded))
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
                .font(.appSystem(size: polishedText.isEmpty ? 32 : 26, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: polishedText.isEmpty ? .center : .leading)
#else
                .font(.appSystem(.title2, design: .rounded, weight: .medium))
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
                        originalTranscriptPanel
                    }
                }
                .padding(.bottom, 8)
            }
#endif

            if isPolishing || recorder.isFinalizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(recorder.isFinalizing ? "正在完成语音转写…" : "DeepSeek 正在整理日记…")
                        .font(.appSystem(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            if let errorMessage {
                Text(errorMessage).font(.appSystem(.footnote)).foregroundStyle(.red).multilineTextAlignment(.center)
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
                    .font(.appSystem(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button {
                    startSupplementaryRecording()
                } label: {
                    Image(systemName: "mic")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isPolishing || recorder.isRecording || recorder.isStarting || recorder.isFinalizing)
                .accessibilityLabel("补充口述原文")
                .help("补充口述")
            }
#if os(macOS)
            transcriptText
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .topLeading)
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
        ZStack(alignment: .topLeading) {
            if displayedTranscript.isEmpty {
                Text(recorder.isStarting ? "正在准备语音识别…" : "你的口述文字会显示在这里，也可以直接修改。")
                    .font(.appSystem(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
            }
            TextEditor(text: transcriptEditorBinding)
                .font(.appSystem(.body, design: .rounded))
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .disabled(isPolishing || recorder.isRecording || recorder.isStarting || recorder.isFinalizing)
                .accessibilityLabel("编辑口述原文")
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
    }

    private var polishedDiaryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(mergedWithEarlier ? "合并后的今日日记" : "整理后的日记", systemImage: "text.alignleft")
                    .font(.appSystem(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    improvementTarget = .currentDraft
                } label: {
                    Image(systemName: "sparkles")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(displayedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPolishing || recorder.isRecording || recorder.isStarting || recorder.isFinalizing)
                .accessibilityLabel("根据口述原文重新整理日记")
                .help("重新整理")
#if os(iOS)
                Button {
                    diaryEditorTarget = .currentDraft
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("全屏编辑日记")
                .help("全屏编辑日记")
#endif
            }
            TextField("日记标题", text: $polishedTitle)
                .font(.appSystem(.title3, design: .serif, weight: .semibold))
                .foregroundStyle(.primary)
                .textFieldStyle(.plain)
                .accessibilityLabel("编辑日记标题")
            TextEditor(text: $polishedText)
                .font(.appSystem(.body, design: .serif))
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
                        .font(.appSystem(size: 17, weight: .semibold))
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
                            .font(.appSystem(size: 23, weight: .semibold))
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
                        .font(.appSystem(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
#else
                Button(action: bottomButtonAction) {
                    HStack(spacing: 12) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.appSystem(size: 20, weight: .semibold))
                            .frame(width: 58, height: 58)
                            .modifier(SystemGlass())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                            .matchedGeometryEffect(id: "recording-button", in: recordingButtonAnimation)
                        Text(bottomButtonTitle)
                            .font(.appSystem(.subheadline, design: .rounded, weight: .medium))
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

    private var transcriptEditorBinding: Binding<String> {
        Binding(
            get: { displayedTranscript },
            set: { editedTranscript in
                recorder.transcript = editedTranscript
                if isSupplementingDraft {
                    transcriptBeforeSupplement = ""
                    isSupplementingDraft = false
                }
            }
        )
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
        draftGeneration = UUID()
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

    private func resetToInitialScreenOnLaunch() {
        guard !didResetOnLaunch else { return }
        didResetOnLaunch = true
        recorder.cancel()
        sessionStarted = false
        showingDiaryList = false
        showingSettings = false
        showingCalendar = false
        diaryEditorTarget = nil
        selectedDiary = nil
        pendingCalendarEntry = nil
    }

    private func cancelCurrentSession() {
        draftGeneration = UUID()
        shouldPolish = false
        recorder.cancel()
        isPolishing = false
        sessionStarted = false
        showingDiaryList = false
        showingSettings = false
        showingCalendar = false
        diaryEditorTarget = nil
        selectedDiary = nil
        isSupplementingDraft = false
        transcriptBeforeSupplement = ""
        polishedTitle = ""
        polishedText = ""
        polishedTags = []
        mergedWithEarlier = false
        errorMessage = nil
        saved = false
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
    private func polishTranscript(improvementPrompt: String = "") async {
        let rawText = recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            errorMessage = recorder.hasDetectedAudibleSignal
                ? "麦克风已收到清晰声音，但系统没有返回文字。请检查网络和系统语音识别设置后再试。"
                : "没有检测到清晰的麦克风声音。若正在用 Xcode 查看手机画面，请关闭远程显示或改用无线调试；也请检查麦克风权限、音量和耳机连接。"
            return
        }
        isPolishing = true
        errorMessage = nil
        let generation = draftGeneration
        let spokenAt = recorder.recordingStartedAt ?? Date()
        do {
            let service = DeepSeekService()
            let result: PolishedDiary
            if isSupplementingDraft {
                let previous = "此前标题（仅作线索，需重新选择）：\(polishedTitle)\n此前特别记忆：\(polishedTags.joined(separator: "、"))\n此前日记正文：\(polishedText)"
                result = try await service.supplementDraft(draft: previous, newRawText: displayedTranscript, spokenAt: spokenAt, improvementPrompt: improvementPrompt)
            } else {
                result = try await service.polish(rawText, spokenAt: spokenAt, improvementPrompt: improvementPrompt)
                mergedWithEarlier = false
            }
            guard generation == draftGeneration else { return }
            polishedTitle = result.title
            polishedText = result.content
            polishedTags = result.tags
            if isSupplementingDraft {
                recorder.transcript = displayedTranscript
                isSupplementingDraft = false
                transcriptBeforeSupplement = ""
            }
        } catch {
            if generation == draftGeneration { errorMessage = error.localizedDescription }
        }
        if generation == draftGeneration { isPolishing = false }
    }

    private func saveDiary() {
        guard !saved else { return }
        draftGeneration = UUID()
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
        isEditingSelectedDiary = false
        originalDiaryBeforeEditing = nil
    }

    private func beginSelectedDiaryEditing() {
        guard let entry = selectedDiary else { return }
        originalDiaryBeforeEditing = entry
        editingSelectedTags = entry.tags.joined(separator: "，")
        isEditingSelectedDiary = true
    }

    private func cancelSelectedDiaryEditing() {
        if let originalDiaryBeforeEditing { selectedDiary = originalDiaryBeforeEditing }
        isEditingSelectedDiary = false
        originalDiaryBeforeEditing = nil
    }

    private func summarizeEntries(_ selectedEntries: [DiaryEntry]) async {
        guard selectedEntries.count > 1,
              let first = selectedEntries.min(by: { $0.createdAt < $1.createdAt }),
              Set(selectedEntries.map { diaryDayKey($0.createdAt) }).count == 1 else { return }
        isSummarizingSelection = true
        defer { isSummarizingSelection = false }
        let orderedEntries = selectedEntries.sorted { $0.createdAt < $1.createdAt }
        let files = orderedEntries.map(\.markdown)
        do {
            let result = try await DeepSeekService().summarize(files: files)
            let transcript = orderedEntries
                .map { $0.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.content : $0.rawTranscript }
                .joined(separator: "\n\n")
            let summary = DiaryEntry(
                createdAt: first.createdAt,
                title: result.title,
                content: result.content,
                tags: result.tags,
                rawTranscript: transcript,
                mergedEntryIDs: orderedEntries.flatMap { $0.mergedEntryIDs + [$0.id] }
            )
            guard store.replaceSelectedEntries(Set(orderedEntries.map(\.id)), with: summary) else {
                mergeErrorMessage = "选中的日记已发生变化，请重新选择后再试。"
                return
            }
            mergeUndoSnapshot = MergeUndoSnapshot(sourceEntries: orderedEntries, mergedEntryID: summary.id)
            selectedMergeEntryIDs = []
            isSelectingEntriesToMerge = false
            isEditingSelectedDiary = false
            originalDiaryBeforeEditing = nil
            selectedDiary = summary
            mergeErrorMessage = nil
            await store.syncWithNutstore()
        } catch {
            mergeErrorMessage = error.localizedDescription
        }
    }

    private func undoLastMerge() {
        guard !isSummarizingSelection, let snapshot = mergeUndoSnapshot else { return }
        guard store.undoMerge(snapshot.mergedEntryID, restoring: snapshot.sourceEntries) else {
            mergeErrorMessage = "找不到这次合并的结果，无法撤回。"
            return
        }
        mergeUndoSnapshot = nil
        mergeErrorMessage = nil
        selectedDiary = nil
        Task { await store.syncWithNutstore() }
    }

    @MainActor
    private func repolishLastMerge(improvementPrompt: String) async {
        guard !isSummarizingSelection,
              let snapshot = mergeUndoSnapshot,
              let existingSummary = store.entries.first(where: { $0.id == snapshot.mergedEntryID }) else { return }
        isSummarizingSelection = true
        defer { isSummarizingSelection = false }
        let sourceEntries = snapshot.sourceEntries.sorted { $0.createdAt < $1.createdAt }
        do {
            let result = try await DeepSeekService().summarize(files: sourceEntries.map(\.markdown), improvementPrompt: improvementPrompt)
            let revisedSummary = DiaryEntry(
                id: existingSummary.id,
                createdAt: existingSummary.createdAt,
                title: result.title,
                content: result.content,
                tags: result.tags,
                rawTranscript: existingSummary.rawTranscript,
                mergedEntryIDs: existingSummary.mergedEntryIDs
            )
            guard store.replaceMergedEntry(existingSummary.id, with: revisedSummary) else {
                mergeErrorMessage = "合并结果已发生变化，请刷新日记列表后重试。"
                return
            }
            selectedDiary = revisedSummary
            mergeErrorMessage = nil
            await store.syncWithNutstore()
        } catch {
            mergeErrorMessage = error.localizedDescription
        }
    }

    private var selectedMergeEntries: [DiaryEntry] {
        store.entries.filter { selectedMergeEntryIDs.contains($0.id) }
    }

    private var mergeAnchorDayKey: String? {
        selectedMergeEntries.first.map { diaryDayKey($0.createdAt) }
    }

    private func toggleMergeSelection(_ entry: DiaryEntry) {
        guard !isSummarizingSelection else { return }
        if selectedMergeEntryIDs.contains(entry.id) {
            selectedMergeEntryIDs.remove(entry.id)
        } else if mergeAnchorDayKey == nil || diaryDayKey(entry.createdAt) == mergeAnchorDayKey {
            selectedMergeEntryIDs.insert(entry.id)
        }
    }

    private func cancelEntryMergeSelection() {
        guard !isSummarizingSelection else { return }
        isSelectingEntriesToMerge = false
        selectedMergeEntryIDs = []
        mergeErrorMessage = nil
    }

    private func toggleDeleteSelection(_ entry: DiaryEntry) {
        if selectedDeleteEntryIDs.contains(entry.id) {
            selectedDeleteEntryIDs.remove(entry.id)
        } else {
            selectedDeleteEntryIDs.insert(entry.id)
        }
    }

    private func toggleSelectAllEntries() {
        if selectedDeleteEntryIDs.count == store.entries.count {
            selectedDeleteEntryIDs = []
        } else {
            selectedDeleteEntryIDs = Set(store.entries.map(\.id))
        }
    }

    private func cancelEntryDeleteSelection() {
        isSelectingEntriesToDelete = false
        selectedDeleteEntryIDs = []
    }

    private func deleteSelectedEntries() {
        store.deleteEntries(selectedDeleteEntryIDs)
        cancelEntryDeleteSelection()
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
                    .font(.appSystem(.title2, design: .serif, weight: .semibold))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .title)
                    .accessibilityLabel("编辑日记标题")

                TextEditor(text: $draftContent)
                    .font(.appSystem(.body, design: .serif))
                    .lineSpacing(8)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .content)
                    .accessibilityLabel("编辑日记正文")
                    .overlay(alignment: .topLeading) {
                        if draftContent.isEmpty {
                            Text("在这里修改整理后的日记…")
                                .font(.appSystem(.body, design: .serif))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                TextField("特别记忆标签（用逗号分隔）", text: $draftTags)
                    .font(.appSystem(.subheadline, design: .rounded))
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
                ToolbarItem(placement: .principal) {
                    Text("编辑今日日记").font(.appSystem(.headline))
                }
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

private struct ImprovementPromptSheet: View {
    let title: String
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.appSystem(.title3, design: .rounded, weight: .semibold))
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("发送给 AI") {
                    onSubmit(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("写下你希望改进的方向，例如调整语气、结构或细节。")
                .font(.appSystem(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)

            TextEditor(text: $prompt)
                .font(.appSystem(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(DiaryStyle.secondaryPaper, in: RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("例如：保留原来的口语感，少一些抒情，多写清楚事情经过……")
                            .font(.appSystem(.body, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("输入重新润色的改进建议")
        }
        .padding(20)
#if os(macOS)
        .frame(minWidth: 520, minHeight: 360)
#else
        .frame(maxWidth: .infinity, minHeight: 340)
#endif
        .background(DiaryStyle.paper)
    }
}
