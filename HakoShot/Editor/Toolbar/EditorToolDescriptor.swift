import Foundation
import HakoKit

/// Title + SF Symbol + shortcut for each editor tool, in toolbar order.
struct EditorToolDescriptor: Identifiable, Equatable {
    let tool: AnnotationTool
    let title: String
    let symbol: String

    var id: AnnotationTool { tool }
    var shortcut: String { String(tool.shortcutKey).uppercased() }
    var help: String { "\(title) (\(shortcut))" }

    /// Drawing tools after the divider
    /// (report §9.1: select, rectangle, filled rectangle, ellipse, line, arrow,
    /// text, pixelate, counter, draw), plus highlighter and spotlight.
    static let drawingTools: [EditorToolDescriptor] = [
        .init(tool: .move, title: "Move", symbol: "cursorarrow"),
        .init(tool: .rectangle, title: "Rectangle", symbol: "rectangle"),
        .init(tool: .filledRectangle, title: "Filled Rectangle", symbol: "rectangle.fill"),
        .init(tool: .ellipse, title: "Ellipse", symbol: "circle"),
        .init(tool: .line, title: "Line", symbol: "line.diagonal"),
        .init(tool: .arrow, title: "Arrow", symbol: "arrow.up.right"),
        .init(tool: .text, title: "Text", symbol: "textformat"),
        .init(tool: .redaction, title: "Redact", symbol: "checkerboard.rectangle"),
        .init(tool: .counter, title: "Counter", symbol: "1.circle"),
        .init(tool: .pencil, title: "Draw", symbol: "pencil.and.scribble"),
        .init(tool: .highlighter, title: "Highlighter", symbol: "highlighter"),
        .init(tool: .spotlight, title: "Spotlight", symbol: "flashlight.on.fill"),
    ]

    /// Canvas tools in the capsule group left of the divider (M5; shown disabled).
    static let canvasTools: [EditorToolDescriptor] = [
        .init(tool: .crop, title: "Crop", symbol: "crop"),
        .init(tool: .background, title: "Background", symbol: "photo.artframe"),
    ]

    static func descriptor(for tool: AnnotationTool) -> EditorToolDescriptor {
        (drawingTools + canvasTools).first { $0.tool == tool }
            ?? EditorToolDescriptor(tool: tool, title: tool.rawValue.capitalized, symbol: "questionmark")
    }
}

extension ArrowStyle {
    var title: String {
        switch self {
        case .standard: "Standard"
        case .curved: "Curved"
        case .thick: "Thick"
        case .doubleHeaded: "Double-Headed"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "arrow.up.right"
        case .curved: "arrow.turn.up.right"
        case .thick: "arrowshape.right.fill"
        case .doubleHeaded: "arrow.left.and.right"
        }
    }
}

extension TextStyle {
    var title: String {
        switch self {
        case .standard: "Standard"
        case .rounded: "Rounded"
        case .monospaced: "Monospaced"
        case .outlined: "Outlined"
        case .boxed: "Boxed"
        case .roundBoxed: "Round Boxed"
        case .monospacedBoxed: "Monospaced Boxed"
        }
    }
}

extension TextAlignmentMode {
    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}

extension CounterStyle {
    var title: String {
        switch self {
        case .filledCircle: "Filled Circle"
        case .outlinedCircle: "Outlined Circle"
        case .filledSquare: "Filled Square"
        }
    }

    var symbol: String {
        switch self {
        case .filledCircle: "1.circle.fill"
        case .outlinedCircle: "1.circle"
        case .filledSquare: "1.square.fill"
        }
    }
}

extension RedactionMethod {
    var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .secureBlur: "Secure Blur"
        case .smoothBlur: "Smooth Blur (not secure)"
        case .blackOut: "Black Out"
        }
    }

    var shortTitle: String {
        switch self {
        case .pixelate: "Pixelate"
        case .secureBlur: "Secure Blur"
        case .smoothBlur: "Smooth Blur"
        case .blackOut: "Black Out"
        }
    }
}
