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
