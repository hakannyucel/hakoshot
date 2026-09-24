#if DEBUG
import Foundation
import HakoKit
import os

/// DEBUG: renders a file with a recipe, no UI (plan §7 R3.2,
/// `hakoshot://debug-render?filepath=<src>&recipe=<json>&out=<dst>`).
///
/// `recipe` is a (URL-encoded) partial `VideoEditRecipe` JSON, e.g.
/// `{"trim":{"start":2,"end":7},"crop":{"x":0,"y":0,"width":640,"height":360}}`
/// or `{"format":"gif","gif":{"fps":15,"width":800}}`; missing = `{}`.
/// `passthrough=0` forces re-encoding. The result (or the error) and the
/// elapsed time go to the log (`category: render`).
nonisolated enum RenderDebug {
    struct Parameters: Equatable, Sendable {
        var source: URL
        var recipe: VideoEditRecipe
        var out: URL
        var allowsPassthrough = true

        init(source: URL, recipe: VideoEditRecipe = VideoEditRecipe(), out: URL, allowsPassthrough: Bool = true) {
            self.source = source
            self.recipe = recipe
            self.out = out
            self.allowsPassthrough = allowsPassthrough
        }

        enum ParseError: Error, Equatable {
            case missing(String)
            case invalidRecipe(String)
        }

        /// Keys: `filepath|path`, `recipe`, `out`, `passthrough`.
        init(queryItems: [URLQueryItem]) throws(ParseError) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
            guard let source = Self.fileURL(values["filepath"] ?? values["path"]) else { throw .missing("filepath") }
            guard let out = Self.fileURL(values["out"]) else { throw .missing("out") }
            let json = values["recipe"].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
            let recipe: VideoEditRecipe
            do {
                recipe = try VideoEditRecipe.decode(json: json)
            } catch {
                throw .invalidRecipe(json)
            }
            let passthrough = values["passthrough"].map { !["0", "false", "no"].contains($0.lowercased()) } ?? true
            self.init(source: source, recipe: recipe, out: out, allowsPassthrough: passthrough)
        }

        private static func fileURL(_ path: String?) -> URL? {
            guard let path, !path.isEmpty else { return nil }
            if let url = URL(string: path), url.isFileURL { return url }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
    }

    /// Renders and logs the output path and time; errors are logged too.
    @discardableResult
    static func run(_ parameters: Parameters) async -> URL? {
        let pipeline = parameters.allowsPassthrough ? RenderPipeline.shared : RenderPipeline(allowsPassthrough: false)
        let started = ContinuousClock.now
        do {
            let url = try await pipeline.render(source: parameters.source, recipe: parameters.recipe, to: parameters.out)
            let elapsed = (ContinuousClock.now - started).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            Log.render.notice("debug-render wrote \(url.path, privacy: .public) in \(String(format: "%.2f", seconds), privacy: .public) s")
            return url
        } catch {
            Log.render.error("debug-render failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
