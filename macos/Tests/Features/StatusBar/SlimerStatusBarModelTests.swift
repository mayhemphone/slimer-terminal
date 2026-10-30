import Testing
import Combine
import Foundation
@testable import Ghostty

/// Stands in for `Ghostty.SurfaceView`: an object with published pwd/title that
/// owns its model through the same associated-object path.
private final class FakeSurface: NSObject, ObservableObject {
    @Published var pwd: String?
    @Published var title: String = ""
}

@MainActor
struct SlimerStatusBarModelTests {
    private func makeModel(for surface: FakeSurface) -> SlimerStatusBarModel {
        SlimerStatusBarModel.model(
            for: surface,
            pwd: surface.$pwd.eraseToAnyPublisher(),
            title: surface.$title.eraseToAnyPublisher(),
            foregroundPID: { nil }
        )
    }

    @Test func surfaceDeallocatesAfterModelIsCreated() {
        weak var weakSurface: FakeSurface?
        weak var weakModel: SlimerStatusBarModel?
        do {
            let surface = FakeSurface()
            weakSurface = surface
            let model = makeModel(for: surface)
            weakModel = model
            surface.title = "me@host: ~"
            // Exercise the command-finished subscription too.
            SlimerCommandFinished.post(surfaceView: surface, exitCode: 0, duration: 1_000_000)
            #expect(model.lastCommand?.exitCode == 0)
        }
        #expect(weakSurface == nil)
        #expect(weakModel == nil)
    }

    @Test func modelIsReusedPerSurfaceAndRemovable() {
        let surface = FakeSurface()
        let first = makeModel(for: surface)
        #expect(makeModel(for: surface) === first)
        SlimerStatusBarModel.removeModel(for: surface)
        #expect(SlimerStatusBarModel.existingModel(for: surface) == nil)
        #expect(makeModel(for: surface) !== first)
    }

    @Test func commandFinishedFromOtherSurfacesIsIgnored() {
        let surface = FakeSurface()
        let other = FakeSurface()
        let model = makeModel(for: surface)
        SlimerCommandFinished.post(surfaceView: other, exitCode: 1, duration: 5)
        #expect(model.lastCommand == nil)
        SlimerCommandFinished.post(surfaceView: surface, exitCode: -1, duration: 5)
        #expect(model.lastCommand == .init(exitCode: nil, durationNanoseconds: 5))
    }

    @Test func barNeedsThreeBarHeights() {
        for size: CGFloat in [9, 13, 24] {
            let height = SlimerStatusBar.height(forFontSize: size)
            #expect(!SlimerStatusBar.fits(inLeafHeight: height * 3 - 1, fontSize: size))
            #expect(SlimerStatusBar.fits(inLeafHeight: height * 3, fontSize: size))
        }
    }

    @Test func barHeightScalesWithTextSize() {
        #expect(SlimerStatusBar.height(forFontSize: 11) == 22)
        #expect(SlimerStatusBar.height(forFontSize: 13) == 26)
        #expect(SlimerStatusBar.height(forFontSize: 24) == 48)
        #expect(SlimerStatusBar.iconSize(forFontSize: 13) < 13)
    }

    @Test func initialHeightAccountsForTheBar() {
        #expect(SlimerStatusBar.initialHeightExtra(for: .bottom, fontSize: 13) == 26)
        #expect(SlimerStatusBar.initialHeightExtra(for: .top, fontSize: 16) == 32)
        #expect(SlimerStatusBar.initialHeightExtra(for: .hidden, fontSize: 16) == 0)
    }
}
