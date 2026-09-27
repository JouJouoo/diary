import SwiftUI

struct ChinaHolidayCalendar {
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

struct DiaryCalendarPicker: View {
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
                        .font(.appSystem(.headline, design: .rounded, weight: .semibold))
                    Spacer()
                    monthButton(systemName: "chevron.right", offset: 1, label: "下个月")
                }
                .padding(.horizontal, 2)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(weekdays.indices, id: \.self) { index in
                        Text(weekdays[index])
                            .font(.appSystem(.caption, design: .rounded, weight: .medium))
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
                        .font(.appSystem(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("有小点的日期保存过日记", systemImage: "circle.fill")
                        .font(.appSystem(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .navigationTitle("日记日历")
            .modifier(InlineNavigationTitle())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("日记日历").font(.appSystem(.headline))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(CalendarSheetPresentation())
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
                .font(.appSystem(size: 13, weight: .semibold))
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
                    .font(.appSystem(.subheadline, design: .rounded, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? DiaryStyle.paper : Color.primary)
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
