import AppKit

/// The outlines the notch can take: the closed wings, the wings widened for an indicator, a timer or the countdown
/// to an event, those with a small row under them for a timer phase alert, those dropped down for a new screenshot,
/// a calendar Quick Peek, a finished download, a T3 Code alert, a new track or a finished timer, the small dictation pill, the open player,
/// the open player grown by a volume or brightness row, a script notice and its history page, and one T3 Code thread.
enum NotchShape: Equatable {
    case closed, indicator, timerAlert, screenshot, downloadPeek, eventPeek, agentPeek, trackPeek, timerDone, dictation, open,
         openLevel, thread, noticePeek, notifications
}

/// Places content around the camera housing, or around a simulated cutout of the width in the settings on displays
/// without one and wherever the simulated notch is forced.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let cutoutWidth: CGFloat
    let topHeight: CGFloat
    let expandedWidth: CGFloat
    let expandedBodyHeight: CGFloat
    let expandedCornerRadius: CGFloat
    let wingWidth: CGFloat
    /// The dictation pill's width and the height of its row under the camera, from the size settings.
    let dictationSize: CGSize
    /// A T3 Code thread's page below the camera row, from its size setting.
    let threadSize: CGSize
    /// A T3 alert's scale, from its size setting.
    let agentPeekScale: CGFloat

    init(screenFrame: CGRect, safeTop: CGFloat, leftWidth: CGFloat?, rightWidth: CGFloat?,
         settings: NotchSettings = NotchSettings()) {
        self.screenFrame = screenFrame
        topHeight = safeTop > 0 ? safeTop : 28
        if safeTop > 0, !settings.forceSimulatedNotch, let leftWidth, let rightWidth {
            cutoutWidth = max(0, screenFrame.width - leftWidth - rightWidth)
        } else {
            cutoutWidth = settings.simulatedNotchWidth
        }
        expandedWidth = settings.expandedWidth
        expandedBodyHeight = settings.expandedHeight
        expandedCornerRadius = settings.cornerRadius
        wingWidth = settings.wingWidth
        // The row always fits the tallest bars with 1 pt to spare above and below.
        let rowHeight = max(Self.dictationRowHeight * settings.dictationPillScale,
                            Self.dictationBarHeight * settings.dictationBarScale + 2)
        dictationSize = CGSize(width: (Self.dictationWidth * settings.dictationPillScale).rounded(),
                               height: rowHeight.rounded(.up))
        threadSize = CGSize(width: (Self.threadWidth * settings.agentPageScale).rounded(),
                            height: (Self.threadHeight * settings.agentPageScale).rounded())
        agentPeekScale = settings.agentAlertScale
    }

    init(screen: NSScreen, settings: NotchSettings = NotchSettings()) {
        self.init(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top,
                  leftWidth: screen.auxiliaryTopLeftArea?.width, rightWidth: screen.auxiliaryTopRightArea?.width,
                  settings: settings)
    }

    /// Stands in before the first layout and for fixture rendering: this MacBook's measured housing.
    static let fallback = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), safeTop: 32,
                                        leftWidth: 645.5, rightWidth: 645.5)

    /// Extra width on each wing while an indicator shows, room for a symbol and a short meter.
    static let hudWingExtra: CGFloat = 16
    /// The dictation pill at scale 1: narrower than the closed wings, with a row for Sotto's bars under the camera.
    static let dictationWidth: CGFloat = 220
    static let dictationRowHeight: CGFloat = 22
    /// The tallest dictation bar at scale 1.
    static let dictationBarHeight: CGFloat = 20
    /// How far a new screenshot drops the closed notch below the camera row, at the
    /// indicator's width.
    static let screenshotDrop: CGFloat = 84
    /// How far a calendar Quick Peek drops the closed notch: one row of title, time and place
    /// Quick Peek studies), at the countdown's width.
    static let eventPeekDrop: CGFloat = 42
    /// How far a finished download drops the closed notch: its name over its site, at
    /// the countdown's width like a Quick Peek.
    static let downloadPeekDrop: CGFloat = 42
    /// How far a T3 Code alert drops the closed notch: the thread's title over its project, branch and run time,
    /// at the countdown's width like a Quick Peek.
    static let agentPeekDrop: CGFloat = 42
    /// How far a track change drops the closed notch: one slim row of artwork, title and artist, at the closed
    /// wings' own width, so the notch only grows down a little.
    static let trackPeekDrop: CGFloat = 34
    /// How far a volume or brightness row grows the open player downward.
    static let levelRowHeight: CGFloat = 30
    /// How far a timer phase alert drops the widened wings: one line of "5 min left".
    static let timerAlertDrop: CGFloat = 22
    /// How far the timer's Done row drops the closed notch: the finished ring, Done, +1 min and Stop, at the
    /// countdown's width like a Quick Peek.
    static let timerDoneDrop: CGFloat = 42
    /// A thread's page at size 1: 360 × 220 with the camera row.
    static let threadWidth: CGFloat = 360
    static let threadHeight: CGFloat = 188
    var compactSize: CGSize { CGSize(width: min(cutoutWidth + 2 * wingWidth, screenFrame.width), height: topHeight) }

    /// Whether a change of outline from one size to another grows it, by area: the opening spring leads growth, the
    /// closing one everything else.
    static func grows(from old: CGSize, to new: CGSize) -> Bool {
        new.width * new.height > old.width * old.height
    }

    /// The visible outline of a shape, centred under the camera.
    func frame(_ shape: NotchShape) -> CGRect {
        var size = compactSize
        switch shape {
        case .closed: break
        case .indicator: size.width = min(size.width + 2 * Self.hudWingExtra, screenFrame.width)
        case .screenshot: size = CGSize(width: min(size.width + 2 * Self.hudWingExtra, screenFrame.width),
                                        height: topHeight + Self.screenshotDrop)
        case .eventPeek, .noticePeek: size = CGSize(width: min(size.width + 2 * Self.hudWingExtra, screenFrame.width),
                                       height: topHeight + Self.eventPeekDrop)
        case .downloadPeek: size = CGSize(width: min(size.width + 2 * Self.hudWingExtra, screenFrame.width),
                                          height: topHeight + Self.downloadPeekDrop)
        case .trackPeek: size.height = topHeight + Self.trackPeekDrop
        case .timerAlert: size = CGSize(width: min(size.width + 2 * Self.hudWingExtra, screenFrame.width),
                                        height: topHeight + Self.timerAlertDrop)
        case .timerDone: size = CGSize(width: min(size.width + 2 * Self.hudWingExtra, screenFrame.width),
                                       height: topHeight + Self.timerDoneDrop)
        // The size setting scales the alert, never narrower than the closed wings.
        case .agentPeek: size = CGSize(width: min(max((size.width + 2 * Self.hudWingExtra) * agentPeekScale, size.width),
                                                  screenFrame.width).rounded(),
                                       height: topHeight + (Self.agentPeekDrop * agentPeekScale).rounded())
        // Never narrower than the housing, on a display whose notch is wider than this one's.
        case .dictation: size = CGSize(width: min(max(dictationSize.width, cutoutWidth + 24), screenFrame.width),
                                       height: topHeight + dictationSize.height)
        case .open: size = CGSize(width: min(expandedWidth, screenFrame.width), height: topHeight + expandedBodyHeight)
        case .openLevel: size = CGSize(width: min(expandedWidth, screenFrame.width),
                                       height: topHeight + expandedBodyHeight + Self.levelRowHeight)
        // Never narrower than the open notch it grows from.
        case .thread: size = CGSize(width: min(max(threadSize.width, expandedWidth), screenFrame.width),
                                    height: topHeight + max(threadSize.height, expandedBodyHeight))
        case .notifications:
            size = CGSize(width: min(max(340, expandedWidth), screenFrame.width),
                          height: topHeight + max(188, expandedBodyHeight))
        }
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Lower corner radius: the player's own, 24 pt for a Quick Peek, a download, a T3 alert or the timer's Done row as in their
    /// studies, 18 pt for the slimmer track peek, 16 pt for a screenshot, 14 pt for the dictation pill and a timer
    /// phase alert, a tight 11 pt for the closed wings.
    func cornerRadius(_ shape: NotchShape) -> CGFloat {
        switch shape {
        case .open, .openLevel, .thread, .notifications: expandedCornerRadius
        case .eventPeek, .downloadPeek, .agentPeek, .timerDone, .noticePeek: 24
        case .trackPeek: 18
        case .screenshot: 16
        case .dictation, .timerAlert: 14
        case .closed, .indicator: 11
        }
    }

    /// Only the visible lower-rounded shape should receive clicks, including on offset displays.
    /// A cursor pushed against the top of the screen reports y equal to the screen's maxY, which
    /// `CGRect.contains` excludes, so the top edge is included here to keep the notch from reopening.
    func contains(_ point: CGPoint, _ shape: NotchShape) -> Bool {
        let rect = frame(shape)
        guard point.x >= rect.minX, point.x < rect.maxX, point.y >= rect.minY, point.y <= rect.maxY else { return false }
        let radius = cornerRadius(shape)
        guard point.y < rect.minY + radius else { return true }
        if point.x < rect.minX + radius {
            return hypot(point.x - rect.minX - radius, point.y - rect.minY - radius) <= radius
        }
        if point.x > rect.maxX - radius {
            return hypot(point.x - rect.maxX + radius, point.y - rect.minY - radius) <= radius
        }
        return true
    }

}

/// A connected display as the display picker and the placement see it.
struct NotchDisplay: Equatable {
    /// `CGDisplayCreateUUIDFromDisplayID`'s UUID: unlike the display number, it survives reconnects and restarts.
    let id: String
    let name: String
    let hasNotch: Bool
    /// The display with the menu bar, first in `NSScreen.screens`.
    let isMain: Bool

    init(id: String, name: String, hasNotch: Bool, isMain: Bool) {
        self.id = id
        self.name = name
        self.hasNotch = hasNotch
        self.isMain = isMain
    }

    init(screen: NSScreen, isMain: Bool) {
        self.init(id: Self.id(of: screen), name: screen.localizedName, hasNotch: screen.safeAreaInsets.top > 0, isMain: isMain)
    }

    static func id(of screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return screen.localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The display a choice lands on. A remembered display that is not connected falls back to the notch display,
    /// which falls back to the main one; the choice itself is kept, so the notch returns once the display does.
    static func resolve(_ choice: NotchDisplayChoice, in displays: [NotchDisplay]) -> NotchDisplay? {
        switch choice {
        case .notch: displays.first(where: \.hasNotch) ?? displays.first(where: \.isMain) ?? displays.first
        case .main: displays.first(where: \.isMain) ?? displays.first
        case .display(let id, _): displays.first { $0.id == id } ?? resolve(.notch, in: displays)
        }
    }
}
