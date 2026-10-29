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
        #expect(!SlimerStatusBar.fits(inLeafHeight: SlimerStatusBar.height * 3 - 1))
        #expect(SlimerStatusBar.fits(inLeafHeight: SlimerStatusBar.height * 3))
    }

    @Test func initialHeightAccountsForTheBar() {
        #expect(SlimerStatusBar.initialHeightExtra(for: .bottom) == SlimerStatusBar.height)
        #expect(SlimerStatusBar.initialHeightExtra(for: .top) == SlimerStatusBar.height)
        #expect(SlimerStatusBar.initialHeightExtra(for: .hidden) == 0)
    }
}
