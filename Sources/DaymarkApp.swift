import SwiftUI
import AppKit
import UserNotifications

enum Palette {
    static let canvas = Color(hex: 0xF8F9FA)
    static let card = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x303943)
    static let secondary = Color(hex: 0x7C8791)
    static let line = Color(hex: 0xE6E9ED)
    static let forest = Color(hex: 0x4C6560)
    static let forestLight = Color(hex: 0xEDF2F0)
    static let coral = Color(hex: 0xEF7058)
    static let gold = Color(hex: 0xDEA627)
    static let lilac = Color(hex: 0x8976C5)
    static let butter = Color(hex: 0xF2F4F6)
    static let sky = Color(hex: 0xF2F4F6)
    static let nowBlue = Color(hex: 0x3983E6)
}

enum RepeatRule: String, CaseIterable, Codable, Identifiable {
    case none = "不重复", daily = "每天", weekly = "每周", monthly = "每月", yearly = "每年"
    var id: String { rawValue }
}

struct ReminderTask: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var startAt: Date
    var dueAt: Date
    var priority: Int
    var repeatRule: RepeatRule
    var reminderMinutes: Int
    var note: String
    var isComplete = false

    enum CodingKeys: String, CodingKey { case id, title, createdAt, startAt, dueAt, priority, repeatRule, reminderMinutes, note, isComplete }
    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), startAt: Date, dueAt: Date, priority: Int, repeatRule: RepeatRule, reminderMinutes: Int, note: String, isComplete: Bool = false) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.startAt = startAt; self.dueAt = dueAt; self.priority = priority; self.repeatRule = repeatRule; self.reminderMinutes = reminderMinutes; self.note = note; self.isComplete = isComplete
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        dueAt = try c.decode(Date.self, forKey: .dueAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt) ?? createdAt
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 3
        repeatRule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .none
        reminderMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderMinutes) ?? 30
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(startAt, forKey: .startAt); try c.encode(dueAt, forKey: .dueAt); try c.encode(priority, forKey: .priority); try c.encode(repeatRule, forKey: .repeatRule)
        try c.encode(reminderMinutes, forKey: .reminderMinutes); try c.encode(note, forKey: .note); try c.encode(isComplete, forKey: .isComplete)
    }
}

@MainActor final class TaskStore: ObservableObject {
    @Published var tasks: [ReminderTask] = [] { didSet { save(); refreshNotifications() } }
    @Published var notificationStatus = "正在检查提醒权限…"
    @Published var notificationDetail = ""
    @Published var notificationAuthorized = false
    private let url: URL
    private let center = UNUserNotificationCenter.current()
    private var scheduleTask: Task<Void, Never>?
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("Daymark", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("tasks.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ReminderTask].self, from: data) { tasks = saved }
        refreshNotifications()
    }
    private func save() { if let data = try? JSONEncoder().encode(tasks) { try? data.write(to: url, options: .atomic) } }
    func add(_ task: ReminderTask) { tasks.append(task) }
    func update(_ task: ReminderTask) { guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }; tasks[i] = task }
    func remove(_ task: ReminderTask) { tasks.removeAll { $0.id == task.id } }
    func toggle(_ task: ReminderTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if task.repeatRule == .none { tasks[i].isComplete.toggle() }
        else { let duration = task.dueAt.timeIntervalSince(task.startAt); tasks[i].dueAt = nextOccurrence(after: task.dueAt, rule: task.repeatRule); tasks[i].startAt = tasks[i].dueAt.addingTimeInterval(-duration); tasks[i].createdAt = Date(); tasks[i].isComplete = false }
    }
    func requestNotifications() {
        Task {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]); refreshNotifications() }
            catch { notificationStatus = "提醒权限请求失败"; notificationDetail = error.localizedDescription }
        }
    }
    func sendTestNotification() {
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                notificationStatus = "提醒未开启"; notificationDetail = "请先允许系统通知。"; return
            }
            let content = UNMutableNotificationContent()
            content.title = "时序 · 提醒测试"
            content.body = "如果看到这条消息，系统通知已可用。"
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: "daymark.test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
                notificationDetail = "测试通知已提交，约 5 秒后显示。"
            } catch { notificationDetail = "测试通知提交失败：\(error.localizedDescription)" }
        }
    }
    func refreshNotifications() {
        scheduleTask?.cancel()
        scheduleTask = Task {
            let settings = await center.notificationSettings()
            guard !Task.isCancelled else { return }
            let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            notificationAuthorized = authorized
            guard authorized else {
                notificationStatus = settings.authorizationStatus == .denied ? "系统通知已关闭" : "提醒尚未授权"
                notificationDetail = settings.authorizationStatus == .denied ? "请在系统设置 → 通知 → 时序中允许通知。" : "点击开启提醒，允许通知和声音。"
                return
            }
            notificationStatus = "系统提醒已开启"
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("daymark.task.") || UUID(uuidString: $0.identifier) != nil }.map(\.identifier))
            var scheduled = 0
            var missed = 0
            var errors: [String] = []
            for task in tasks where !task.isComplete && task.reminderMinutes >= 0 {
                guard !Task.isCancelled else { return }
                let fireDate = task.dueAt.addingTimeInterval(-Double(task.reminderMinutes * 60))
                if task.repeatRule == .none && fireDate <= Date() { missed += 1; continue }
                let content = UNMutableNotificationContent()
                content.title = "时序提醒 · \(task.title)"
                content.body = "截止时间：\(fireDateFormatter.string(from: task.dueAt))" + (task.note.isEmpty ? "" : " · \(task.note)")
                content.sound = .default
                let trigger: UNNotificationTrigger
                if task.repeatRule == .none {
                    trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireDate.timeIntervalSinceNow), repeats: false)
                } else {
                    var parts = Calendar.current.dateComponents([.weekday, .day, .month, .hour, .minute], from: fireDate)
                    switch task.repeatRule {
                    case .daily: parts.weekday = nil; parts.day = nil; parts.month = nil
                    case .weekly: parts.day = nil; parts.month = nil
                    case .monthly: parts.weekday = nil; parts.month = nil
                    case .yearly: parts.weekday = nil
                    case .none: break
                    }
                    trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
                }
                let request = UNNotificationRequest(identifier: "daymark.task." + task.id.uuidString, content: content, trigger: trigger)
                do { try await center.add(request); scheduled += 1 }
                catch { errors.append(error.localizedDescription) }
            }
            guard !Task.isCancelled else { return }
            if !errors.isEmpty { notificationStatus = "部分提醒安排失败"; notificationDetail = errors.joined(separator: "；") }
            else { notificationDetail = "已安排 \(scheduled) 条提醒" + (missed > 0 ? "；\(missed) 条的提醒时间已过去" : "") }
        }
    }
}

final class NotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) { UNUserNotificationCenter.current().delegate = self }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

private let fireDateFormatter: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"; return f
}()

@main struct DaymarkApp: App {
    @NSApplicationDelegateAdaptor(NotificationDelegate.self) private var appDelegate
    @StateObject private var store = TaskStore()
    var body: some Scene {
        WindowGroup {
            PlannerView().environmentObject(store).frame(minWidth: 1000, minHeight: 700).preferredColorScheme(.light)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 790)
    }
}

struct PlannerView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var page = "today"
    @State private var filter = ""
    @State private var sorting = "priority"
    @State private var timelineShift = 0
    @State private var editorTask: ReminderTask?
    @State private var isAdding = false
    @State private var clockTick = Date()

    private var active: [ReminderTask] { store.tasks.filter { !$0.isComplete } }
    private var todayTasks: [ReminderTask] {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return active.filter { $0.startAt < end && $0.dueAt >= start }
    }
    private var overdueTasks: [ReminderTask] { active.filter { $0.dueAt < Date() } }
    private var upcomingTasks: [ReminderTask] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return active.filter { $0.startAt >= tomorrow && $0.dueAt >= Date() }
    }
    private var visibleTasks: [ReminderTask] {
        let filtered: [ReminderTask]
        switch filter { case "overdue": filtered = overdueTasks; case "upcoming": filtered = upcomingTasks; case "high": filtered = active.filter { $0.priority <= 2 }; default: filtered = page == "today" ? todayTasks : active }
        return filtered.sorted { sorting == "time" ? $0.dueAt < $1.dueAt : ($0.priority == $1.priority ? $0.dueAt < $1.dueAt : $0.priority < $1.priority) }
    }
    private var timelineStart: Date {
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: timelineShift, to: weekStart) ?? weekStart
    }
    private var timelineDates: [Date] { (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: timelineStart) } }
    private var ganttTasks: [ReminderTask] {
        return active.sorted { $0.priority == $1.priority ? $0.dueAt < $1.dueAt : $0.priority < $1.priority }
    }
    private var nowOffset: CGFloat? {
        let seconds = clockTick.timeIntervalSince(timelineStart)
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: timelineStart) ?? timelineStart.addingTimeInterval(7 * 24 * 60 * 60)
        let weekSeconds = weekEnd.timeIntervalSince(timelineStart)
        guard seconds >= 0 && seconds < weekSeconds else { return nil }
        return CGFloat(seconds / weekSeconds) * 7 * 88
    }
    private func showAfterSave(_ task: ReminderTask, isNew: Bool) {
        if isNew { store.add(task) } else { store.update(task) }
        filter = ""
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayEnd = Calendar.current.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86_400)
        if task.startAt < todayEnd && task.dueAt >= todayStart { page = "today" }
        else {
            page = "timeline"
            if isNew { timelineShift = 0 }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 236)
            Rectangle().fill(Palette.line).frame(width: 1)
            mainContent.padding(.horizontal, 42).padding(.top, 22).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.canvas)
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 30_000_000_000); clockTick = Date() } }
        .sheet(isPresented: $isAdding) { TaskEditor(task: nil) { showAfterSave($0, isNew: true) } }
        .sheet(item: $editorTask) { task in TaskEditor(task: task) { showAfterSave($0, isNew: false) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshNotifications() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack { RoundedRectangle(cornerRadius: 12).fill(Palette.butter).frame(width: 38, height: 38); Image(systemName: "sun.max.fill").font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.coral) }
                VStack(alignment: .leading, spacing: 2) { Text("时序").font(uiFont("时序", 19, bold: true)).foregroundStyle(Palette.ink); Text("DAYMARK").font(comicFont(9, bold: true)).tracking(2).foregroundStyle(Palette.secondary) }
            }.padding(.bottom, 38)
            Text("工作台").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary).padding(.leading, 12).padding(.bottom, 10)
            navButton("今日事项", icon: "circle.grid.2x2", count: todayTasks.count, key: "today")
            navButton("时间轴", icon: "point.topleft.down.to.point.bottomright.curvepath", key: "timeline")
            navButton("全部事项", icon: "list.bullet.rectangle", count: active.count, key: "all")
            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 23).padding(.horizontal, 8)
            Text("快速筛选").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary).padding(.leading, 12).padding(.bottom, 10)
            filterButton("已逾期", icon: "exclamationmark.circle", key: "overdue", count: overdueTasks.count)
            filterButton("即将到期", icon: "clock", key: "upcoming", count: upcomingTasks.count)
            filterButton("高优先级", icon: "flag", key: "high", count: active.filter { $0.priority <= 2 }.count)
            Spacer()
            VStack(alignment: .leading, spacing: 7) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.secondary)
                Text(Date.now.formatted(.dateTime.year())).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("把重要的事，一件一件做好。").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Palette.butter, in: RoundedRectangle(cornerRadius: 14)).padding(.bottom, 14)
            HStack { Text("保存在这台 Mac 上").font(.system(size: 10)).foregroundStyle(Palette.secondary); Spacer(); Button { exportBackup() } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 12)) }.buttonStyle(.plain).help("导出事项备份") }.padding(.horizontal, 7)
        }.padding(.horizontal, 17).padding(.top, 26).padding(.bottom, 19).background(Color(hex: 0xF1F3F5))
    }
    private func navButton(_ title: String, icon: String, count: Int? = nil, key: String) -> some View {
        Button { page = key; filter = "" } label: {
            HStack(spacing: 11) { Image(systemName: icon).frame(width: 17); Text(title); Spacer(); if let count { Text("\(count)").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.secondary) } }
                .font(.system(size: 13, weight: page == key && filter.isEmpty ? .semibold : .regular)).foregroundStyle(page == key && filter.isEmpty ? Palette.forest : Palette.secondary).padding(.horizontal, 12).padding(.vertical, 10).background(page == key && filter.isEmpty ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
    private func filterButton(_ title: String, icon: String, key: String, count: Int) -> some View {
        Button { filter = key; page = "all" } label: {
            HStack(spacing: 11) { Image(systemName: icon).frame(width: 17); Text(title); Spacer(); Text("\(count)").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.secondary) }
                .font(.system(size: 12, weight: filter == key ? .semibold : .regular)).foregroundStyle(filter == key ? Palette.forest : Palette.secondary).padding(.horizontal, 12).padding(.vertical, 9).background(filter == key ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PERSONAL PLANNER  /  \(filter.isEmpty ? page.uppercased() : filter.uppercased())").font(.system(size: 10, weight: .medium, design: .rounded)).tracking(1.2).foregroundStyle(Color(hex: 0x9B9F98))
                Spacer()
                Menu {
                    Text(store.notificationStatus)
                    if !store.notificationDetail.isEmpty { Text(store.notificationDetail) }
                    Divider()
                    if !store.notificationAuthorized { Button("开启提醒") { store.requestNotifications() } }
                    Button("发送测试提醒（5 秒后）") { store.sendTestNotification() }.disabled(!store.notificationAuthorized)
                    Button("刷新提醒状态") { store.refreshNotifications() }
                    Button("打开系统通知设置") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
                } label: {
                    Label(store.notificationStatus, systemImage: store.notificationAuthorized ? "bell.badge.fill" : "bell.slash")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(store.notificationAuthorized ? Palette.forest : Palette.coral)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.white.opacity(0.8), in: Capsule())
                }.menuStyle(.borderlessButton).help(store.notificationDetail)
            }.padding(.bottom, 29)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()).font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.8).foregroundStyle(Palette.coral)
                    Text(headerTitle).font(uiFont(headerTitle, 30, bold: true)).tracking(-0.7).foregroundStyle(Palette.ink)
                    Text(headerSubtitle).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button { isAdding = true } label: { Label("新建事项", systemImage: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 11).background(Palette.forest, in: RoundedRectangle(cornerRadius: 11)) }.buttonStyle(.plain)
            }.padding(.bottom, 23)
            if filter.isEmpty && page == "today" { summaryCards.padding(.bottom, 25) }
            HStack {
                Text(sectionTitle).font(uiFont(sectionTitle, 16, bold: true)).foregroundStyle(Palette.ink)
                Spacer()
                if page == "timeline" && filter.isEmpty {
                    HStack(spacing: 9) {
                        Button { timelineShift -= 7 } label: { Image(systemName: "chevron.left") }
                        Text("\(timelineStart.formatted(.dateTime.month(.abbreviated).day())) — \((Calendar.current.date(byAdding: .day, value: 6, to: timelineStart) ?? timelineStart).formatted(.dateTime.month(.abbreviated).day()))").font(.system(size: 11, weight: .medium, design: .rounded))
                        Button { timelineShift += 7 } label: { Image(systemName: "chevron.right") }
                        Button("本周") { timelineShift = 0 }.font(.system(size: 10, weight: .semibold, design: .rounded))
                    }.buttonStyle(.plain).foregroundStyle(Palette.forest)
                } else { Picker("排序", selection: $sorting) { Text("优先级").tag("priority"); Text("截止时间").tag("time") }.pickerStyle(.segmented).frame(width: 170) }
            }.padding(.bottom, 12)
            if page == "timeline" && filter.isEmpty { ganttChart }
            else { ScrollView { contentList.padding(.bottom, 25) } }
        }
    }
    private var headerTitle: String { if !filter.isEmpty { return filter == "overdue" ? "已逾期" : filter == "upcoming" ? "即将到期" : "高优先级" }; return page == "timeline" ? "沿着时间，安排好每一步" : page == "all" ? "所有事项，都在这里" : "今天，慢慢来" }
    private var headerSubtitle: String { page == "timeline" ? "从今天开始，看看接下来的安排。" : page == "all" ? "一份清晰的清单，让每件事都有着落。" : "把注意力放在此刻最重要的事情上。" }
    private var sectionTitle: String { !filter.isEmpty ? (filter == "overdue" ? "已逾期事项" : filter == "upcoming" ? "接下来要做" : "优先处理") : page == "timeline" ? "时间轴" : page == "all" ? "全部事项" : "今日安排" }
    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard("今日待办", value: todayTasks.count, note: "TODAY", featured: true)
            summaryCard("已逾期", value: overdueTasks.count, note: "OVERDUE")
            summaryCard("接下来", value: upcomingTasks.count, note: "UPCOMING")
        }
    }
    private func summaryCard(_ title: String, value: Int, note: String, featured: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(title).font(.system(size: 11, weight: .medium)).opacity(featured ? 0.8 : 0.7); Spacer(); Text(note).font(.system(size: 8, weight: .medium, design: .rounded)).tracking(1).opacity(0.55) }
            Text("\(value)").font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
        }.foregroundStyle(Palette.ink).padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading).background(featured ? Color(hex: 0xECEFF1) : title == "已逾期" ? Color(hex: 0xF6F1F0) : title == "接下来" ? Color(hex: 0xF1F3F5) : Color(hex: 0xF1F1F4), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line, lineWidth: 1))
    }
    @ViewBuilder private var contentList: some View {
        if page == "today" && filter.isEmpty && visibleTasks.isEmpty && !upcomingTasks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 25)).foregroundStyle(Palette.gold)
                Text("后续事项已安排").font(uiFont("后续事项已安排", 15, bold: true)).foregroundStyle(Palette.ink)
                Text("接下来有 \(upcomingTasks.count) 件事项，打开时间轴查看排期。 ").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Button("查看甘特时间轴") { page = "timeline" }.font(uiFont("查看甘特时间轴", 12, bold: true)).buttonStyle(.borderedProminent).tint(Palette.forest).padding(.top, 3)
            }.frame(maxWidth: .infinity).padding(.vertical, 38).background(.white, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line, lineWidth: 1))
        } else if visibleTasks.isEmpty {
            VStack(spacing: 9) { Image(systemName: "checkmark.circle").font(.system(size: 27, weight: .light)).foregroundStyle(Palette.forest.opacity(0.7)); Text(page == "today" && filter.isEmpty ? "今天暂时没有待办" : "这里还没有事项").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink); Text("点击「新建事项」，把第一件事记下来。 ").font(.system(size: 12)).foregroundStyle(Palette.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 42).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
        } else if page == "timeline" && filter.isEmpty {
            LazyVStack(alignment: .leading, spacing: 19) {
                ForEach(Dictionary(grouping: visibleTasks.sorted { $0.dueAt < $1.dueAt }) { Calendar.current.startOfDay(for: $0.dueAt) }.keys.sorted(), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) { Circle().fill(Palette.coral).frame(width: 7, height: 7); Text(dayHeading(day)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink); Text(day.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.secondary) }
                        ForEach((Dictionary(grouping: visibleTasks.sorted { $0.dueAt < $1.dueAt }) { Calendar.current.startOfDay(for: $0.dueAt) }[day] ?? [])) { task in TaskRow(task: task, complete: { store.toggle(task) }, edit: { editorTask = task }, delete: { store.remove(task) }) }
                    }.padding(.leading, 5).overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1).padding(.leading, 3).offset(x: -5).padding(.top, 18) }
                }
            }
        } else {
            LazyVStack(spacing: 8) { ForEach(visibleTasks) { task in TaskRow(task: task, complete: { store.toggle(task) }, edit: { editorTask = task }, delete: { store.remove(task) }) } }
        }
    }
    private func dayHeading(_ day: Date) -> String { if Calendar.current.isDateInToday(day) { return "今天" }; if Calendar.current.isDateInTomorrow(day) { return "明天" }; return day.formatted(.dateTime.weekday(.wide)) }
    private let timelineDayWidth: CGFloat = 240
    private let timelineLabelWidth: CGFloat = 248
    private let timelineHeaderHeight: CGFloat = 74
    private let timelineRowHeight: CGFloat = 64

    // Each civil day has equal width; positions within a day follow local clock time.
    private func timelineX(_ date: Date) -> CGFloat {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: timelineStart, to: day).day ?? 0
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let length = max(1, next.timeIntervalSince(day))
        let fraction = date.timeIntervalSince(day) / length
        return (CGFloat(offset) + CGFloat(fraction)) * timelineDayWidth
    }

    private var ganttChart: some View {
        let tasks = ganttTasks
        let gridWidth = timelineDayWidth * 7
        let height = timelineHeaderHeight + CGFloat(max(tasks.count, 1)) * timelineRowHeight
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Palette.nowBlue).frame(width: 7, height: 7)
                Text("蓝线表示当前时间")
                Text("·").foregroundStyle(Palette.line)
                Text("左右滑动查看一天中的时间")
                Spacer()
                Text("每格 6 小时").foregroundStyle(Palette.secondary)
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.horizontal, 2)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("事项").font(uiFont("事项", 12, bold: true)).foregroundStyle(Palette.ink)
                            Spacer()
                            Text("剩余时间").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        }.padding(.horizontal, 14).frame(width: timelineLabelWidth, height: timelineHeaderHeight)
                            .background(Color(hex: 0xF6F7F9))
                        if tasks.isEmpty {
                            Text("暂无事项").font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(width: timelineLabelWidth, height: timelineRowHeight)
                        } else {
                            ForEach(tasks) { task in ganttLabel(task) }
                        }
                    }.frame(width: timelineLabelWidth).background(.white)
                        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    ganttDateHeader
                                    if tasks.isEmpty {
                                        timelineGridRow.frame(height: timelineRowHeight)
                                    } else {
                                        ForEach(tasks) { task in ganttBar(task) }
                                    }
                                }
                                let nowX = timelineX(clockTick)
                                if nowX >= 0 && nowX < gridWidth {
                                    Rectangle().fill(Palette.nowBlue).frame(width: 2, height: max(0, height - 31)).offset(x: nowX, y: 31)
                                        .allowsHitTesting(false)
                                    Text("现在 \(clockTick.formatted(.dateTime.hour().minute()))")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 3).background(Palette.nowBlue, in: Capsule())
                                        .fixedSize().offset(x: max(0, min(gridWidth - 68, nowX - 30)), y: 24).allowsHitTesting(false)
                                }
                            }.frame(width: gridWidth, height: height, alignment: .topLeading)
                        }
                        .onAppear { scrollToRelevantDay(proxy) }
                        .onChange(of: timelineShift) { _ in scrollToRelevantDay(proxy) }
                    }
                }.frame(height: height, alignment: .top)
            }.background(.white, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
        }.padding(.bottom, 18)
    }

    private func scrollToRelevantDay(_ proxy: ScrollViewProxy) {
        let today = Calendar.current.startOfDay(for: clockTick)
        let days = Calendar.current.dateComponents([.day], from: timelineStart, to: today).day ?? 0
        let index = (0..<7).contains(days) ? days : 0
        DispatchQueue.main.async { proxy.scrollTo(index, anchor: .leading) }
    }

    private var ganttDateHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(timelineDates.enumerated()), id: \.offset) { index, day in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Text(day.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        if Calendar.current.isDateInToday(day) {
                            Text("今天").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.nowBlue)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(["00:00", "06:00", "12:00", "18:00"], id: \.self) { time in
                            Text(time).font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Palette.secondary).frame(width: timelineDayWidth / 4, alignment: .leading)
                        }
                    }
                }.padding(.leading, 10).frame(width: timelineDayWidth, height: timelineHeaderHeight, alignment: .leading)
                    .background(Calendar.current.isDateInToday(day) ? Color(hex: 0xF2F7FD) : Color(hex: 0xF6F7F9))
                    .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
                    .id(index)
            }
        }.frame(height: timelineHeaderHeight)
    }

    private func ganttLabel(_ task: ReminderTask) -> some View {
        HStack(spacing: 10) {
            Button { store.toggle(task) } label: {
                Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(priorityTint(task.priority))
            }.buttonStyle(.plain).help("完成事项")
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(uiFont(task.title, 13, bold: true)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(task.dueAt < clockTick ? "已逾期" : "剩余 \(remainingLabel(task.dueAt))")
                    .font(.system(size: 10)).foregroundStyle(task.dueAt < clockTick ? Palette.coral : Palette.secondary)
            }
            Spacer(minLength: 2)
            Menu {
                Button("编辑事项", systemImage: "pencil") { editorTask = task }
                Button("删除事项", systemImage: "trash", role: .destructive) { store.remove(task) }
            } label: { Image(systemName: "ellipsis").foregroundStyle(Palette.secondary).frame(width: 20) }.menuStyle(.borderlessButton)
        }.padding(.horizontal, 13).frame(width: timelineLabelWidth, height: timelineRowHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var timelineGridRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(timelineDates.enumerated()), id: \.offset) { index, day in
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { part in
                        Color.clear.frame(width: timelineDayWidth / 4)
                            .overlay(alignment: .leading) { Rectangle().fill(part == 0 ? Palette.line : Palette.line.opacity(0.45)).frame(width: 1) }
                    }
                }.background(Calendar.current.isDateInToday(day) ? Color(hex: 0xFAFCFF) : (index.isMultiple(of: 2) ? .white : Color(hex: 0xFAFBFC)))
            }
        }.overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func ganttBar(_ task: ReminderTask) -> some View {
        let width = timelineDayWidth * 7
        let rawStart = timelineX(task.startAt)
        let rawEnd = timelineX(task.dueAt)
        let start = min(width, max(0, rawStart))
        let end = min(width, max(0, rawEnd))
        let isVisible = rawEnd >= 0 && rawStart < width
        let barWidth = max(3, end - start)
        let elapsed = min(barWidth, max(0, timelineX(clockTick) - start))
        return ZStack(alignment: .leading) {
            timelineGridRow
            if isVisible {
                HStack(spacing: 0) {
                    if elapsed > 0 { Rectangle().fill(priorityTint(task.priority).opacity(0.3)).frame(width: elapsed) }
                    if elapsed < barWidth { Rectangle().fill(priorityTint(task.priority)).frame(width: barWidth - elapsed) }
                }.frame(width: barWidth, height: 8).clipShape(Capsule()).offset(x: start)
                    .help("\(task.title)：\(fireDateFormatter.string(from: task.startAt)) — \(fireDateFormatter.string(from: task.dueAt))")
            }
        }.frame(width: width, height: timelineRowHeight)
    }
    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "时序事项备份.json"; panel.allowedContentTypes = [.json]
        panel.begin { response in if response == .OK, let url = panel.url, let data = try? JSONEncoder().encode(store.tasks) { try? data.write(to: url, options: .atomic) } }
    }
}

struct TaskRow: View {
    let task: ReminderTask
    let complete: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    private var isOverdue: Bool { task.dueAt < Date() }
    var body: some View {
        HStack(spacing: 13) {
            Button(action: complete) { Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle").font(.system(size: 19, weight: .regular)).foregroundStyle(task.isComplete ? Palette.forest : Color(hex: 0xC7CCC5)) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title).font(uiFont(task.title, 15, bold: true)).foregroundStyle(task.isComplete ? Palette.secondary : Palette.ink).strikethrough(task.isComplete)
                HStack(spacing: 9) {
                    Label("\(task.startAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))–\(task.dueAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))", systemImage: "clock").foregroundStyle(isOverdue ? Palette.coral : Palette.secondary)
                    Text(isOverdue ? "已逾期" : "还剩 \(remainingLabel(task.dueAt))").foregroundStyle(isOverdue ? Palette.coral : Palette.forest)
                    if task.repeatRule != .none { Label(task.repeatRule.rawValue, systemImage: "arrow.2.circlepath").foregroundStyle(Color(hex: 0x8582A7)) }
                    if !task.note.isEmpty { Text("· \(task.note)").lineLimit(1).foregroundStyle(Palette.secondary) }
                }.font(.system(size: 10, weight: .regular))
            }
            Spacer(minLength: 12)
            Text(priorityName(task.priority)).font(.system(size: 9, weight: .semibold)).foregroundStyle(priorityColor(task.priority)).padding(.horizontal, 8).padding(.vertical, 5).background(priorityColor(task.priority).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            Menu { Button("编辑事项", systemImage: "pencil", action: edit); Button("删除事项", systemImage: "trash", role: .destructive, action: delete) } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.secondary).frame(width: 24, height: 26).contentShape(Rectangle()) }.menuStyle(.borderlessButton)
        }.padding(.horizontal, 14).padding(.vertical, 13).background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line, lineWidth: 1)).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(priorityColor(task.priority)).frame(width: 3).padding(.vertical, 12) }
    }
    private func priorityName(_ p: Int) -> String { [1:"P1 · 紧急",2:"P2 · 重要",3:"P3 · 普通",4:"P4 · 稍后"][p] ?? "P3 · 普通" }
    private func priorityColor(_ p: Int) -> Color { [1:Palette.coral,2:Palette.gold,3:Palette.forest,4:Palette.lilac][p] ?? Palette.secondary }
}

struct TaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    let task: ReminderTask?
    let saveTask: (ReminderTask) -> Void
    @State private var title: String
    @State private var startAt: Date
    @State private var dueAt: Date
    @State private var priority: Int
    @State private var repeatRule: RepeatRule
    @State private var reminder: Int
    @State private var note: String
    @State private var showStartCalendar = false
    @State private var showEndCalendar = false

    init(task: ReminderTask?, save: @escaping (ReminderTask) -> Void) {
        self.task = task; self.saveTask = save
        _title = State(initialValue: task?.title ?? "")
        let defaultStart = Calendar.current.dateInterval(of: .minute, for: Date())?.start ?? Date()
        _startAt = State(initialValue: task?.startAt ?? defaultStart)
        _dueAt = State(initialValue: task?.dueAt ?? defaultStart.addingTimeInterval(3600))
        _priority = State(initialValue: task?.priority ?? 2)
        _repeatRule = State(initialValue: task?.repeatRule ?? .none)
        _reminder = State(initialValue: task?.reminderMinutes ?? 30)
        _note = State(initialValue: task?.note ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(task == nil ? "新建事项" : "编辑事项").font(uiFont("新建事项", 21, bold: true)); Text("为重要的事留出时间。 ").font(.system(size: 12)).foregroundStyle(Palette.secondary) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(Palette.secondary) }.buttonStyle(.plain) }
            VStack(alignment: .leading, spacing: 7) { fieldLabel("事项名称"); TextField("例如：项目讨论会议", text: $title).textFieldStyle(.roundedBorder).font(.system(size: 14)) }
            timeSection
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 7) { fieldLabel("优先级"); Picker("优先级", selection: $priority) { Text("P1 · 最重要").tag(1); Text("P2 · 重要").tag(2); Text("P3 · 普通").tag(3); Text("P4 · 有空再做").tag(4) }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading) }
                VStack(alignment: .leading, spacing: 7) { fieldLabel("重复周期"); Picker("重复周期", selection: $repeatRule) { ForEach(RepeatRule.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 7) { fieldLabel("结束前提醒"); Picker("结束前提醒", selection: $reminder) { Text("不提醒").tag(-1); Text("结束时").tag(0); Text("提前 5 分钟").tag(5); Text("提前 30 分钟").tag(30); Text("提前 1 天").tag(1440) }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading) }
                VStack(alignment: .leading, spacing: 7) { fieldLabel("备注"); TextField("可选", text: $note).textFieldStyle(.roundedBorder) }
            }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button(task == nil ? "保存事项" : "保存修改") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Palette.forest).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dueAt <= startAt) }
        }.padding(26).frame(width: 560).background(Palette.canvas)
    }
    private var startBinding: Binding<Date> {
        Binding(get: { startAt }, set: { value in
            let duration = max(60, dueAt.timeIntervalSince(startAt))
            startAt = value
            dueAt = value.addingTimeInterval(duration)
        })
    }
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("时间安排", systemImage: "calendar.badge.clock").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Button("开始设为现在") { startBinding.wrappedValue = Calendar.current.dateInterval(of: .minute, for: Date())?.start ?? Date() }
                    .font(.system(size: 10, weight: .medium)).buttonStyle(.plain).foregroundStyle(Palette.forest).keyboardShortcut("0", modifiers: .command)
                Text(dueAt > startAt ? durationText : "结束时间须晚于开始时间")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(dueAt > startAt ? Palette.forest : Palette.coral)
            }
            HStack(spacing: 10) {
                timeCard("开始", selection: startBinding, showCalendar: $showStartCalendar)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                timeCard("结束 / 截止", selection: $dueAt, showCalendar: $showEndCalendar)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("快捷时长").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary); Spacer(); Text("从开始时间计算").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                HStack(spacing: 7) {
                    durationButton("30 分钟", minutes: 30, key: "1")
                    durationButton("1 小时", minutes: 60, key: "2")
                    durationButton("2 小时", minutes: 120, key: "3")
                    durationButton("4 小时", minutes: 240, key: "4")
                    durationButton("1 天", minutes: 1440, key: "5")
                }
                Text("⌘0 现在开始 · ⌘1–⌘5 设置时长 · 修改开始时间会保留当前时长")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            if dueAt <= startAt {
                Label("请将结束时间设在开始时间之后，或选择快捷时长。", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.coral)
            }
        }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
    private func timeCard(_ label: String, selection: Binding<Date>, showCalendar: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
            Button { showCalendar.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(Palette.forest)
                    Text(selection.wrappedValue.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                }.foregroundStyle(Palette.ink).contentShape(Rectangle())
            }.buttonStyle(.plain).popover(isPresented: showCalendar, arrowEdge: .bottom) {
                VStack(alignment: .trailing, spacing: 6) {
                    DatePicker(label, selection: selection, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                    Button("完成") { showCalendar.wrappedValue = false }.buttonStyle(.borderedProminent).tint(Palette.forest)
                }.padding(12).frame(width: 280)
            }
            HStack(spacing: 5) {
                Image(systemName: "clock").foregroundStyle(Palette.secondary)
                DatePicker(label + "时间", selection: selection, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field)
                    .font(.system(size: 13, weight: .medium, design: .rounded)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0xF6F8F9), in: RoundedRectangle(cornerRadius: 10))
    }
    private func durationButton(_ label: String, minutes: Int, key: KeyEquivalent) -> some View {
        let selected = abs(dueAt.timeIntervalSince(startAt) - Double(minutes * 60)) < 1
        return Button { dueAt = startAt.addingTimeInterval(Double(minutes * 60)) } label: {
            Text(label).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.forest : Palette.ink).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? Palette.forestLight : Color(hex: 0xF3F5F6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Palette.forest.opacity(0.45) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).keyboardShortcut(key, modifiers: .command).help("设置从开始时间起的时长：\(label)")
    }
    private var durationText: String {
        let minutes = Int(dueAt.timeIntervalSince(startAt) / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
        let parts = [days > 0 ? "\(days) 天" : "", hours > 0 ? "\(hours) 小时" : "", rest > 0 ? "\(rest) 分钟" : ""].filter { !$0.isEmpty }
        return "时长 " + (parts.isEmpty ? "不足 1 分钟" : parts.joined(separator: " "))
    }
    private func fieldLabel(_ value: String) -> some View { Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary) }
    private func save() { guard dueAt > startAt, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; let item = ReminderTask(id: task?.id ?? UUID(), title: title.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: task?.createdAt ?? Date(), startAt: startAt, dueAt: dueAt, priority: priority, repeatRule: repeatRule, reminderMinutes: reminder, note: note.trimmingCharacters(in: .whitespacesAndNewlines), isComplete: task?.isComplete ?? false); saveTask(item); dismiss() }
}

private func nextOccurrence(after date: Date, rule: RepeatRule) -> Date {
    let calendar = Calendar.current
    let component: Calendar.Component = rule == .daily ? .day : rule == .weekly ? .weekOfYear : rule == .monthly ? .month : .year
    var next = calendar.date(byAdding: component, value: 1, to: date) ?? date.addingTimeInterval(86400)
    while next <= Date() { next = calendar.date(byAdding: component, value: 1, to: next) ?? next.addingTimeInterval(86400) }
    return next
}
private extension Color {
    init(hex: UInt) { self.init(.sRGB, red: Double((hex >> 16) & 0xFF)/255, green: Double((hex >> 8) & 0xFF)/255, blue: Double(hex & 0xFF)/255, opacity: 1) }
}
private func comicFont(_ size: CGFloat, bold: Bool = false) -> Font {
    let name = bold ? "ComicSansMS-Bold" : "ComicSansMS"
    if let font = NSFont(name: name, size: size) { return Font(font) }
    return .system(size: size, weight: bold ? .bold : .regular, design: .rounded)
}
private func uiFont(_ text: String, _ size: CGFloat, bold: Bool = false) -> Font {
    let hasHan = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
    guard hasHan else { return comicFont(size, bold: bold) }
    let name = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
    if let font = NSFont(name: name, size: size) { return Font(font) }
    return .system(size: size, weight: bold ? .semibold : .regular, design: .default)
}
private func priorityTint(_ priority: Int) -> Color {
    switch priority { case 1: Palette.coral; case 2: Palette.gold; case 3: Palette.forest; default: Palette.lilac }
}
private func remainingLabel(_ deadline: Date) -> String {
    let seconds = Int(deadline.timeIntervalSinceNow)
    guard seconds > 0 else { return "已逾期" }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return hours > 0 ? "\(days)天\(hours)小时" : "\(days)天" }
    if hours > 0 { return "\(hours)小时\(minutes)分" }
    return "\(max(1, minutes))分钟"
}
