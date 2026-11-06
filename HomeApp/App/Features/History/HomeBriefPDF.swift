import Foundation
import CoreGraphics
import CoreText
import HomeCore

private struct BriefProblem: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct HomeBriefPDF {
    /// Build a reviewable document from the whitelisted journal projection; original attachments and notes cannot enter it.
    static func make(from history: [HomeHistoryEntry], selected: Set<UUID>, includeCosts: Bool, includeEvidence: Bool = false, prepared: LocalDate) throws -> Data {
        let projects = history.filter { selected.contains($0.id) }
        guard !projects.isEmpty else { throw BriefProblem("Choose at least one completed project.") }
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let title = "Home improvement brief"
        guard let consumer = CGDataConsumer(data: bytes),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextCreator: "Home Blueprint"] as CFDictionary) else {
            throw BriefProblem("The PDF could not be created. Try again.")
        }
        let ink = CGColor(gray: 0.13, alpha: 1), muted = CGColor(gray: 0.34, alpha: 1)
        func text(_ value: String, font: String, size: CGFloat, color: CGColor) -> NSAttributedString {
            NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ])
        }
        func draw(_ line: NSAttributedString, y: CGFloat) {
            ctx.textPosition = CGPoint(x: 48, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(line), ctx)
        }
        let body = NSMutableAttributedString(string: "")
        for project in projects {
            body.append(text(project.title + "\n", font: "Helvetica-Bold", size: 15, color: ink))
            var facts = [project.date.map { "Completed \($0.description)" } ?? project.completedYear.map { "Completed \($0)" } ?? "Completion date unrecorded"]
            if includeCosts { facts.append(project.actual.map { "Recorded cost \($0.formatted()) \($0.currency)" } ?? "Cost unrecorded") }
            if includeEvidence {
                let files = project.fileCount == 1 ? "1 file" : "\(project.fileCount) files"
                facts.append(project.hasReceipt ? files + " (receipt on file)" : files)
            }
            body.append(text(facts.joined(separator: "   •   ") + "\n\n", font: "Helvetica", size: 12, color: muted))
        }
        let layout = CTFramesetterCreateWithAttributedString(body)
        let area = CGPath(rect: CGRect(x: 48, y: 65, width: 516, height: 580), transform: nil)
        var offset = 0, page = 1
        repeat {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            draw(text("HOME BLUEPRINT", font: "Helvetica-Bold", size: 10, color: muted), y: 743)
            draw(text(title, font: "Georgia", size: 29, color: ink), y: 703)
            draw(text("Owner-reported work  •  Prepared \(prepared.description)", font: "Helvetica", size: 12, color: muted), y: 674)
            let frame = CTFramesetterCreateFrame(layout, CFRange(location: offset, length: 0), area, nil)
            CTFrameDraw(frame, ctx)
            let count = CTFrameGetVisibleStringRange(frame).length
            draw(text("Page \(page)", font: "Helvetica", size: 10, color: muted), y: 39)
            ctx.endPDFPage()
            guard count > 0 else { ctx.closePDF(); throw BriefProblem("This document could not be laid out. Try fewer projects.") }
            offset += count; page += 1
        } while offset < body.length
        ctx.closePDF()
        return bytes as Data
    }
}
