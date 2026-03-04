import Foundation
import Security

/// Generates GCS V2 signed URLs on-device using a service account key.
actor GCSURLSigner {
    static let shared = GCSURLSigner()

    private let bucket = "alakazam-forge-data"
    private let expiration: TimeInterval = 3600 // 1 hour

    private var clientEmail: String?
    private var privateKey: SecKey?
    private var loaded = false

    private init() {}

    /// Generate a signed URL for a GCS object path (e.g. "coreml/index.json").
    func signedURL(for path: String) -> URL? {
        ensureLoaded()
        guard let email = clientEmail, let key = privateKey else { return nil }

        let expiry = Int(Date().timeIntervalSince1970 + expiration)
        let resource = "/\(bucket)/\(path)"

        // V2 signing: StringToSign = HTTP_Verb\n Content-MD5\n Content-Type\n Expiration\n Resource
        let stringToSign = "GET\n\n\n\(expiry)\n\(resource)"

        guard let signature = sign(stringToSign, with: key) else { return nil }

        let b64Signature = signature.base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""

        let urlString = "https://storage.googleapis.com\(resource)"
            + "?GoogleAccessId=\(email)"
            + "&Expires=\(expiry)"
            + "&Signature=\(b64Signature)"

        print("[GCSURLSigner] Signed: \(path) → \(urlString.prefix(120))...")
        return URL(string: urlString)
    }

    /// Fetch data from a signed GCS path.
    func fetchData(path: String) async throws -> Data {
        guard let url = signedURL(for: path) else {
            throw GCSError.invalidURL(path)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw GCSError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    // MARK: - Private

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        loadCredentials()
    }

    private func loadCredentials() {
        guard let url = Bundle.main.url(forResource: "gcs-credentials", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[GCSURLSigner] No credentials file found in bundle")
            return
        }

        clientEmail = json["client_email"] as? String

        guard let pemString = json["private_key"] as? String else { return }
        privateKey = loadRSAKey(from: pemString)

        if privateKey != nil {
            print("[GCSURLSigner] Loaded service account: \(clientEmail ?? "?")")
        }
    }

    private func loadRSAKey(from pem: String) -> SecKey? {
        // Strip PEM headers and decode base64
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")

        guard let pkcs8Data = Data(base64Encoded: stripped) else { return nil }

        // Strip PKCS#8 wrapper to get PKCS#1 RSA key.
        // PKCS#8 = SEQUENCE { version, AlgorithmIdentifier, OCTET STRING { PKCS#1 key } }
        // The PKCS#1 key is inside the OCTET STRING after the fixed RSA algorithm header.
        guard let pkcs1Data = stripPKCS8Header(pkcs8Data) else {
            print("[GCSURLSigner] Failed to strip PKCS#8 header")
            return nil
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]

        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(pkcs1Data as CFData, attributes as CFDictionary, &error)
        if let error = error?.takeRetainedValue() {
            print("[GCSURLSigner] Key import error: \(error)")
        }
        return key
    }

    /// Strip PKCS#8 header to extract the inner PKCS#1 RSA private key.
    private func stripPKCS8Header(_ data: Data) -> Data? {
        // PKCS#8 RSA header bytes: SEQUENCE + version(0) + AlgorithmIdentifier(rsaEncryption) + OCTET STRING
        // We scan for the OCTET STRING tag (0x04) after the algorithm OID
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let bytes = [UInt8](data)

        // Find the RSA OID
        guard let oidRange = bytes.firstRange(of: rsaOID) else { return nil }

        // Skip past OID + NULL (05 00) to find the OCTET STRING (04 ...)
        var idx = oidRange.upperBound
        // Skip NULL if present
        if idx + 2 <= bytes.count && bytes[idx] == 0x05 && bytes[idx + 1] == 0x00 {
            idx += 2
        }

        // Expect OCTET STRING tag (0x04)
        guard idx < bytes.count && bytes[idx] == 0x04 else { return nil }
        idx += 1

        // Parse length
        guard idx < bytes.count else { return nil }
        if bytes[idx] & 0x80 == 0 {
            // Short form length
            idx += 1
        } else {
            // Long form: number of length bytes
            let numLengthBytes = Int(bytes[idx] & 0x7F)
            idx += 1 + numLengthBytes
        }

        guard idx < bytes.count else { return nil }
        return Data(bytes[idx...])
    }

    private func sign(_ string: String, with key: SecKey) -> Data? {
        guard let data = string.data(using: .utf8) else { return nil }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) else {
            if let error = error?.takeRetainedValue() {
                print("[GCSURLSigner] Signing error: \(error)")
            }
            return nil
        }

        return signature as Data
    }
}

private extension CharacterSet {
    /// Characters allowed in URL query values — excludes +, =, /, &, etc.
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+/=&")
        return cs
    }()
}
