import Foundation
import LumaRemoteCore
@testable import LumaRemoteKit
import Testing

@Test func textChangesBecomeBackspacesAndText() {
    #expect(TextDiff.messages(from: "helo", to: "hello") == [.edit(.backspace(1)), .text("lo")])
    #expect(TextDiff.messages(from: "", to: "hi") == [.text("hi")])
    #expect(TextDiff.messages(from: "abc", to: "") == [.edit(.backspace(3))])
}

@Test func keyPressesTapHoldAndRepeat() {
    #expect(KeyPress(.ok).released() == .key(.ok, .tap))

    var volume = KeyPress(.volumeUp)
    #expect(volume.threshold == .milliseconds(300))
    #expect(volume.thresholdPassed() == .key(.volumeUp, .down))
    #expect(volume.thresholdPassed() == nil)
    #expect(volume.released() == .key(.volumeUp, .up))
    #expect(volume.cancelled() == .key(.volumeUp, .up))

    var back = KeyPress(.back)
    #expect(back.threshold == .milliseconds(500))
    #expect(back.thresholdPassed() == .key(.back, .hold))
    #expect(back.released() == nil)

    var home = KeyPress(.home)
    #expect(home.threshold == nil && home.thresholdPassed() == nil)
    #expect(home.released() == .key(.home, .tap))
    #expect(KeyPress(.left).cancelled() == nil)
}

@Test func swipesStepThroughArrows() {
    var swipe = SwipeTracker(x: 0, y: 0)
    #expect(swipe.move(x: 30, y: 4).isEmpty)
    #expect(swipe.move(x: 100, y: 10) == [.right, .right])
    // The sideways drift was re-centred, so only the new downward travel counts.
    #expect(swipe.move(x: 100, y: 60) == [.down])
    #expect(swipe.move(x: 100, y: -40) == [.up, .up])
}

@Test func trackpadTapsDragsAndScrolls() {
    var pad = TrackpadTracker()
    #expect(pad.update(count: 1, x: 100, y: 100, time: 0).isEmpty)
    #expect(pad.update(count: 0, x: 100, y: 100, time: 0.1) == [.click])

    // A touch straight after the tap drags once it moves.
    #expect(pad.update(count: 1, x: 100, y: 100, time: 0.2).isEmpty)
    let drag = pad.update(count: 1, x: 120, y: 100, time: 0.25)
    #expect(drag.first == .press)
    guard case .move(let dx, let dy) = drag.last else {
        Issue.record("no move")
        return
    }
    #expect(dx > 20 * 1.2 && dy == 0)
    #expect(pad.update(count: 0, x: 120, y: 100, time: 0.4) == [.release])

    // Two fingers scroll against their motion and fling on if they lift still moving; resting first just stops.
    #expect(pad.update(count: 2, x: 100, y: 100, time: 1) == [.scrolling(true)])
    #expect(pad.update(count: 2, x: 100, y: 70, time: 1.015625) == [.scroll(dx: 0, dy: 60)])
    #expect(pad.update(count: 0, x: 100, y: 70, time: 1.03125) == [.fling(dx: 0, dy: 1920)])
    #expect(pad.update(count: 2, x: 100, y: 100, time: 2) == [.scrolling(true)])
    #expect(pad.update(count: 2, x: 100, y: 70, time: 2.015625) == [.scroll(dx: 0, dy: 60)])
    #expect(pad.update(count: 0, x: 100, y: 70, time: 2.5) == [.scrolling(false)])

    // A quick two-finger tap is Back.
    #expect(pad.update(count: 2, x: 50, y: 50, time: 3) == [.scrolling(true)])
    #expect(pad.update(count: 1, x: 80, y: 50, time: 3.05).isEmpty)
    #expect(pad.update(count: 0, x: 80, y: 50, time: 3.1) == [.scrolling(false), .back])
}

@Test func flungScrollingDecaysToAStop() {
    var momentum = ScrollMomentum(velocityX: 0, velocityY: 1000)
    var travelled = 0.0
    var steps = 0
    while let step = momentum.step(interval: 1.0 / 60) {
        travelled += step.dy
        steps += 1
    }
    // Speed falls from 1,000 to 20 points a second: (1000 - 20) / -ln(0.998^1000) points in all.
    #expect(abs(travelled - 980 / -log(ScrollMomentum.decayPerSecond)) < 1)
    #expect(steps < 200)
}

@Test func airMouseFollowsTheTurn() {
    let flat = AirMouseMath.Vector(x: 0, y: 0, z: -1)
    // Turning right, clockwise from above, is negative about the screen's normal when it faces up.
    let right = AirMouseMath.pointerRates(rotation: .init(x: 0, y: 0, z: -1), gravity: flat)
    #expect(right.x > 0.99 && abs(right.y) < 1e-9)
    // Raising the top edge is positive about the phone's x axis and moves the pointer up.
    let up = AirMouseMath.pointerRates(rotation: .init(x: 1, y: 0, z: 0), gravity: flat)
    #expect(up.y < -0.99 && abs(up.x) < 1e-9)
    // Tremor below the dead zone barely moves it.
    #expect(abs(AirMouseMath.soften(0.002)) < 0.0001)
    #expect(AirMouseMath.acceleration(.pi / 2) > 0.99 && AirMouseMath.acceleration(.pi / 2) < 1.01)
}

@Test func latencySummaryUsesNearestRank() throws {
    let summary = try #require(LatencySummary((1...20).map { Duration.milliseconds($0) }.shuffled()))
    #expect(summary.median == .milliseconds(10) && summary.p95 == .milliseconds(19) && summary.worst == .milliseconds(20))
    #expect(LatencySummary([]) == nil)
}
