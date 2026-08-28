import Foundation
import os
import Shared
import VisionServices

/// Reads the captures the agent hands over, for the history index (docs/03 §5 P3,
/// docs/06 M20).
///
/// It runs here, in the helper, for the reason everything Vision-shaped does: OCR means
/// loading models, tens of megabytes that must never appear in the agent and that should
/// die with a process rather than linger in a menu bar app (docs/04 §1, §7 rule 4). When
/// the backlog is finished the helper goes idle and exits, and the cost goes with it.
///
/// It does *only* the recognition. The library — the SQLite file, the retention policy,
/// the writes — belongs to the agent, which is its only writer (docs/04 §9); the agent
/// also decides *when* a pass happens, on mains power and opted in (docs/03 §5: "zero
/// agent idle cost").
struct HistoryTextIndexer {
    private let recognizer = TextRecognizer()
    private let logger = KadrLog.logger(.history)

    /// Indexing wants the words, not the layout: line breaks are folded into spaces so a
    /// phrase that wrapped mid-sentence is still one searchable run, and codes and tables
    /// are skipped because neither is what someone searches their screenshots for.
    private static let options = TextRecognitionOptions(
        preservesLineBreaks: false,
        detectsCodes: false,
        includeRedactionCandidates: false,
        detectsTables: false
    )

    /// Reads one batch. Every item gets a result, including the ones that could not be
    /// read — the alternative is reading the same unreadable file on every pass forever.
    func run(_ request: HistoryIndexRequest) async -> HistoryIndexResponse {
        var results: [HistoryIndexResult] = []
        results.reserveCapacity(request.items.count)

        for item in request.items {
            let text = await text(of: URL(fileURLWithPath: item.path))
            results.append(HistoryIndexResult(id: item.id, text: text))
        }
        logger.info("Read \(results.count, privacy: .public) capture(s) for the index")
        return HistoryIndexResponse(results: results)
    }

    private func text(of url: URL) async -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        guard let analysis = try? await recognizer.analyze(pngData: data, options: Self.options) else {
            return ""
        }
        return analysis.text(preservingLineBreaks: false)
    }
}
