import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for high-resolution mice (e.g. Logitech free-spin
/// wheels) being double-amplified in the terminal. Such mice report precise
/// scrolling deltas like a trackpad but carry no gesture phase, so the 2x boost
/// must not apply to them.
@Suite
struct GhosttyScrollPreciseBoostTests {
    @Test
    func trackpadGesturePhaseGetsBoost() {
        #expect(
            GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: true,
                phase: .changed,
                momentumPhase: []
            ).shouldDoublePreciseScrollDelta
        )
    }

    @Test
    func trackpadMomentumPhaseGetsBoost() {
        #expect(
            GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: true,
                phase: [],
                momentumPhase: .changed
            ).shouldDoublePreciseScrollDelta
        )
    }

    @Test
    func highResMouseWithoutPhaseIsNotBoosted() {
        // Logitech free-spin wheel: precise deltas, no phase, no momentum.
        #expect(
            !GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: true,
                phase: [],
                momentumPhase: []
            ).shouldDoublePreciseScrollDelta
        )
    }

    @Test
    func notchedMouseIsNotBoosted() {
        #expect(
            !GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: false,
                phase: [],
                momentumPhase: []
            ).shouldDoublePreciseScrollDelta
        )
    }
}

@Suite
struct GhosttyTerminalScrollGeometryTests {
    @Test
    func mapsTopBottomAndFractionalOffsets() throws {
        let maximum = try #require(
            GhosttyTerminalScrollGeometry.maximumRowOffset(
                documentHeight: 1_000,
                viewportHeight: 400,
                cellHeight: 20
            )
        )
        #expect(maximum == 30)

        #expect(
            GhosttyTerminalScrollGeometry.rowOffset(
                documentHeight: 1_000,
                viewportOriginY: 600,
                viewportHeight: 400,
                cellHeight: 20
            ) == 0
        )
        #expect(
            GhosttyTerminalScrollGeometry.rowOffset(
                documentHeight: 1_000,
                viewportOriginY: 0,
                viewportHeight: 400,
                cellHeight: 20
            ) == 30
        )
        #expect(
            GhosttyTerminalScrollGeometry.rowOffset(
                documentHeight: 1_000,
                viewportOriginY: 350,
                viewportHeight: 400,
                cellHeight: 20
            ) == 12.5
        )
    }

    @Test
    func inverseMappingClampsToDocumentBounds() {
        #expect(
            GhosttyTerminalScrollGeometry.viewportOriginY(
                rowOffset: -10,
                documentHeight: 1_000,
                viewportHeight: 400,
                cellHeight: 20
            ) == 600
        )
        #expect(
            GhosttyTerminalScrollGeometry.viewportOriginY(
                rowOffset: 12.5,
                documentHeight: 1_000,
                viewportHeight: 400,
                cellHeight: 20
            ) == 350
        )
        #expect(
            GhosttyTerminalScrollGeometry.viewportOriginY(
                rowOffset: 100,
                documentHeight: 1_000,
                viewportHeight: 400,
                cellHeight: 20
            ) == 0
        )
    }
}

@Suite
struct GhosttyTerminalScrollRoutingTests {
    @Test
    func nativeRouteRequiresEveryPrecondition() {
        #expect(
            GhosttyTerminalScrollRouting.usesNativeScrolling(
                smoothScrollingEnabled: true,
                hasSurface: true,
                hasScrollback: true,
                mouseCaptured: false,
                hasValidCellGeometry: true
            )
        )

        let rejectedInputs: [(Bool, Bool, Bool, Bool, Bool)] = [
            (false, true, true, false, true),
            (true, false, true, false, true),
            (true, true, false, false, true),
            (true, true, true, true, true),
            (true, true, true, false, false),
        ]
        for input in rejectedInputs {
            #expect(
                !GhosttyTerminalScrollRouting.usesNativeScrolling(
                    smoothScrollingEnabled: input.0,
                    hasSurface: input.1,
                    hasScrollback: input.2,
                    mouseCaptured: input.3,
                    hasValidCellGeometry: input.4
                )
            )
        }
    }
}

/// A gesture must keep the route it started with. Momentum is the same physical scroll
/// as the fingers that launched it, so a TUI grabbing the alt screen between finger-lift
/// and momentum must not flip the route mid-flight.
@Suite
struct GhosttyTerminalWheelLatchTests {
    @Test
    func gestureStartResolvesAndHoldsTheRoute() {
        let began = GhosttyTerminalScrollRouting.wheelLatch(
            phase: .began, momentumPhase: [], hasLatchedRoute: false
        )
        #expect(began.resolvesRoute)
        #expect(!began.clearsLatchAfterEvent)

        let changed = GhosttyTerminalScrollRouting.wheelLatch(
            phase: .changed, momentumPhase: [], hasLatchedRoute: true
        )
        #expect(!changed.resolvesRoute)
        #expect(!changed.clearsLatchAfterEvent)
    }

    @Test
    func fingerLiftKeepsTheLatchSoMomentumCannotReResolve() {
        let ended = GhosttyTerminalScrollRouting.wheelLatch(
            phase: .ended, momentumPhase: [], hasLatchedRoute: true
        )
        #expect(!ended.clearsLatchAfterEvent)

        // The first momentum event carries no phase, only a momentum phase. If the
        // latch had been dropped on `.ended` this would resolve the route afresh.
        let momentumBegan = GhosttyTerminalScrollRouting.wheelLatch(
            phase: [], momentumPhase: .began, hasLatchedRoute: true
        )
        #expect(!momentumBegan.resolvesRoute)
        #expect(!momentumBegan.clearsLatchAfterEvent)
    }

    @Test
    func momentumEndAndCancellationReleaseTheLatch() {
        #expect(
            GhosttyTerminalScrollRouting.wheelLatch(
                phase: [], momentumPhase: .ended, hasLatchedRoute: true
            ).clearsLatchAfterEvent
        )
        #expect(
            GhosttyTerminalScrollRouting.wheelLatch(
                phase: [], momentumPhase: .cancelled, hasLatchedRoute: true
            ).clearsLatchAfterEvent
        )
        #expect(
            GhosttyTerminalScrollRouting.wheelLatch(
                phase: .cancelled, momentumPhase: [], hasLatchedRoute: true
            ).clearsLatchAfterEvent
        )
    }

    @Test
    func legacyWheelsResolveEveryEventAndNeverLatch() {
        // No phase information at all, so there is no gesture boundary to latch to.
        let legacy = GhosttyTerminalScrollRouting.wheelLatch(
            phase: [], momentumPhase: [], hasLatchedRoute: true
        )
        #expect(legacy.resolvesRoute)
        #expect(legacy.clearsLatchAfterEvent)
    }

    @Test
    func aMissingLatchIsAlwaysResolved() {
        // An event stream joined mid-gesture still needs a route.
        #expect(
            GhosttyTerminalScrollRouting.wheelLatch(
                phase: .changed, momentumPhase: [], hasLatchedRoute: false
            ).resolvesRoute
        )
    }
}

/// The terminal scroller reserves a 24pt gutter, but AppKit keeps its own 11pt knob
/// metric and right-aligns it there. Deriving the drawn knob from AppKit's track rect
/// produced a ~1pt sliver, so the width must come from the scroller bounds instead.
@Suite
struct GhosttyTerminalScrollerKnobTests {
    /// Matches the real AppKit geometry measured for a 24pt vertical scroller.
    private static let appKitKnobRect = CGRect(x: 10, y: 268, width: 11, height: 29)
    private static let scrollerBounds = CGRect(x: 0, y: 0, width: 24, height: 300)

    @Test
    func knobSpansTheGutterRatherThanAppKitsTrackWidth() {
        let knob = GhosttyTerminalScrollGeometry.knobRect(
            appKitKnobRect: Self.appKitKnobRect,
            scrollerBounds: Self.scrollerBounds,
            knobWidth: 9,
            verticalInset: 2
        )

        #expect(knob.width == 9)
        #expect(knob.midX == Self.scrollerBounds.midX)
        #expect(knob.minY == 270)
        #expect(knob.height == 25)
    }

    @Test
    func knobNeverExceedsANarrowScroller() {
        let knob = GhosttyTerminalScrollGeometry.knobRect(
            appKitKnobRect: Self.appKitKnobRect,
            scrollerBounds: CGRect(x: 0, y: 0, width: 6, height: 300),
            knobWidth: 9,
            verticalInset: 2
        )

        #expect(knob.width == 6)
        #expect(knob.minX == 0)
    }
}

/// libghostty's `scroll_to_row` is absolute from the top of scrollback, while captured
/// notification positions are measured from the bottom. Feeding one to the other
/// mirrored the target: a notification recorded at the bottom jumped to the top.
@Suite
struct GhosttyTerminalScrollTopOriginRowTests {
    @Test
    func bottomCaptureRestoresToTheLiveScreen() {
        #expect(
            GhosttyTerminalScrollGeometry.topOriginRow(
                rowFromBottom: 0,
                totalRows: 1_000,
                viewportRows: 24
            ) == 976
        )
    }

    @Test
    func topCaptureRestoresToTheOldestRow() {
        #expect(
            GhosttyTerminalScrollGeometry.topOriginRow(
                rowFromBottom: 976,
                totalRows: 1_000,
                viewportRows: 24
            ) == 0
        )
    }

    @Test
    func midHistoryCaptureRoundTrips() {
        #expect(
            GhosttyTerminalScrollGeometry.topOriginRow(
                rowFromBottom: 100,
                totalRows: 1_000,
                viewportRows: 24
            ) == 876
        )
    }

    @Test
    func outOfRangeCapturesClampInsteadOfWrapping() {
        #expect(
            GhosttyTerminalScrollGeometry.topOriginRow(
                rowFromBottom: 5_000,
                totalRows: 1_000,
                viewportRows: 24
            ) == 0
        )
        #expect(
            GhosttyTerminalScrollGeometry.topOriginRow(
                rowFromBottom: -5,
                totalRows: 1_000,
                viewportRows: 24
            ) == 976
        )
        // A surface with no scrollback has exactly one valid row.
        #expect(
            GhosttyTerminalScrollGeometry.topOriginRow(
                rowFromBottom: 0,
                totalRows: 24,
                viewportRows: 24
            ) == 0
        )
    }
}

/// The clip view addresses scrollback by an absolute offset from the top, which
/// eviction invalidates. libghostty reports the authoritative viewport row, but from
/// the renderer thread during a draw, so a packet can pre-date a commit and arrive
/// after it. Only the first packet after a commit can be that stale one.
@Suite
struct GhosttyTerminalScrollReportTrackerTests {
    @Test
    func evictionBetweenPacketsIsReportedAsANegativeDelta() {
        var tracker = GhosttyTerminalScrollReportTracker()

        #expect(tracker.noteReport(rowOffset: 900) == nil)  // first packet only baselines
        let delta = tracker.noteReport(rowOffset: 892)

        #expect(delta == -8)
    }

    @Test
    func appendOnlyOutputReportsNoMove() {
        var tracker = GhosttyTerminalScrollReportTracker()

        _ = tracker.noteReport(rowOffset: 900)

        // Rows appended below the viewport do not change its offset from the top.
        #expect(tracker.noteReport(rowOffset: 900) == nil)
    }

    @Test
    func firstPacketAfterACommitIsDiscardedBecauseItMayPreDateIt() {
        var tracker = GhosttyTerminalScrollReportTracker()
        _ = tracker.noteReport(rowOffset: 900)

        tracker.noteCommit(rowOffset: 880.4, maximumRowOffset: 976)

        // A packet generated before the commit still reports the old row. Attributing
        // it would shift the clip by the commit's own movement.
        #expect(tracker.noteReport(rowOffset: 900) == nil)
        // The next packet is guaranteed to post-date the commit, and is measured
        // against the committed row rather than the discarded packet.
        #expect(tracker.noteReport(rowOffset: 880) == nil)
    }

    @Test
    func evictionAfterACommitIsMeasuredAgainstTheCommittedRow() {
        var tracker = GhosttyTerminalScrollReportTracker()
        _ = tracker.noteReport(rowOffset: 900)
        tracker.noteCommit(rowOffset: 880.4, maximumRowOffset: 976)
        _ = tracker.noteReport(rowOffset: 900)  // stale, discarded

        // 880 committed (fractional part is libghostty's renderer offset, not a row),
        // then a page of 120 rows is pruned above the anchor.
        #expect(tracker.noteReport(rowOffset: 760) == -120)
    }

    @Test
    func severalSamplesTakenBeforeACommitAreAllDiscarded() {
        // The renderer samples the row under the state mutex but publishes at the end
        // of the frame, so more than one pre-commit sample can be in flight. Each
        // carries a row the viewport actually held, which is what identifies them.
        var tracker = GhosttyTerminalScrollReportTracker()
        _ = tracker.noteReport(rowOffset: 900)

        tracker.noteCommit(rowOffset: 890, maximumRowOffset: 976)
        tracker.noteCommit(rowOffset: 880, maximumRowOffset: 976)
        tracker.noteCommit(rowOffset: 870, maximumRowOffset: 976)

        #expect(tracker.noteReport(rowOffset: 900) == nil)
        #expect(tracker.noteReport(rowOffset: 890) == nil)
        #expect(tracker.noteReport(rowOffset: 880) == nil)
        // Only now does a real move show up, measured from the last committed row.
        #expect(tracker.noteReport(rowOffset: 750) == -120)
    }

    @Test
    func aMoveInsideTheAcknowledgementWindowIsNotSwallowed() {
        // A keyboard scroll or prompt jump landing right after a commit reports a row
        // the viewport has never held, so it cannot be a stale sample. An idle terminal
        // produces no follow-up packet, so discarding it would strand the clip.
        var tracker = GhosttyTerminalScrollReportTracker()
        _ = tracker.noteReport(rowOffset: 900)
        tracker.noteCommit(rowOffset: 880, maximumRowOffset: 976)

        #expect(tracker.noteReport(rowOffset: 400) == -480)
    }

    @Test
    func observedRowHistoryIsBounded() {
        // A long scroll must not retain rows forever, or a genuine return to an old
        // row would be misread as a stale sample indefinitely.
        var tracker = GhosttyTerminalScrollReportTracker()
        _ = tracker.noteReport(rowOffset: 500)
        for row in 0..<40 {
            tracker.noteCommit(rowOffset: Double(600 + row), maximumRowOffset: 976)
            _ = tracker.noteReport(rowOffset: Double(600 + row))
        }

        tracker.noteCommit(rowOffset: 700, maximumRowOffset: 976)
        // 500 has long since aged out, so a move back to it is attributed.
        #expect(tracker.noteReport(rowOffset: 500) == -200)
    }

    @Test
    func commitExpectationMirrorsLibghosttysClamp() {
        var tracker = GhosttyTerminalScrollReportTracker()
        _ = tracker.noteReport(rowOffset: 0)

        // The view's geometry can ask for a row past the end; libghostty clamps to
        // total - len, so the expectation has to clamp identically or the next packet
        // reads as a spurious move.
        tracker.noteCommit(rowOffset: 999, maximumRowOffset: 976)
        #expect(tracker.expectedRowOffset == 976)
        _ = tracker.noteReport(rowOffset: 976)
        #expect(tracker.noteReport(rowOffset: 976) == nil)

        tracker.noteCommit(rowOffset: -5, maximumRowOffset: 976)
        #expect(tracker.expectedRowOffset == 0)
    }
}
