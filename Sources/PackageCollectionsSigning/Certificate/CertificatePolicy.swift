/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Dispatch
import struct Foundation.Data
import struct Foundation.Date
import class Foundation.FileManager
import struct Foundation.URL

import Basics
import TSCBasic

#if canImport(Security)
import Security
#else
@_implementationOnly import CCryptoBoringSSL
@_implementationOnly import PackageCollectionsSigningLibc
#endif

protocol CertificatePolicy {
    /// Validates the given certificate chain.
    ///
    /// - Parameters:
    ///   - certChainPaths: Paths to each certificate in the chain. The certificate being verified must be the first element of the array,
    ///                     with its issuer the next element and so on, and the root CA certificate is last.
    ///   - callback: The callback to invoke when the result is available.
    func validate(certChain: [Certificate], callback: @escaping (Result<Void, Error>) -> Void)
}

extension CertificatePolicy {
    #if !canImport(Security)
    typealias BoringSSLVerifyCallback = @convention(c) (CInt, UnsafeMutablePointer<X509_STORE_CTX>?) -> CInt
    #endif

    #if canImport(Security)
    /// Verifies a certificate chain.
    ///
    /// - Parameters:
    ///   - certChain: The entire certificate chain. The certificate being verified must be the first element of the array.
    ///   - anchorCerts: On Apple platforms, these are root certificates to trust **in addition** to the operating system's trust store.
    ///                  On other platforms, these are the **only** root certificates to be trusted.
    ///   - verifyDate: Overrides the timestamp used for checking certificate expiry (e.g., for testing). By default the current time is used.
    ///   - diagnosticsEngine: The `DiagnosticsEngine` for emitting warnings and errors
    ///   - callbackQueue: The `DispatchQueue` to use for callbacks
    ///   - callback: The callback to invoke when the result is available.
    func verify(certChain: [Certificate],
                anchorCerts: [Certificate]?,
                verifyDate: Date? = nil,
                diagnosticsEngine: DiagnosticsEngine,
                callbackQueue: DispatchQueue,
                callback: @escaping (Result<Void, Error>) -> Void) {
        let wrappedCallback: (Result<Void, Error>) -> Void = { result in callbackQueue.async { callback(result) } }

        guard !certChain.isEmpty else {
            return wrappedCallback(.failure(CertificatePolicyError.emptyCertChain))
        }

        let policy = SecPolicyCreateBasicX509()
        let revocationPolicy = SecPolicyCreateRevocation(kSecRevocationOCSPMethod)

        var secTrust: SecTrust?
        guard SecTrustCreateWithCertificates(certChain.map { $0.underlying } as CFArray,
                                             [policy, revocationPolicy] as CFArray,
                                             &secTrust) == errSecSuccess,
            let trust = secTrust else {
            return wrappedCallback(.failure(CertificatePolicyError.trustSetupFailure))
        }

        if let anchorCerts = anchorCerts {
            SecTrustSetAnchorCertificates(trust, anchorCerts.map { $0.underlying } as CFArray)
        }
        if let verifyDate = verifyDate {
            SecTrustSetVerifyDate(trust, verifyDate as CFDate)
        }

        callbackQueue.async {
            // This automatically searches the user's keychain and system's store for any needed
            // certificates. Passing the entire cert chain is optional and is an optimization.
            SecTrustEvaluateAsyncWithError(trust, callbackQueue) { _, isTrusted, _ in
                guard isTrusted else {
                    return wrappedCallback(.failure(CertificatePolicyError.invalidCertChain))
                }
                wrappedCallback(.success(()))
            }
        }
    }

    #else
    /// Verifies a certificate chain.
    ///
    /// - Parameters:
    ///   - certChain: The entire certificate chain. The certificate being verified must be the first element of the array.
    ///   - anchorCerts: On Apple platforms, these are root certificates to trust **in addition** to the operating system's trust store.
    ///                  On other platforms, these are the **only** root certificates to be trusted.
    ///   - verifyDate: Overrides the timestamp used for checking certificate expiry (e.g., for testing). By default the current time is used.
    ///   - httpClient: HTTP client for OCSP requests
    ///   - diagnosticsEngine: The `DiagnosticsEngine` for emitting warnings and errors
    ///   - callbackQueue: The `DispatchQueue` to use for callbacks
    ///   - callback: The callback to invoke when the result is available.
    func verify(certChain: [Certificate],
                anchorCerts: [Certificate]? = nil,
                verifyDate: Date? = nil,
                httpClient: HTTPClient?,
                diagnosticsEngine: DiagnosticsEngine,
                callbackQueue: DispatchQueue,
                callback: @escaping (Result<Void, Error>) -> Void) {
        let wrappedCallback: (Result<Void, Error>) -> Void = { result in callbackQueue.async { callback(result) } }

        guard !certChain.isEmpty else {
            return wrappedCallback(.failure(CertificatePolicyError.emptyCertChain))
        }
        guard let anchorCerts = anchorCerts, !anchorCerts.isEmpty else {
            return wrappedCallback(.failure(CertificatePolicyError.noTrustedRootCertsConfigured))
        }

        // Cert chain
        let x509Stack = CCryptoBoringSSL_sk_X509_new_null()
        defer { CCryptoBoringSSL_sk_X509_free(x509Stack) }

        certChain[1...].forEach { certificate in
            guard CCryptoBoringSSL_sk_X509_push(x509Stack, certificate.underlying) > 0 else {
                return wrappedCallback(.failure(CertificatePolicyError.trustSetupFailure))
            }
        }

        // Trusted certs
        let x509Store = CCryptoBoringSSL_X509_STORE_new()
        defer { CCryptoBoringSSL_X509_STORE_free(x509Store) }

        let x509StoreCtx = CCryptoBoringSSL_X509_STORE_CTX_new()
        defer { CCryptoBoringSSL_X509_STORE_CTX_free(x509StoreCtx) }

        guard CCryptoBoringSSL_X509_STORE_CTX_init(x509StoreCtx, x509Store, certChain.first!.underlying, x509Stack) == 1 else { // !-safe since certChain cannot be empty
            return wrappedCallback(.failure(CertificatePolicyError.trustSetupFailure))
        }
        CCryptoBoringSSL_X509_STORE_CTX_set_purpose(x509StoreCtx, X509_PURPOSE_ANY)

        anchorCerts.forEach {
            CCryptoBoringSSL_X509_STORE_add_cert(x509Store, $0.underlying)
        }

        var ctxFlags: CInt = 0
        if let verifyDate = verifyDate {
            CCryptoBoringSSL_X509_STORE_CTX_set_time(x509StoreCtx, 0, numericCast(Int(verifyDate.timeIntervalSince1970)))
            ctxFlags = ctxFlags | X509_V_FLAG_USE_CHECK_TIME
        }
        CCryptoBoringSSL_X509_STORE_CTX_set_flags(x509StoreCtx, UInt(ctxFlags))

        let verifyCallback: BoringSSLVerifyCallback = { result, ctx in
            // Success
            if result == 1 { return result }

            // Custom error handling
            let errorCode = CCryptoBoringSSL_X509_STORE_CTX_get_error(ctx)
            // Certs could have unknown critical extensions and cause them to be rejected.
            // Instead of disabling all critical extension checks with X509_V_FLAG_IGNORE_CRITICAL
            // we will just ignore this specific error.
            if errorCode == X509_V_ERR_UNHANDLED_CRITICAL_EXTENSION {
                return 1
            }
            return result
        }
        CCryptoBoringSSL_X509_STORE_CTX_set_verify_cb(x509StoreCtx, verifyCallback)

        guard CCryptoBoringSSL_X509_verify_cert(x509StoreCtx) == 1 else {
            let error = CCryptoBoringSSL_X509_verify_cert_error_string(numericCast(CCryptoBoringSSL_X509_STORE_CTX_get_error(x509StoreCtx)))
            diagnosticsEngine.emit(warning: "The certificate is invalid: \(String(describing: error))")
            return wrappedCallback(.failure(CertificatePolicyError.invalidCertChain))
        }

        if certChain.count >= 1, let httpClient = httpClient {
            // Whether cert chain can be trusted depends on OCSP result
            self.BoringSSL_OCSP_isGood(certificate: certChain[0], issuer: certChain[1], httpClient: httpClient, callbackQueue: callbackQueue, callback: callback)
        } else {
            wrappedCallback(.success(()))
        }
    }

    private func BoringSSL_OCSP_isGood(certificate: Certificate,
                                       issuer: Certificate,
                                       httpClient: HTTPClient,
                                       callbackQueue: DispatchQueue,
                                       callback: @escaping (Result<Void, Error>) -> Void) {
        let wrappedCallback: (Result<Void, Error>) -> Void = { result in callbackQueue.async { callback(result) } }

        let ocspURLs = CCryptoBoringSSL_X509_get1_ocsp(certificate.underlying)
        defer { CCryptoBoringSSL_sk_OPENSSL_STRING_free(ocspURLs) }

        let ocspURLCount = CCryptoBoringSSL_sk_OPENSSL_STRING_num(ocspURLs)
        // Nothing to do if no OCSP URLs. Use `supportsOCSP` to require OCSP support if needed.
        guard ocspURLCount > 0 else { return wrappedCallback(.success(())) }

        // Construct the OCSP request
        let digest = CCryptoBoringSSL_EVP_sha1()
        guard let certid = OCSP_cert_to_id(digest, certificate.underlying, issuer.underlying),
            let request = OCSP_REQUEST_new(),
            OCSP_request_add0_id(request, certid) != nil else {
            return wrappedCallback(.failure(CertificatePolicyError.ocspSetupFailure))
        }
        defer { OCSP_REQUEST_free(request) }

        // Write the request binary to memory bio
        guard let bio = CCryptoBoringSSL_BIO_new(CCryptoBoringSSL_BIO_s_mem()),
            i2d_OCSP_REQUEST_bio(bio, request) > 0 else {
            return wrappedCallback(.failure(CertificatePolicyError.ocspSetupFailure))
        }
        defer { CCryptoBoringSSL_BIO_free(bio) }

        // Copy from bio to byte array then convert to Data
        var count = 0
        let out = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: 1)
        guard CCryptoBoringSSL_BIO_mem_contents(bio, out, &count) > 0 else {
            return wrappedCallback(.failure(CertificatePolicyError.ocspSetupFailure))
        }

        let requestData = Data(UnsafeBufferPointer(start: out.pointee, count: count))

        let results = ThreadSafeArrayStore<Bool>()
        let group = DispatchGroup()

        // Query each OCSP responder and record result
        for index in 0 ..< ocspURLCount {
            guard let urlStr = CCryptoBoringSSL_sk_OPENSSL_STRING_value(ocspURLs, numericCast(index)),
                let url = String(validatingUTF8: urlStr).flatMap({ URL(string: $0) }) else {
                continue
            }

            var headers = HTTPClientHeaders()
            headers.add(name: "Content-Type", value: "application/ocsp-request")
            url.host.map { headers.add(name: "Host", value: "\($0)") }

            var options = HTTPClientRequest.Options()
            options.validResponseCodes = [200]

            group.enter()
            httpClient.post(url, body: requestData, headers: headers, options: options) { result in
                defer { group.leave() }

                switch result {
                case .failure:
                    return
                case .success(let response):
                    guard let responseData = response.body else { return }

                    let bytes = responseData.copyBytes()
                    // Convert response to bio then OCSP response
                    guard let bio = CCryptoBoringSSL_BIO_new(CCryptoBoringSSL_BIO_s_mem()),
                        CCryptoBoringSSL_BIO_write(bio, bytes, numericCast(bytes.count)) > 0,
                        let response = d2i_OCSP_RESPONSE_bio(bio, nil) else {
                        return
                    }
                    defer { CCryptoBoringSSL_BIO_free(bio) }
                    defer { OCSP_RESPONSE_free(response) }

                    // This is just the OCSP response status, not the certificate's status
                    guard OCSP_response_status(response) == OCSP_RESPONSE_STATUS_SUCCESSFUL,
                        CCryptoBoringSSL_OBJ_obj2nid(response.pointee.responseBytes.pointee.responseType) == NID_id_pkix_OCSP_basic,
                        let basicResp = OCSP_response_get1_basic(response),
                        let basicRespData = basicResp.pointee.tbsResponseData?.pointee else {
                        return
                    }
                    defer { OCSP_BASICRESP_free(basicResp) }

                    // Inspect the OCSP response
                    for i in 0 ..< sk_OCSP_SINGLERESP_num(basicRespData.responses) {
                        guard let singleResp = sk_OCSP_SINGLERESP_value(basicRespData.responses, numericCast(i)),
                            let certStatus = singleResp.pointee.certStatus else {
                            continue
                        }

                        // Is the certificate in good status?
                        results.append(certStatus.pointee.type == V_OCSP_CERTSTATUS_GOOD)
                        break
                    }
                }
            }
        }

        group.notify(queue: callbackQueue) {
            // If there's no result then something must have gone wrong
            guard !results.isEmpty else {
                return wrappedCallback(.failure(CertificatePolicyError.ocspFailure))
            }
            // Is there response "bad status" response?
            guard results.get().first(where: { !$0 }) == nil else {
                return wrappedCallback(.failure(CertificatePolicyError.invalidCertChain))
            }
            wrappedCallback(.success(()))
        }
    }
    #endif
}

// MARK: - Supporting methods and types

extension CertificatePolicy {
    func hasExtension(oid: String, in certificate: Certificate) throws -> Bool {
        #if canImport(Security)
        guard let dict = SecCertificateCopyValues(certificate.underlying, [oid as CFString] as CFArray, nil) as? [CFString: Any] else {
            throw CertificatePolicyError.extensionFailure
        }
        return !dict.isEmpty
        #else
        let nid = CCryptoBoringSSL_OBJ_create(oid, "ObjectShortName", "ObjectLongName")
        let index = CCryptoBoringSSL_X509_get_ext_by_NID(certificate.underlying, nid, -1)
        return index >= 0
        #endif
    }

    func hasExtendedKeyUsage(_ usage: CertificateExtendedKeyUsage, in certificate: Certificate) throws -> Bool {
        #if canImport(Security)
        guard let dict = SecCertificateCopyValues(certificate.underlying, [kSecOIDExtendedKeyUsage] as CFArray, nil) as? [CFString: Any] else {
            throw CertificatePolicyError.extensionFailure
        }
        guard let usageDict = dict[kSecOIDExtendedKeyUsage] as? [CFString: Any],
            let usages = usageDict[kSecPropertyKeyValue] as? [Data] else {
            return false
        }
        return usages.first(where: { $0 == usage.data }) != nil
        #else
        let eku = CCryptoBoringSSL_X509_get_extended_key_usage(certificate.underlying)
        return eku & UInt32(usage.flag) > 0
        #endif
    }

    /// Checks that the certificate supports OCSP. This **must** be done before calling `verify` to ensure
    /// the necessary properties are in place to trigger revocation check.
    func supportsOCSP(certificate: Certificate) throws -> Bool {
        #if canImport(Security)
        // Check that certificate has "Certificate Authority Information Access" extension and includes OCSP as access method.
        // The actual revocation check will be done by the Security framework in `verify`.
        guard let dict = SecCertificateCopyValues(certificate.underlying, [kSecOIDAuthorityInfoAccess] as CFArray, nil) as? [CFString: Any] else { // ignore error
            throw CertificatePolicyError.extensionFailure
        }
        guard let infoAccessDict = dict[kSecOIDAuthorityInfoAccess] as? [CFString: Any],
            let infoAccessValue = infoAccessDict[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return false
        }
        return infoAccessValue.first(where: { valueDict in valueDict[kSecPropertyKeyValue] as? String == "1.3.6.1.5.5.7.48.1" }) != nil
        #else
        // Check that there is at least one OCSP responder URL, in which case OCSP check will take place in `verify`.
        let ocspURLs = CCryptoBoringSSL_X509_get1_ocsp(certificate.underlying)
        defer { CCryptoBoringSSL_sk_OPENSSL_STRING_free(ocspURLs) }

        return CCryptoBoringSSL_sk_OPENSSL_STRING_num(ocspURLs) > 0
        #endif
    }
}

enum CertificateExtendedKeyUsage {
    case codeSigning

    #if canImport(Security)
    var data: Data {
        switch self {
        case .codeSigning:
            // https://stackoverflow.com/questions/49489591/how-to-extract-or-compare-ksecpropertykeyvalue-from-seccertificate
            // https://github.com/google/der-ascii/blob/cd91cb85bb0d71e4611856e4f76f5110609d7e42/cmd/der2ascii/oid_names.go#L100
            return Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03])
        }
    }

    #else
    var flag: CInt {
        switch self {
        case .codeSigning:
            // https://www.openssl.org/docs/man1.1.0/man3/X509_get_extension_flags.html
            return XKU_CODE_SIGN
        }
    }
    #endif
}

extension CertificatePolicy {
    static func loadCerts(at directory: URL, diagnosticsEngine: DiagnosticsEngine) -> [Certificate] {
        var certs = [Certificate]()
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                do {
                    certs.append(try Certificate(derEncoded: Data(contentsOf: fileURL)))
                } catch {
                    diagnosticsEngine.emit(warning: "The certificate \(fileURL) is invalid: \(error)")
                }
            }
        }
        return certs
    }
}

enum CertificatePolicyError: Error, Equatable {
    case emptyCertChain
    case trustSetupFailure
    case invalidCertChain
    case subjectUserIDMismatch
    case codeSigningCertRequired
    case ocspSupportRequired
    case unexpectedCertChainLength
    case missingRequiredExtension
    case extensionFailure
    case noTrustedRootCertsConfigured
    case ocspSetupFailure
    case ocspFailure
}

// MARK: - Certificate policies

/// Default policy for validating certificates used to sign package collections.
///
/// Certificates must satisfy these conditions:
///   - The timestamp at which signing/verification is done must fall within the signing certificate’s validity period.
///   - The certificate’s “Extended Key Usage” extension must include “Code Signing”.
///   - The certificate must use either 256-bit EC (recommended) or 2048-bit RSA key.
///   - The certificate must not be revoked. The certificate authority must support OCSP, which means the certificate must have the
///   "Certificate Authority Information Access" extension that includes OCSP as a method, specifying the responder’s URL.
///   - The certificate chain is valid and root certificate must be trusted.
struct DefaultCertificatePolicy: CertificatePolicy {
    let trustedRoots: [Certificate]?
    let expectedSubjectUserID: String?

    private let callbackQueue: DispatchQueue
    private let diagnosticsEngine: DiagnosticsEngine

    #if !canImport(Security)
    private let httpClient: HTTPClient
    #endif

    /// Initializes a `DefaultCertificatePolicy`.
    /// - Parameters:
    ///   - trustedRootCertsDir: On Apple platforms, all root certificates that come preinstalled with the OS are automatically trusted.
    ///                          Users may specify additional certificates to trust by placing them in `trustedRootCertsDir` and
    ///                          configure the signing tool or SwiftPM to use it. On non-Apple platforms, only trust root certificates in
    ///                          `trustedRootCertsDir` are trusted.
    ///   - expectedSubjectUserID: The subject user ID that must match if specified.
    ///   - callbackQueue: The `DispatchQueue` to use for callbacks
    ///   - diagnosticsEngine: The `DiagnosticsEngine` for emitting warnings and errors.
    init(trustedRootCertsDir: URL? = nil, expectedSubjectUserID: String? = nil, callbackQueue: DispatchQueue, diagnosticsEngine: DiagnosticsEngine) {
        self.trustedRoots = trustedRootCertsDir.map { Self.loadCerts(at: $0, diagnosticsEngine: diagnosticsEngine) }
        self.expectedSubjectUserID = expectedSubjectUserID
        self.callbackQueue = callbackQueue
        self.diagnosticsEngine = diagnosticsEngine

        #if !canImport(Security)
        var httpClientConfig = HTTPClientConfiguration()
        httpClientConfig.callbackQueue = callbackQueue
        self.httpClient = HTTPClient(configuration: httpClientConfig)
        #endif
    }

    func validate(certChain: [Certificate], callback: @escaping (Result<Void, Error>) -> Void) {
        let wrappedCallback: (Result<Void, Error>) -> Void = { result in self.callbackQueue.async { callback(result) } }

        guard !certChain.isEmpty else {
            return wrappedCallback(.failure(CertificatePolicyError.emptyCertChain))
        }

        do {
            // Check if subject user ID matches
            if let expectedSubjectUserID = self.expectedSubjectUserID {
                guard try certChain[0].subject().userID == expectedSubjectUserID else {
                    return wrappedCallback(.failure(CertificatePolicyError.subjectUserIDMismatch))
                }
            }

            // Must be a code signing certificate
            guard try self.hasExtendedKeyUsage(.codeSigning, in: certChain[0]) else {
                return wrappedCallback(.failure(CertificatePolicyError.codeSigningCertRequired))
            }
            // Must support OCSP
            guard try self.supportsOCSP(certificate: certChain[0]) else {
                return wrappedCallback(.failure(CertificatePolicyError.ocspSupportRequired))
            }

            // Verify the cert chain - if it is trusted then cert chain is valid
            #if canImport(Security)
            self.verify(certChain: certChain, anchorCerts: self.trustedRoots, diagnosticsEngine: self.diagnosticsEngine, callbackQueue: self.callbackQueue, callback: callback)
            #else
            self.verify(certChain: certChain, anchorCerts: self.trustedRoots, httpClient: self.httpClient, diagnosticsEngine: self.diagnosticsEngine, callbackQueue: self.callbackQueue, callback: callback)
            #endif
        } catch {
            return wrappedCallback(.failure(error))
        }
    }
}

/// Policy for validating developer.apple.com certificates.
///
/// This has the same requirements as `DefaultCertificatePolicy` plus additional
/// marker extensions for Apple Distribution certifiications.
struct AppleDeveloperCertificatePolicy: CertificatePolicy {
    private static let expectedCertChainLength = 3
    private static let appleDistributionIOSMarker = "1.2.840.113635.100.6.1.4"
    private static let appleDistributionMacOSMarker = "1.2.840.113635.100.6.1.7"
    private static let appleIntermediateMarker = "1.2.840.113635.100.6.2.1"

    let trustedRoots: [Certificate]?
    let expectedSubjectUserID: String?

    private let callbackQueue: DispatchQueue
    private let diagnosticsEngine: DiagnosticsEngine

    #if !canImport(Security)
    private let httpClient: HTTPClient
    #endif

    /// Initializes a `AppleDeveloperCertificatePolicy`.
    /// - Parameters:
    ///   - trustedRootCertsDir: On Apple platforms, all root certificates that come preinstalled with the OS are automatically trusted.
    ///                          Users may specify additional certificates to trust by placing them in `trustedRootCertsDir` and
    ///                          configure the signing tool or SwiftPM to use it. On non-Apple platforms, only trust root certificates in
    ///                          `trustedRootCertsDir` are trusted.
    ///   - expectedSubjectUserID: The subject user ID that must match if specified.
    ///   - callbackQueue: The `DispatchQueue` to use for callbacks
    ///   - diagnosticsEngine: The `DiagnosticsEngine` for emitting warnings and errors.
    init(trustedRootCertsDir: URL? = nil, expectedSubjectUserID: String? = nil, callbackQueue: DispatchQueue, diagnosticsEngine: DiagnosticsEngine) {
        self.trustedRoots = trustedRootCertsDir.map { Self.loadCerts(at: $0, diagnosticsEngine: diagnosticsEngine) }
        self.expectedSubjectUserID = expectedSubjectUserID
        self.callbackQueue = callbackQueue
        self.diagnosticsEngine = diagnosticsEngine

        #if !canImport(Security)
        var httpClientConfig = HTTPClientConfiguration()
        httpClientConfig.callbackQueue = callbackQueue
        self.httpClient = HTTPClient(configuration: httpClientConfig)
        #endif
    }

    func validate(certChain: [Certificate], callback: @escaping (Result<Void, Error>) -> Void) {
        let wrappedCallback: (Result<Void, Error>) -> Void = { result in self.callbackQueue.async { callback(result) } }

        guard !certChain.isEmpty else {
            return wrappedCallback(.failure(CertificatePolicyError.emptyCertChain))
        }
        // developer.apple.com cert chain is always 3-long
        guard certChain.count == Self.expectedCertChainLength else {
            return wrappedCallback(.failure(CertificatePolicyError.unexpectedCertChainLength))
        }

        do {
            // Check if subject user ID matches
            if let expectedSubjectUserID = self.expectedSubjectUserID {
                guard try certChain[0].subject().userID == expectedSubjectUserID else {
                    return wrappedCallback(.failure(CertificatePolicyError.subjectUserIDMismatch))
                }
            }

            // Check marker extensions (certificates issued post WWDC 2019 have both extensions but earlier ones have just one depending on platform)
            guard try (self.hasExtension(oid: Self.appleDistributionIOSMarker, in: certChain[0]) || self.hasExtension(oid: Self.appleDistributionMacOSMarker, in: certChain[0])) else {
                return wrappedCallback(.failure(CertificatePolicyError.missingRequiredExtension))
            }
            guard try self.hasExtension(oid: Self.appleIntermediateMarker, in: certChain[1]) else {
                return wrappedCallback(.failure(CertificatePolicyError.missingRequiredExtension))
            }

            // Must be a code signing certificate
            guard try self.hasExtendedKeyUsage(.codeSigning, in: certChain[0]) else {
                return wrappedCallback(.failure(CertificatePolicyError.codeSigningCertRequired))
            }
            // Must support OCSP
            guard try self.supportsOCSP(certificate: certChain[0]) else {
                return wrappedCallback(.failure(CertificatePolicyError.ocspSupportRequired))
            }

            // Verify the cert chain - if it is trusted then cert chain is valid
            #if canImport(Security)
            self.verify(certChain: certChain, anchorCerts: self.trustedRoots, diagnosticsEngine: self.diagnosticsEngine, callbackQueue: self.callbackQueue, callback: callback)
            #else
            self.verify(certChain: certChain, anchorCerts: self.trustedRoots, httpClient: self.httpClient, diagnosticsEngine: self.diagnosticsEngine, callbackQueue: self.callbackQueue, callback: callback)
            #endif
        } catch {
            return wrappedCallback(.failure(error))
        }
    }
}

public enum CertificatePolicyKey: Equatable, Hashable {
    case `default`(subjectUserID: String?)
    case appleDistribution(subjectUserID: String?)

    /// For internal-use only
    case custom

    public static let `default` = CertificatePolicyKey.default(subjectUserID: nil)
    public static let appleDistribution = CertificatePolicyKey.appleDistribution(subjectUserID: nil)
}
