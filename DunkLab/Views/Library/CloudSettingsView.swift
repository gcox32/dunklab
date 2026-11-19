import OSLog
import SwiftData
import SwiftUI

/// Where clips are backed up: the bucket, the key to reach it, and how much is where.
struct CloudSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var clips: [Clip]
    @AppStorage(CloudConfig.bucketKey) private var bucket = CloudConfig.defaultBucket
    @AppStorage(CloudConfig.regionKey) private var region = CloudConfig.defaultRegion

    @State private var keyID = ""
    @State private var secret = ""
    @State private var hasKey = CloudConfig.hasKey
    @State private var testing = false
    @State private var testResult: Result<Void, Error>?
    @State private var testedAt: Date?
    @State private var confirmFree = false

    private var sync: ClipSync { ClipSync.shared }

    private var pending: Int { clips.filter { $0.uploadState != .uploaded }.count }
    private var uploaded: [Clip] { clips.filter { $0.uploadState == .uploaded } }
    private var freeable: [Clip] { uploaded.filter(\.hasLocalFile) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Clips", value: "\(clips.count)")
                LabeledContent("In the cloud", value: "\(uploaded.count)")
                LabeledContent("Waiting to upload", value: "\(pending)")
                LabeledContent("Videos on this phone", value: Self.bytes(clips.filter(\.hasLocalFile)))
                if sync.isSyncing {
                    HStack { Text("Uploading…"); Spacer(); ProgressView() }
                } else if hasKey && pending > 0 {
                    Button("Upload now") { Task { await sync.retryFailed(context) } }
                }
                if !freeable.isEmpty {
                    Button("Remove phone copies of uploaded clips") { confirmFree = true }
                }
            } header: {
                SectionTitle("Library")
            } footer: {
                if let error = sync.lastError {
                    Text("Last upload failed: \(error)").foregroundStyle(Palette.vaneRed)
                } else {
                    Text("Clips upload on their own when the app opens and after a session. Once uploaded, a clip's phone copy clears \(ClipSync.keepLocalDays) days after you last open it, unless it's starred; it then plays from the cloud.")
                }
            }

            Section {
                TextField("Bucket", text: $bucket)
                TextField("Region", text: $region)
            } header: {
                SectionTitle("Bucket")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Section {
                if hasKey {
                    LabeledContent("Access key", value: CloudConfig.maskedKeyID ?? "Saved")
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                        .disabled(testing)
                    testRow
                    Button("Forget key", role: .destructive) {
                        CloudConfig.forgetKey()
                        hasKey = false
                        testResult = nil
                    }
                } else {
                    TextField("Access key ID", text: $keyID)
                    SecureField("Secret access key", text: $secret)
                    Button("Save key") {
                        CloudConfig.saveKey(id: keyID, secret: secret)
                        keyID = ""
                        secret = ""
                        hasKey = true
                        Task { await test() }
                    }
                    .disabled(keyID.isEmpty || secret.isEmpty)
                }
            } header: {
                SectionTitle("Key")
            } footer: {
                Text("The IAM user's key, limited to this bucket's \(CloudConfig.prefix) folder. Kept in this phone's Keychain only.")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .navigationTitle("Clip storage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(freeable.count) phone copies?", isPresented: $confirmFree, titleVisibility: .visible) {
            Button("Remove phone copies", role: .destructive) {
                for clip in freeable { sync.removeLocalCopy(clip) }
                try? context.save()
            }
        } message: {
            Text("Frees \(Self.bytes(freeable)). They stay in the cloud and play from there.")
        }
    }

    /// The last test's outcome, left in place until the next one.
    @ViewBuilder private var testRow: some View {
        if let testResult {
            VStack(alignment: .leading, spacing: 4) {
                switch testResult {
                case .success:
                    Label("Connected: can write to \(bucket)/\(CloudConfig.prefix)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.vaneBlue)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Palette.vaneRed)
                        .textSelection(.enabled)
                }
                if let testedAt {
                    Text("Checked \(testedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(Palette.inkSoft)
                }
            }
            .font(.subheadline)
        }
    }

    /// Writes and deletes a tiny object: proves the key, the bucket, the region and the policy.
    private func test() async {
        guard let client = CloudConfig.client else { return }
        testing = true
        defer { testing = false }
        let key = CloudConfig.prefix + ".connection-test"
        do {
            try await client.put(data: Data("ok".utf8), key: key, contentType: "text/plain")
            try await client.delete(key: key)
            testResult = .success(())
            testedAt = .now
            Self.log.info("Connection test passed for \(bucket, privacy: .public)")
            await sync.syncPending(context)
        } catch {
            testResult = .failure(error)
            testedAt = .now
            Self.log.error("Connection test failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "com.grantcox.dunklab", category: "cloud")

    private static func bytes(_ clips: [Clip]) -> String {
        let total = clips.reduce(0) { sum, clip in
            sum + ((try? clip.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
