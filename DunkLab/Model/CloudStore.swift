import CryptoKit
import Foundation
import Security

/// Where clips go in the cloud: one private S3 bucket, reached with one IAM
/// user's key. The bucket and region aren't secret and live in UserDefaults;
/// the key lives in the Keychain and never in the source.
nonisolated enum CloudConfig {
    static let bucketKey = "cloud.bucket"
    static let regionKey = "cloud.region"
    static let defaultBucket = "dunklab-bucket"
    static let defaultRegion = "us-east-1"
    /// Every clip's key starts with this, which is all the IAM policy allows.
    static let prefix = "clips/"

    static var bucket: String { UserDefaults.standard.string(forKey: bucketKey) ?? defaultBucket }
    static var region: String { UserDefaults.standard.string(forKey: regionKey) ?? defaultRegion }

    /// A client when a key has been entered, else nil.
    static var client: S3Client? {
        guard let keyID = Keychain.read("s3.accessKeyID"), !keyID.isEmpty,
              let secret = Keychain.read("s3.secretAccessKey"), !secret.isEmpty else { return nil }
        return S3Client(bucket: bucket, region: region, accessKeyID: keyID, secretAccessKey: secret)
    }

    static var hasKey: Bool { Keychain.read("s3.accessKeyID") != nil }

    static func saveKey(id: String, secret: String) {
        Keychain.write(id.trimmingCharacters(in: .whitespacesAndNewlines), for: "s3.accessKeyID")
        Keychain.write(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: "s3.secretAccessKey")
    }

    static func forgetKey() {
        Keychain.delete("s3.accessKeyID")
        Keychain.delete("s3.secretAccessKey")
    }

    static var maskedKeyID: String? {
        guard let id = Keychain.read("s3.accessKeyID"), id.count > 4 else { return nil }
        return "••••" + id.suffix(4)
    }
}

/// Generic passwords for this app, readable after first unlock so uploads can
/// finish with the phone locked.
nonisolated enum Keychain {
    private static let service = "com.grantcox.dunklab.cloud"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) {
        delete(account)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The four S3 calls the library needs, signed with AWS Signature Version 4.
/// Bodies aren't hashed (UNSIGNED-PAYLOAD, fine over HTTPS), so a large clip
/// streams from disk without being read twice.
nonisolated struct S3Client: Sendable {
    let bucket: String
    let region: String
    let accessKeyID: String
    let secretAccessKey: String

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    func put(file: URL, key: String, contentType: String) async throws {
        let request = signed("PUT", key: key, contentType: contentType)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try check(response, data)
    }

    func put(data body: Data, key: String, contentType: String) async throws {
        let request = signed("PUT", key: key, contentType: contentType)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try check(response, data)
    }

    /// Downloads an object to `destination`, replacing anything there.
    func get(key: String, to destination: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(for: signed("GET", key: key))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: temp)) ?? Data()
            try check(response, data)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    func delete(key: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: signed("DELETE", key: key))
        try check(response, data)
    }

    // MARK: Signing

    private var host: String { "\(bucket).s3.\(region).amazonaws.com" }

    func signed(_ method: String, key: String, contentType: String? = nil, now: Date = .now) -> URLRequest {
        let path = "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/")
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 120

        let amzDate = Self.stamp(now, "yyyyMMdd'T'HHmmss'Z'")
        let day = Self.stamp(now, "yyyyMMdd")
        let payload = "UNSIGNED-PAYLOAD"
        request.setValue(payload, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonical = [
            method, path, "",
            "host:\(host)\nx-amz-content-sha256:\(payload)\nx-amz-date:\(amzDate)\n",
            signedHeaders, payload,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")

        let signature = sign(toSign, day: day)
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    /// A link anyone holding it can GET for `expires` seconds, with no headers:
    /// what AVPlayer needs to stream a clip straight from the bucket.
    func presignedGET(key: String, expires: Int = 3600, now: Date = .now) -> URL {
        let path = "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/")
        let amzDate = Self.stamp(now, "yyyyMMdd'T'HHmmss'Z'")
        let day = Self.stamp(now, "yyyyMMdd")
        let scope = "\(day)/\(region)/s3/aws4_request"
        // Already in sorted order, as the canonical query must be.
        let query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKeyID)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ].map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        let canonical = ["GET", path, query, "host:\(host)\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        return URL(string: "https://\(host)\(path)?\(query)&X-Amz-Signature=\(sign(toSign, day: day))")!
    }

    private func sign(_ toSign: String, day: String) -> String {
        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for part in [day, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3986: everything but unreserved characters is escaped.
    private static func encode(_ segment: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? segment
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure(errorDescription: "No response from S3.") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        let code = Self.tag("Code", in: body) ?? "HTTP \(http.statusCode)"
        let message = Self.tag("Message", in: body) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        throw Failure(errorDescription: "\(code): \(message)")
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
