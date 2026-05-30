import CoreGraphics
import Foundation
import Testing
@testable import ClaudeStats

@Suite("FloatingPanelDragMotion")
struct FloatingPanelDragMotionTests {
    private let startFrame = CGRect(x: 800, y: 300, width: 44, height: 132)
    private let startMouse = CGPoint(x: 830, y: 360)
    private let visibleFrame = CGRect(x: 100, y: 50, width: 1_000, height: 700)

    @Test("Default activation threshold is higher")
    func defaultActivationThreshold() {
        #expect(FloatingPanelDragMotion.defaultActivationDistance == 64)
    }

    @Test("Below threshold does not move the frame")
    func belowThresholdDoesNotMove() {
        let currentMouse = CGPoint(x: 852, y: 382)
        let frame = FloatingPanelDragMotion.activatedFrame(
            startFrame: startFrame,
            startMouse: startMouse,
            currentMouse: currentMouse,
            activationDistance: 64
        )

        #expect(frame == nil)
    }

    @Test("Crossing threshold returns start frame plus full delta")
    func crossingThresholdUsesFullDelta() throws {
        let currentMouse = CGPoint(x: 900, y: 390)
        let frame = try #require(FloatingPanelDragMotion.activatedFrame(
            startFrame: startFrame,
            startMouse: startMouse,
            currentMouse: currentMouse,
            activationDistance: 64
        ))

        #expect(frame.origin.x == startFrame.origin.x + 70)
        #expect(frame.origin.y == startFrame.origin.y + 30)
    }

    @Test("Docked drag step stays pending below threshold")
    func dockedDragStepStaysPendingBelowThreshold() {
        let step = FloatingPanelDragMotion.dragStep(
            startFrame: startFrame,
            startMouse: startMouse,
            currentMouse: CGPoint(x: 852, y: 382),
            isDocked: true,
            activationDistance: 64
        )

        #expect(step == .pending)
    }

    @Test("Docked drag step activates with detached shape progress")
    func dockedDragStepActivatesWithDetachedShapeProgress() {
        let step = FloatingPanelDragMotion.dragStep(
            startFrame: startFrame,
            startMouse: startMouse,
            currentMouse: CGPoint(x: 900, y: 390),
            isDocked: true,
            activationDistance: 64
        )

        #expect(step == .active(
            frame: startFrame.offsetBy(dx: 70, dy: 30),
            edgeReleaseProgress: FloatingPanelDragMotion.detachedEdgeReleaseProgress
        ))
    }

    @Test("Detached drag step moves immediately without threshold")
    func detachedDragStepMovesImmediatelyWithoutThreshold() {
        let step = FloatingPanelDragMotion.dragStep(
            startFrame: startFrame,
            startMouse: startMouse,
            currentMouse: CGPoint(x: 832, y: 361),
            isDocked: false,
            activationDistance: 64
        )

        #expect(step == .active(
            frame: startFrame.offsetBy(dx: 2, dy: 1),
            edgeReleaseProgress: FloatingPanelDragMotion.detachedEdgeReleaseProgress
        ))
    }

    @Test("Active drag follows absolute screen-coordinate delta")
    func activeDragFollowsAbsoluteDelta() {
        let currentMouse = CGPoint(x: 790, y: 420)
        let frame = FloatingPanelDragMotion.frame(
            startFrame: startFrame,
            startMouse: startMouse,
            currentMouse: currentMouse
        )

        #expect(frame.origin.x == startFrame.origin.x - 40)
        #expect(frame.origin.y == startFrame.origin.y + 60)
    }

    @Test("Far from edges does not magnetize")
    func farFromEdgesDoesNotMagnetize() {
        let frame = CGRect(x: 430, y: 270, width: 300, height: 220)
        let magnetic = FloatingPanelDragMotion.magneticFrame(frame, in: visibleFrame)

        #expect(magnetic == frame)
    }

    @Test("Near edges magnetizes only perpendicular axis")
    func nearEdgesMagnetizePerpendicularAxis() {
        let left = CGRect(x: 150, y: 270, width: 300, height: 220)
        let right = CGRect(x: 750, y: 270, width: 300, height: 220)
        let bottom = CGRect(x: 430, y: 90, width: 300, height: 220)
        let top = CGRect(x: 430, y: 490, width: 300, height: 220)

        let leftMagnetic = FloatingPanelDragMotion.magneticFrame(left, in: visibleFrame)
        let rightMagnetic = FloatingPanelDragMotion.magneticFrame(right, in: visibleFrame)
        let bottomMagnetic = FloatingPanelDragMotion.magneticFrame(bottom, in: visibleFrame)
        let topMagnetic = FloatingPanelDragMotion.magneticFrame(top, in: visibleFrame)

        #expect(leftMagnetic.minX < left.minX)
        #expect(leftMagnetic.minY == left.minY)
        #expect(rightMagnetic.minX > right.minX)
        #expect(rightMagnetic.minY == right.minY)
        #expect(bottomMagnetic.minY < bottom.minY)
        #expect(bottomMagnetic.minX == bottom.minX)
        #expect(topMagnetic.minY > top.minY)
        #expect(topMagnetic.minX == top.minX)
    }

    @Test("Release inside snap radius docks with edge and anchor")
    func releaseInsideSnapRadiusDocks() {
        let frame = CGRect(x: 130, y: 270, width: 300, height: 220)
        let placement = FloatingPanelDragMotion.releasePlacement(for: frame, in: visibleFrame)

        if case let .docked(edge, anchor) = placement {
            #expect(edge == .left)
            #expect(anchor > 0)
            #expect(anchor < 1)
        } else {
            #expect(Bool(false))
        }
    }

    @Test("Release outside snap radius stays detached")
    func releaseOutsideSnapRadiusStaysDetached() {
        let frame = CGRect(x: 300, y: 270, width: 300, height: 220)
        let placement = FloatingPanelDragMotion.releasePlacement(for: frame, in: visibleFrame)

        if case let .detached(detachedFrame) = placement {
            #expect(detachedFrame == frame)
        } else {
            #expect(Bool(false))
        }
    }

    @Test("Detached frame clamps when visible frame shrinks")
    func detachedFrameClampsWhenVisibleFrameShrinks() {
        let frame = CGRect(x: 720, y: 500, width: 300, height: 220)
        let shrunkVisibleFrame = CGRect(x: 100, y: 50, width: 700, height: 500)
        let clamped = FloatingPanelDragMotion.clampedFrame(frame, in: shrunkVisibleFrame)

        #expect(clamped.maxX <= shrunkVisibleFrame.maxX)
        #expect(clamped.maxY <= shrunkVisibleFrame.maxY)
        #expect(clamped.minX >= shrunkVisibleFrame.minX)
        #expect(clamped.minY >= shrunkVisibleFrame.minY)
    }
}
