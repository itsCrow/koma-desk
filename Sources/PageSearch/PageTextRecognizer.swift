import Foundation
import Vision

/// Reads the lettering off a page with the system's on-device OCR.
public enum PageTextRecognizer {
    /// Reads one page. Slow — on the order of a second — and meant to be run
    /// off the main thread, one page at a time, at low priority.
    public static func recognise(_ url: URL, languages: [String] = ["en-US"]) throws -> PageText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        try VNImageRequestHandler(url: url, options: [:]).perform([request])

        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextLine(text: text, box: observation.boundingBox)
        }
        return PageText(lines: lines)
    }
}
