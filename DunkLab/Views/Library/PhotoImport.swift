import PhotosUI
import SwiftData
import SwiftUI

/// Copies picked Photos videos into the library, dated when they were filmed.
/// Used by the library and by a session's page, which links what it imports.
enum PhotoImport {
    struct Result {
        var added: [Clip] = []
        var skipped = 0
        var failures: [String] = []

        /// What to tell the athlete, or nil when there's nothing worth a dialog.
        func note(linkedTo session: PracticeSession?) -> String? {
            var notes: [String] = []
            if skipped > 0 { notes.append("\(skipped) already in the library, skipped.") }
            if !failures.isEmpty { notes.append("\(failures.count) couldn't be imported: \(failures[0])") }
            if added.count > 1 {
                notes.append(session == nil
                    ? "\(added.count) added. Open each to tag it or link it to a session."
                    : "\(added.count) added to this session. Open each to match it to an attempt.")
            }
            return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
        }
    }

    /// Imports each item, skipping videos already in the library. `progress`
    /// gets the index being worked on and the total.
    static func run(_ items: [PhotosPickerItem], linkingTo session: PracticeSession? = nil,
                    into context: ModelContext, progress: (Int, Int) -> Void) async -> Result {
        let existing = Set(((try? context.fetch(FetchDescriptor<Clip>())) ?? []).compactMap(\.sourceAssetID))
        var result = Result()
        for (index, item) in items.enumerated() {
            progress(index, items.count)
            guard let id = item.itemIdentifier, !existing.contains(id) else {
                result.skipped += 1
                continue
            }
            do {
                let video = try await SlowMoLibrary.video(forPickerItem: id, requireSlowMo: false)
                let clip = try await ClipLibrary.importOriginal(
                    video.asset, kind: .attempt, recordedAt: video.recordedAt ?? .now, into: context)
                clip.sourceAssetID = id
                if let session {
                    ClipLibrary.link(clip, to: session, attempt: nil)
                }
                try? context.save()
                result.added.append(clip)
            } catch {
                result.failures.append(error.localizedDescription)
            }
        }
        await ClipSync.shared.syncPending(context)
        return result
    }
}
