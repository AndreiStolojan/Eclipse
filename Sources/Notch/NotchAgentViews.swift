import SwiftUI

// The T3 Code views: the alert under the closed notch (2.5 s, size and duration in the settings), the list page (30 pt rows, no
// scroller) and a thread's page (sized from the settings) with T3's questions and approvals.

extension NotchAgentPhase {
    var color: Color {
        switch self {
        case .done: Color(nsColor: .systemGreen)
        case .input, .approval: Color(nsColor: .systemOrange)
        case .plan, .running: Color(nsColor: .systemBlue)
        case .failed: Color(nsColor: .systemRed)
        case .limited, .woke: Color(nsColor: .systemYellow)
        case .stopped, .idle: .white.opacity(0.7)
        }
    }
}

/// T3 Code's own icon, or a terminal symbol while it is not installed.
struct NotchT3Icon: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let icon = NotchT3.icon {
                Image(nsImage: icon).resizable().scaledToFit().scaleEffect(1.2)
            } else {
                Image(systemName: "terminal.fill").font(.system(size: size * 0.7))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The alert: T3's icon in the left wing, the state word in the right one, and under the camera the thread's title
/// over its project, branch and run time. A click opens the thread's page; so does hovering, like any closed notch.
struct NotchAgentPeekView: View {
    let alert: NotchAgentAlert
    @ObservedObject var experience: NotchExperience
    let topHeight: CGFloat
    let wing: CGFloat
    /// The alert size setting; the type grows with the outline.
    let scale: CGFloat

    var body: some View {
        let thread = alert.thread
        Button { experience.openAgent(thread.id) } label: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    NotchT3Icon(size: 16 * min(scale, 1.2)).frame(width: wing)
                    Spacer(minLength: 0)
                    Text(alert.word).font(.system(size: 11 * scale, weight: .semibold)).foregroundStyle(thread.phase.color)
                        .lineLimit(1).fixedSize().frame(width: wing)
                }
                .frame(height: topHeight)
                VStack(spacing: 2 * scale) {
                    Text(thread.title).font(.system(size: 12 * scale, weight: .semibold)).lineLimit(1)
                    Text(subtitle(thread)).font(.system(size: 9.5 * scale)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(height: (NotchGeometry.agentPeekDrop - 6) * scale)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchRowPressStyle())
        .accessibilityLabel("\(thread.title), \(thread.phase.word)")
        .help("Show in the notch")
    }

    private func subtitle(_ thread: NotchAgentThread) -> String {
        ([thread.place] + [thread.runTime(at: .now).map(notchAgentDuration)].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The T3 Code page: threads that need you, then running, then the rest of the day, 30 pt rows under the camera row.
/// It scrolls without a scroller; the row cut at the bottom shows there is more.
struct NotchAgentListPage: View {
    @ObservedObject var t3: NotchT3
    @ObservedObject var experience: NotchExperience
    let topHeight: CGFloat
    let wing: CGFloat
    /// The page is on screen rather than waiting beside it on the strip.
    var visible = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NotchT3Icon(size: 14).frame(width: wing)
                Spacer()
            }
            .frame(height: topHeight)
            if t3.threads.isEmpty {
                Text(t3.status == .connected ? "No threads today" : t3.status.label)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(t3.threads) { thread in
                            Button { experience.openAgent(thread.id) } label: {
                                NotchAgentRow(thread: thread, phase: thread.shownPhase(at: t3.listedAt),
                                              live: visible)
                            }
                                .buttonStyle(NotchPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// One thread: its state, title and place, then the state word when it needs you, or its time.
private struct NotchAgentRow: View {
    let thread: NotchAgentThread
    /// The run state, or Woke.
    let phase: NotchAgentPhase
    /// The page is on screen, so a running thread's time ticks every second.
    let live: Bool

    var body: some View {
        HStack(spacing: 8) {
            NotchAgentGlyph(phase: phase)
            VStack(alignment: .leading, spacing: 0) {
                Text(thread.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(thread.place).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        if phase.needsYou || [.failed, .limited, .woke].contains(phase) {
            Text(phase.word).font(.system(size: 11, weight: .semibold)).foregroundStyle(phase.color)
        } else if phase == .running {
            // One small text redraws once a second while the page shows; paged away it stands still until it returns.
            TimelineView(NotchTicks(start: .now, interval: live ? 1 : nil)) { context in
                Text(thread.runTime(at: context.date).map(notchAgentDuration) ?? "")
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
        } else {
            Text((thread.runCompleted ?? thread.updated).formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// A filled dot for a settled state, a ring while running.
private struct NotchAgentGlyph: View {
    let phase: NotchAgentPhase
    var body: some View {
        Group {
            if phase == .running {
                Circle().strokeBorder(phase.color, lineWidth: 1.5)
            } else {
                Circle().fill(phase.color)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(phase.word)
    }
}

/// One thread's page: title and state, where and how long it runs, the question or approval it waits for, what it
/// does now, its subagents, the agent's last message, the files it changed and its PR, then Stop and Open in T3.
struct NotchAgentThreadPage: View {
    @ObservedObject var t3: NotchT3
    @ObservedObject var experience: NotchExperience
    let threadID: String
    let topHeight: CGFloat
    let wing: CGFloat
    /// Snooze shows T3's choices in place of the buttons.
    @State private var snoozing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: experience.closeAgent) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: topHeight).contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle()).accessibilityLabel("Back to threads").help("Back")
                NotchT3Icon(size: 14)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(width: wing + 10, height: topHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let thread = t3.threads.first(where: { $0.id == threadID }) {
                ScrollView(.vertical) {
                    content(thread, detail: t3.details[threadID])
                        .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 14)
                }
                .scrollIndicators(.never)
            } else {
                Text("This thread is no longer listed").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(_ thread: NotchAgentThread, detail: NotchAgentDetail?) -> some View {
        let phase = thread.shownPhase(at: t3.listedAt)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thread.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Text(phase.word).font(.system(size: 11, weight: .semibold)).foregroundStyle(phase.color)
            }
            // The run time ticks every second while the thread runs; a finished run's time no longer changes.
            TimelineView(.periodic(from: .now, by: thread.phase == .running ? 1 : 3600)) { context in
                Text(meta(thread, now: context.date)).font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .padding(.top, 3)
            if let request = detail?.request, request.id == thread.requestID {
                // A new request starts with no picks.
                NotchAgentRequestView(request: request, threadID: thread.id, t3: t3).id(request.id).padding(.top, 10)
            }
            // Only what the agent says: its latest reply while it works, its last one once it is done. The whole
            // reply shows; the page scrolls.
            if let detail {
                let blocks = thread.phase == .running || detail.message != nil ? detail.messageBlocks : detail.lastMessageBlocks
                if !blocks.isEmpty { NotchMarkdownView(blocks: blocks).padding(.top, 10) }
                if !detail.imageFiles.isEmpty { NotchAgentImageStrip(files: detail.imageFiles).padding(.top, 8) }
            }
            if snoozing {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    ForEach(NotchSnoozeChoice.choices(at: .now), id: \.label) { choice in
                        pill(choice.label) { snooze(thread.id, until: choice.until) }
                    }
                    Button { snoozing = false } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20).background(.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(NotchPressStyle()).accessibilityLabel("Cancel snooze")
                }
                .padding(.top, 10)
            } else {
                buttons(thread, detail: detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A snoozed thread leaves the list, so the page goes back to it.
    private func snooze(_ id: String, until: Date) {
        snoozing = false
        Task {
            if await t3.dispatch(.snooze(threadID: id, until: until), for: id) { experience.closeAgent() }
        }
    }

    private func buttons(_ thread: NotchAgentThread, detail: NotchAgentDetail?) -> some View {
            HStack(spacing: 6) {
                if let files = detail?.files, files > 0 {
                    Text(files == 1 ? "1 file" : "\(files) files").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                if thread.canSnooze { pill("Snooze") { snoozing = true } }
                if thread.phase == .running, let run = thread.runID {
                    pill("Stop") { Task { await t3.dispatch(.interrupt(threadID: thread.id, runID: run), for: thread.id) } }
                }
                if let pullRequest = thread.pullRequest {
                    pill("PR #\(pullRequest.number)") { NSWorkspace.shared.open(pullRequest.url) }
                }
                pill("Open in T3", action: t3.openApp)
            }
            .padding(.top, 10)
    }

    /// "Eclipse · feat/50-t3-code · claude-opus-5-5 · 6m 12s"
    private func meta(_ thread: NotchAgentThread, now: Date) -> String {
        ([thread.place, thread.model, thread.runTime(at: now).map(notchAgentDuration) ?? ""])
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).frame(height: 20)
                .background(.white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(NotchPressStyle())
    }
}

/// The thread's images under the reply, newest first, the agent's and the user's: four 64 × 44 thumbnails and a count
/// for the rest. A click opens them all in Quick Look at that image.
private struct NotchAgentImageStrip: View {
    /// Found on disk by the client when it read the thread.
    let files: [NotchAgentImageFile]
    private static let shown = 4

    var body: some View {
        let urls = files.map(\.url)
        HStack(spacing: 6) {
            ForEach(Array(files.prefix(Self.shown).enumerated()), id: \.offset) { index, file in
                Button { NotchQuickLook.shared.show(urls, at: index) } label: { NotchAgentThumbnail(url: file.url) }
                    .buttonStyle(NotchPressStyle())
                    .help(file.name)
                    .accessibilityLabel(file.name)
            }
            if files.count > Self.shown {
                Button { NotchQuickLook.shared.show(urls, at: Self.shown) } label: {
                    Text("+\(files.count - Self.shown)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7)).frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle())
                .accessibilityLabel("\(files.count - Self.shown) more images")
            }
        }
    }
}

private struct NotchAgentThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    init(url: URL) {
        self.url = url
        _image = State(initialValue: NotchThumbnails.cached(url))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08))
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: 64, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // A hairline keeps a dark screenshot from melting into the black notch.
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .task(id: url) { image = await NotchThumbnails.load(url) }
    }
}

/// An agent's reply drawn like T3 Code draws it: headings, paragraphs, list items, tables in aligned columns and code,
/// with bold, inline code and links inside them.
private struct NotchMarkdownView: View {
    /// Parsed with the thread's snapshot, off the main thread.
    let blocks: [NotchMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(block) }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.white.opacity(0.85))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ block: NotchMarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            inline(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).padding(.top, 2)
        case .paragraph(let text):
            inline(text).fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marker).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                inline(text).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.system(size: 10, weight: index == 0 ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .code(let text):
            Text(text).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Bold, italics, inline code and links; anything else stays as written.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// A pending question or approval, answered from the notch with T3's own choices. A single question that takes one
/// answer sends on the click; several questions or a multiple choice collect the picks, then Send. Typed answers
/// need a key window, which the notch never takes, so Answer in T3 brings T3 forward for them.
private struct NotchAgentRequestView: View {
    let request: NotchAgentRequest
    let threadID: String
    @ObservedObject var t3: NotchT3
    @State private var picks: [String: [String]] = [:]

    var body: some View {
        let busy = t3.sending.contains(threadID)
        VStack(alignment: .leading, spacing: 4) {
            switch request {
            case .questions(let id, let questions):
                ForEach(questions, id: \.id) { question in
                    questionView(question, single: questions.count == 1 && question.multiSelect != true, requestID: id)
                }
                optionRow(number: nil, label: "Answer in T3", detail: nil, selected: false, action: t3.openApp)
                if questions.count > 1 || questions.contains(where: { $0.multiSelect == true }) {
                    let complete = questions.allSatisfy { !(picks[$0.id] ?? []).isEmpty }
                    HStack {
                        Spacer()
                        decision("Send", prominent: true) { send(id, questions) }.disabled(!complete)
                    }
                    .padding(.top, 4)
                }
            case .approval(let id, let kind, let prompt, let decisions):
                Text(NotchAgentRequest.summary(kind: kind)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                if let prompt, !prompt.isEmpty {
                    Text(prompt).font(.system(size: 10, design: .monospaced)).lineLimit(6)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(Array(decisions.enumerated()), id: \.offset) { index, choice in
                        decision(choice.label, prominent: index == decisions.count - 1 && choice.decision.hasPrefix("accept")) {
                            Task { await t3.dispatch(.decide(threadID: threadID, requestID: id, decision: choice.decision), for: threadID) }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
    }

    private func questionView(_ question: NotchAgentQuestion, single: Bool, requestID: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(question.header).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).frame(height: 15).background(.white.opacity(0.15), in: Capsule())
                Text(question.question).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 2)
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                let selected = picks[question.id]?.contains(option.answer) == true
                optionRow(number: index + 1, label: option.label, detail: option.description, selected: selected) {
                    if single {
                        Task {
                            await t3.dispatch(.answer(threadID: threadID, requestID: requestID,
                                                      answers: [question.id: [option.answer]], multi: []), for: threadID)
                        }
                    } else {
                        pick(option.answer, for: question)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func pick(_ answer: String, for question: NotchAgentQuestion) {
        var current = picks[question.id] ?? []
        if question.multiSelect == true {
            if let index = current.firstIndex(of: answer) { current.remove(at: index) } else { current.append(answer) }
        } else {
            current = [answer]
        }
        picks[question.id] = current
    }

    private func send(_ requestID: String, _ questions: [NotchAgentQuestion]) {
        let multi = Set(questions.filter { $0.multiSelect == true }.map(\.id))
        let answers = picks
        Task { await t3.dispatch(.answer(threadID: threadID, requestID: requestID, answers: answers, multi: multi), for: threadID) }
    }

    private func optionRow(number: Int?, label: String, detail: String?, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(number.map(String.init) ?? "").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7)).frame(width: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 10.5, weight: .semibold))
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(.white.opacity(selected ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func decision(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).frame(height: 20)
                .foregroundStyle(prominent ? .black : .white)
                .background(prominent ? Color(nsColor: .systemGreen) : .white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(NotchPressStyle())
    }
}
