import AppKit
import QuartzCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Upstream #14832: sidebar spinners stop while hidden and ask the compositor
/// for their real step rate instead of the display's full refresh rate.
@MainActor
struct GPUSpinnerPacingTests {
    @Test func hiddenSpinnerRemovesItsInstalledAnimation() {
        let spinner = GPUSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.contentLayer.add(
            CABasicAnimation(keyPath: "transform.rotation.z"),
            forKey: GPUSpinnerNSView.animationKey
        )
        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) != nil)

        spinner.isHidden = true

        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) == nil)
    }

    @Test func spinnerUnderAHiddenAncestorRemovesItsAnimation() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let spinner = GPUSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        container.addSubview(spinner)
        spinner.contentLayer.add(
            CABasicAnimation(keyPath: "transform.rotation.z"),
            forKey: GPUSpinnerNSView.animationKey
        )

        container.isHidden = true

        #expect(
            spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) == nil,
            "Sidebar rows hide an ancestor; the spinner must stop with it"
        )
    }

    @Test func spinnerAnimationsRequestTheirStepRateFromTheCompositor() {
        let spokes = GPUSpinnerNSView.makeRotationAnimation(style: .macOSSpokes, beginTime: 0)
        #expect(spokes.preferredFrameRateRange.maximum <= 20)
        #expect(spokes.preferredFrameRateRange.minimum >= 10)

        let arc = GPUSpinnerNSView.makeRotationAnimation(style: .arc, beginTime: 0)
        #expect(arc.preferredFrameRateRange.maximum <= 60)
    }
}
