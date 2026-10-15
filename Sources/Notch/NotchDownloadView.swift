import AppKit
import SwiftUI

/// The row a finished download drops from the closed notch: the arrow, the file's name over its site
/// and quarantine state, and Shelf. A click on the name shows the file in Finder.
struct NotchDownloadPeekView: View {
    let download: NotchDownload
    @ObservedObject var experience: NotchExperience
    let topHeight: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Button(action: experience.revealDownload) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(download.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(download.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchRowPressStyle()).help("Show in Finder")
            .accessibilityLabel("Downloaded \(download.name), \(download.detail)")
            Button(action: experience.shelveDownload) {
                HStack(spacing: 4) { Image(systemName: "tray"); Text("Shelf") }.font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 20)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(NotchPressStyle()).help("Keep on the shelf").accessibilityLabel("Keep \(download.name) on the shelf")
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: NotchGeometry.downloadPeekDrop - 6)
        .padding(.top, topHeight)
    }
}
