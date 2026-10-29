import AppKit
import SwiftUI

private extension NotchTint {
    var color: Color {
        switch self {
        case .white: .white
        case .green: Color(nsColor: .systemGreen)
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .yellow: Color(nsColor: .systemYellow)
        case .blue: Color(nsColor: .systemBlue)
        case .teal: Color(nsColor: .systemTeal)
        case .purple: Color(nsColor: .systemPurple)
        case .pink: Color(nsColor: .systemPink)
        }
    }
}

/// Draws only known SF Symbols, falling back quietly for a syntactically valid but unavailable name.
private struct NotchNoticeSymbol: View {
    let notice: NotchNotice
    private var name: String {
        guard let name = notice.symbol, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            return "bell.fill"
        }
        return name
    }
    var body: some View {
        Image(systemName: name).foregroundStyle(notice.tint.color).accessibilityHidden(true)
    }
}

/// A fixed two-point progress line, with no native control animation or minimum control height.
private struct NotchNoticeProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(.white.opacity(0.15))
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white).frame(width: geometry.size.width * value)
                }
        }
        .frame(height: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// A temporary notice below the camera. Clicking its text opens history; dismissing it leaves history intact.
struct NotchNoticePeekView: View {
    let entry: NotchNotices.Entry
    @ObservedObject var experience: NotchExperience
    let topHeight: CGFloat
    let wing: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if experience.notices.waitingCount > 0 {
                    Text("+\(experience.notices.waitingCount)").font(.system(size: 10, weight: .medium))
                        .frame(width: wing)
                }
            }
            .frame(height: topHeight)
            HStack(spacing: 10) {
                Button { experience.openNotifications() } label: {
                    HStack(spacing: 10) {
                        NotchNoticeSymbol(notice: entry.notice).font(.system(size: 18)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.notice.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if let detail = entry.notice.detail {
                                Text(detail).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                            if let progress = entry.notice.progress {
                                NotchNoticeProgress(value: progress)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle())
                .accessibilityHint("Open notifications")
                Button { experience.dismissNoticeAlert() } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 18, height: 28)
                }
                .buttonStyle(NotchPressStyle())
                .accessibilityLabel("Dismiss alert")
            }
            .padding(.horizontal, 16)
            .frame(height: NotchGeometry.eventPeekDrop - 6)
            Spacer(minLength: 0)
        }
    }
}

/// A bounded, in-memory list. Timestamps stay fixed so an idle page does not schedule redraws.
struct NotchNotificationsPage: View {
    @ObservedObject var experience: NotchExperience
    let topHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topHeight)
            HStack {
                Text("Notifications").font(.system(size: 11, weight: .semibold))
                if !experience.notices.history.isEmpty {
                    Text("\(experience.notices.history.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { experience.clearNotices() }
                        .font(.system(size: 10)).buttonStyle(NotchPressStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 8)
            if experience.notices.history.isEmpty {
                VStack(spacing: 6) {
                    Text("No notifications").font(.system(size: 12))
                    Text("New notices appear here").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        ForEach(experience.notices.history) { entry in
                            HStack(spacing: 8) {
                                NotchNoticeSymbol(notice: entry.notice).font(.system(size: 16)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.notice.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    if let detail = entry.notice.detail {
                                        Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                                    }
                                    if let progress = entry.notice.progress {
                                        NotchNoticeProgress(value: progress)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.received.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                                Button { experience.removeNotice(entry.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 28)
                                }
                                .buttonStyle(NotchPressStyle())
                                .accessibilityLabel("Remove \(entry.notice.title)")
                            }
                            .frame(minHeight: 32)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
                .scrollIndicators(.never)
            }
        }
    }
}
