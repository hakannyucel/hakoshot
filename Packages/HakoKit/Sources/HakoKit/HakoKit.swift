import Foundation

/// Namespace for HakoKit-wide metadata.
///
/// HakoKit holds HakoShot's pure logic (geometry, naming, export, stitching,
/// annotation model, rendering). It must never import AppKit or SwiftUI so the
/// whole module stays testable with `swift test`.
public enum HakoKit {
    /// Semantic version of the HakoKit module.
    public static let version = "0.1.0"

    /// File extension of editable HakoShot project bundles (plan §4.9).
    public static let projectFileExtension = "hakoshot"

    /// Uniform Type Identifier exported by the app for `.hakoshot` bundles.
    public static let projectTypeIdentifier = "com.hakanyucel.hakoshot.project"
}
