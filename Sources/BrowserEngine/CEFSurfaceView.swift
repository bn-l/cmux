import AppKit
import IOSurface
import Bonsplit

/// NSView that displays CEF's offscreen-rendered content via IOSurface.
///
/// CEF renders each frame to an IOSurface (via OnAcceleratedPaint) or
/// a BGRA pixel buffer (via OnPaint). This view sets the surface/image
/// as its layer's contents for zero-copy GPU compositing.
///
/// Follows the same pattern as Ghostty's IOSurfaceLayer for terminal rendering.
final class CEFSurfaceView: NSView {

    /// Delegate for forwarding input events to CEF.
    weak var inputDelegate: CEFSurfaceInputDelegate?

    /// Called when the view's size changes (DIP coordinates).
    var onViewSizeChanged: ((NSSize) -> Void)?

    private var displayLayer: CALayer!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        displayLayer = CALayer()
        displayLayer.contentsGravity = .resizeAspectFill
        displayLayer.magnificationFilter = .nearest
        displayLayer.isOpaque = true
        // Disable implicit animations on the display layer
        displayLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "contentsScale": NSNull(),
        ]
        layer!.addSublayer(displayLayer)
        updateDisplayLayerFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Rendering

    /// Called from OnAcceleratedPaint with an IOSurfaceRef.
    /// Must be called on the main thread, synchronously within the callback.
    func updateIOSurface(_ surfaceRef: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // CALayer.contents accepts IOSurfaceRef as an id-compatible type.
        // Use unsafeBitCast to pass the IOSurface as the contents object.
        displayLayer.contents = unsafeBitCast(surfaceRef, to: AnyObject.self)
        CATransaction.commit()
#if DEBUG
        if updateCount < 3 {
            let w = IOSurfaceGetWidth(surfaceRef)
            let h = IOSurfaceGetHeight(surfaceRef)
            dlog("cef.osr.updateIOSurface \(w)x\(h) layer=\(displayLayer.frame) view=\(bounds) inWindow=\(window != nil) superview=\(superview != nil)")
        }
        updateCount += 1
#endif
    }
    #if DEBUG
    private var updateCount = 0
    #endif

    /// Fallback: called from OnPaint with a BGRA pixel buffer.
    func updateBitmap(_ buffer: UnsafeRawPointer, width: Int, height: Int) {
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(dataInfo: nil,
                                             data: buffer,
                                             size: width * height * 4,
                                             releaseData: { _, _, _ in }),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contents = image
        CATransaction.commit()
    }

    // MARK: - Layout

    private func updateDisplayLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateDisplayLayerFrame()
        onViewSizeChanged?(bounds.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDisplayLayerFrame()
        onViewSizeChanged?(newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayLayerFrame()
    }

    // MARK: - Input: Mouse

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func cefPoint(from event: NSEvent) -> (x: Int32, y: Int32) {
        let local = convert(event.locationInWindow, from: nil)
        // Flip Y: macOS bottom-left → CEF top-left
        return (Int32(local.x), Int32(bounds.height - local.y))
    }

    override func mouseDown(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseClick(x: x, y: y, button: 0, mouseUp: false,
                                       clickCount: Int32(event.clickCount),
                                       modifiers: CEFModifiers.from(event))
    }

    override func mouseUp(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseClick(x: x, y: y, button: 0, mouseUp: true,
                                       clickCount: Int32(event.clickCount),
                                       modifiers: CEFModifiers.from(event))
    }

    override func mouseMoved(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseMove(x: x, y: y, mouseLeave: false,
                                      modifiers: CEFModifiers.from(event))
    }

    override func mouseDragged(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseMove(x: x, y: y, mouseLeave: false,
                                      modifiers: CEFModifiers.from(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseClick(x: x, y: y, button: 2, mouseUp: false,
                                       clickCount: Int32(event.clickCount),
                                       modifiers: CEFModifiers.from(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseClick(x: x, y: y, button: 2, mouseUp: true,
                                       clickCount: Int32(event.clickCount),
                                       modifiers: CEFModifiers.from(event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseMove(x: x, y: y, mouseLeave: false,
                                      modifiers: CEFModifiers.from(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseClick(x: x, y: y, button: 1, mouseUp: false,
                                       clickCount: Int32(event.clickCount),
                                       modifiers: CEFModifiers.from(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseClick(x: x, y: y, button: 1, mouseUp: true,
                                       clickCount: Int32(event.clickCount),
                                       modifiers: CEFModifiers.from(event))
    }

    override func scrollWheel(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 40
            dy *= 40
        }
        inputDelegate?.sendMouseWheel(x: x, y: y,
                                       deltaX: Int32(dx), deltaY: Int32(dy),
                                       modifiers: CEFModifiers.from(event))
    }

    override func mouseEntered(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseMove(x: x, y: y, mouseLeave: false,
                                      modifiers: CEFModifiers.from(event))
    }

    override func mouseExited(with event: NSEvent) {
        let (x, y) = cefPoint(from: event)
        inputDelegate?.sendMouseMove(x: x, y: y, mouseLeave: true,
                                      modifiers: CEFModifiers.from(event))
    }

    // MARK: - Input: Keyboard

    override func keyDown(with event: NSEvent) {
        inputDelegate?.sendKeyEvent(event, type: 0) // RAWKEYDOWN
        // Also send CHAR event for character input
        if let chars = event.characters, !chars.isEmpty {
            inputDelegate?.sendKeyEvent(event, type: 2) // CHAR
        }
    }

    override func keyUp(with event: NSEvent) {
        inputDelegate?.sendKeyEvent(event, type: 1) // KEYUP
    }

    override func flagsChanged(with event: NSEvent) {
        // Determine if this is key down or up based on modifier state
        let type: Int32 = event.modifierFlags.rawValue > 0 ? 0 : 1
        inputDelegate?.sendKeyEvent(event, type: type)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        inputDelegate?.sendFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        inputDelegate?.sendFocus(false)
        return true
    }

    // MARK: - Tracking Area (for mouseMoved)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }
}

// MARK: - Input Delegate Protocol

protocol CEFSurfaceInputDelegate: AnyObject {
    func sendMouseClick(x: Int32, y: Int32, button: Int32, mouseUp: Bool,
                        clickCount: Int32, modifiers: UInt32)
    func sendMouseMove(x: Int32, y: Int32, mouseLeave: Bool, modifiers: UInt32)
    func sendMouseWheel(x: Int32, y: Int32, deltaX: Int32, deltaY: Int32, modifiers: UInt32)
    func sendKeyEvent(_ event: NSEvent, type: Int32)
    func sendFocus(_ focused: Bool)
}

// MARK: - Modifier Flags

enum CEFModifiers {
    // CEF modifier flag constants (from cef_types.h)
    static let shiftDown: UInt32     = 1 << 1
    static let controlDown: UInt32   = 1 << 2
    static let altDown: UInt32       = 1 << 3
    static let commandDown: UInt32   = 1 << 7
    static let leftMouseButton: UInt32  = 1 << 4
    static let middleMouseButton: UInt32 = 1 << 5
    static let rightMouseButton: UInt32 = 1 << 6

    static func from(_ event: NSEvent) -> UInt32 {
        var m: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.shift)   { m |= shiftDown }
        if flags.contains(.control) { m |= controlDown }
        if flags.contains(.option)  { m |= altDown }
        if flags.contains(.command) { m |= commandDown }
        let buttons = NSEvent.pressedMouseButtons
        if buttons & (1 << 0) != 0 { m |= leftMouseButton }
        if buttons & (1 << 1) != 0 { m |= rightMouseButton }
        if buttons & (1 << 2) != 0 { m |= middleMouseButton }
        return m
    }
}
