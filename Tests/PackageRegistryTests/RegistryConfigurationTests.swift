//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import PackageModel
import PackageRegistry
import _InternalTestSupport
import XCTest

private let defaultRegistryBaseURL = URL("https://packages.example.com/")
private let customRegistryBaseURL = URL("https://custom.packages.example.com/")

final class RegistryConfigurationTests: XCTestCase {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    func testEmptyConfiguration() throws {
        let configuration = RegistryConfiguration()
        XCTAssertNil(configuration.defaultRegistry)
        XCTAssertEqual(configuration.scopedRegistries, [:])
        XCTAssertEqual(configuration.registryAuthentication, [:])
        XCTAssertNil(configuration.security)
    }

    func testRoundTripCodingForEmptyConfiguration() throws {
        let configuration = RegistryConfiguration()

        let encoded = try encoder.encode(configuration)
        let decoded = try decoder.decode(RegistryConfiguration.self, from: encoded)

        XCTAssertEqual(configuration, decoded)
    }

    func testRoundTripCodingForExampleConfiguration() throws {
        var configuration = RegistryConfiguration()

        configuration.defaultRegistry = .init(url: defaultRegistryBaseURL, supportsAvailability: false)
        configuration.scopedRegistries["foo"] = .init(url: customRegistryBaseURL, supportsAvailability: false)
        configuration.scopedRegistries["bar"] = .init(url: customRegistryBaseURL, supportsAvailability: false)

        configuration.registryAuthentication[defaultRegistryBaseURL.host!] = .init(type: .token)

        var security = RegistryConfiguration.Security()
        // default
        var global = RegistryConfiguration.Security.Global()
        global.signing = RegistryConfiguration.Security.Signing()
        global.signing?.onUnsigned = .error
        global.signing?.onUntrustedCertificate = .error
        global.signing?.trustedRootCertificatesPath = "/shared/roots"
        global.signing?.includeDefaultTrustedRootCertificates = false
        global.signing?.validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
        global.signing?.validationChecks?.certificateExpiration = .enabled
        global.signing?.validationChecks?.certificateRevocation = .strict
        security.default = global
        // registryOverrides
        var registryOverride = RegistryConfiguration.Security.RegistryOverride()
        registryOverride.signing = RegistryConfiguration.Security.Signing()
        registryOverride.signing?.onUnsigned = .silentAllow
        registryOverride.signing?.onUntrustedCertificate = .silentAllow
        registryOverride.signing?.trustedRootCertificatesPath = "/foo/roots"
        registryOverride.signing?.includeDefaultTrustedRootCertificates = false
        registryOverride.signing?.validationChecks = RegistryConfiguration.Security.Signing.ValidationChecks()
        registryOverride.signing?.validationChecks?.certificateExpiration = .enabled
        registryOverride.signing?.validationChecks?.certificateRevocation = .allowSoftFail
        security.registryOverrides["foo.com"] = registryOverride
        // scopeOverrides
        let scope = try PackageIdentity.Scope(validating: "mona")
        var scopeOverride = RegistryConfiguration.Security.ScopePackageOverride()
        scopeOverride.signing = RegistryConfiguration.Security.ScopePackageOverride.Signing()
        scopeOverride.signing?.trustedRootCertificatesPath = "/mona/roots"
        scopeOverride.signing?.includeDefaultTrustedRootCertificates = false
        security.scopeOverrides[scope] = scopeOverride
        // packageOverrides
        let packageIdentity = PackageIdentity.plain("mona.LinkedList").registry!
        var packageOverride = RegistryConfiguration.Security.ScopePackageOverride()
        packageOverride.signing = RegistryConfiguration.Security.ScopePackageOverride.Signing()
        packageOverride.signing?.trustedRootCertificatesPath = "/mona/LinkedList/roots"
        packageOverride.signing?.includeDefaultTrustedRootCertificates = false
        security.packageOverrides[packageIdentity] = packageOverride
        configuration.security = security

        let encoded = try encoder.encode(configuration)
        let decoded = try decoder.decode(RegistryConfiguration.self, from: encoded)

        XCTAssertEqual(configuration, decoded)
    }

    func testDecodeEmptyConfiguration() throws {
        let json = #"""
        {
            "registries": {},
            "authentication": {},
            "security": {},
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)
        XCTAssertNil(configuration.defaultRegistry)
        XCTAssertEqual(configuration.scopedRegistries, [:])
        XCTAssertEqual(configuration.registryAuthentication, [:])
        XCTAssertEqual(configuration.security, RegistryConfiguration.Security())
    }

    func testDecodeEmptyConfigurationWithMissingKeys() throws {
        let json = #"""
        {
            "registries": {},
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)
        XCTAssertNil(configuration.defaultRegistry)
        XCTAssertEqual(configuration.scopedRegistries, [:])
        XCTAssertEqual(configuration.registryAuthentication, [:])
        XCTAssertNil(configuration.security)
    }

    func testDecodeExampleConfiguration() throws {
        let json = #"""
        {
            "registries": {
                "[default]": {
                    "url": "\#(defaultRegistryBaseURL)"
                },
                "foo": {
                    "url": "\#(customRegistryBaseURL)"
                },
                "bar": {
                    "url": "\#(customRegistryBaseURL)"
                }
            },
            "authentication": {
                "packages.example.com": {
                    "type": "basic",
                    "loginAPIPath": "/v1/login"
                }
            },
            "security": {
                "default": {
                    "signing": {
                        "onUnsigned": "error",
                        "onUntrustedCertificate": "error",
                        "trustedRootCertificatesPath": "~/.swiftpm/security/trusted-root-certs/",
                        "includeDefaultTrustedRootCertificates": true,
                        "validationChecks": {
                            "certificateExpiration": "disabled",
                            "certificateRevocation": "disabled"
                        }
                    }
                },
                "registryOverrides": {
                    "packages.example.com": {
                        "signing": {
                            "onUnsigned": "warn",
                            "onUntrustedCertificate": "warn",
                            "trustedRootCertificatesPath": "/foo/roots",
                            "includeDefaultTrustedRootCertificates": false,
                            "validationChecks": {
                                "certificateExpiration": "enabled",
                                "certificateRevocation": "allowSoftFail"
                            }
                        }
                    }
                },
                "scopeOverrides": {
                    "mona": {
                        "signing": {
                            "trustedRootCertificatesPath": "/mona/roots",
                            "includeDefaultTrustedRootCertificates": false
                        }
                    }
                },
                "packageOverrides": {
                    "mona.LinkedList": {
                        "signing": {
                            "trustedRootCertificatesPath": "/mona/LinkedList/roots",
                            "includeDefaultTrustedRootCertificates": false
                        }
                    }
                }
            },
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)
        XCTAssertEqual(configuration.defaultRegistry?.url, defaultRegistryBaseURL)
        XCTAssertEqual(configuration.scopedRegistries["foo"]?.url, customRegistryBaseURL)
        XCTAssertEqual(configuration.scopedRegistries["bar"]?.url, customRegistryBaseURL)
        XCTAssertEqual(configuration.registryAuthentication["packages.example.com"]?.type, .basic)
        XCTAssertEqual(configuration.registryAuthentication["packages.example.com"]?.loginAPIPath, "/v1/login")
        XCTAssertEqual(configuration.security?.default.signing?.onUnsigned, .error)
        XCTAssertEqual(configuration.security?.default.signing?.onUntrustedCertificate, .error)
        XCTAssertEqual(
            configuration.security?.default.signing?.trustedRootCertificatesPath,
            "~/.swiftpm/security/trusted-root-certs/"
        )
        XCTAssertEqual(configuration.security?.default.signing?.includeDefaultTrustedRootCertificates, true)
        XCTAssertEqual(configuration.security?.default.signing?.validationChecks?.certificateExpiration, .disabled)
        XCTAssertEqual(configuration.security?.default.signing?.validationChecks?.certificateRevocation, .disabled)
        XCTAssertEqual(configuration.security?.registryOverrides["packages.example.com"]?.signing?.onUnsigned, .warn)
        XCTAssertEqual(
            configuration.security?.registryOverrides["packages.example.com"]?.signing?.onUntrustedCertificate,
            .warn
        )
        XCTAssertEqual(
            configuration.security?.registryOverrides["packages.example.com"]?.signing?.trustedRootCertificatesPath,
            "/foo/roots"
        )
        XCTAssertEqual(
            configuration.security?.registryOverrides["packages.example.com"]?.signing?
                .includeDefaultTrustedRootCertificates,
            false
        )
        XCTAssertEqual(
            configuration.security?.registryOverrides["packages.example.com"]?.signing?.validationChecks?
                .certificateExpiration,
            .enabled
        )
        XCTAssertEqual(
            configuration.security?.registryOverrides["packages.example.com"]?.signing?.validationChecks?
                .certificateRevocation,
            .allowSoftFail
        )
        XCTAssertEqual(
            configuration.security?.scopeOverrides[PackageIdentity.Scope(stringLiteral: "mona")]?.signing?
                .trustedRootCertificatesPath,
            "/mona/roots"
        )
        XCTAssertEqual(
            configuration.security?.scopeOverrides[PackageIdentity.Scope(stringLiteral: "mona")]?.signing?
                .includeDefaultTrustedRootCertificates,
            false
        )
        XCTAssertEqual(
            configuration.security?.packageOverrides[PackageIdentity.plain("mona.LinkedList").registry!]?.signing?
                .trustedRootCertificatesPath,
            "/mona/LinkedList/roots"
        )
        XCTAssertEqual(
            configuration.security?.packageOverrides[PackageIdentity.plain("mona.LinkedList").registry!]?.signing?
                .includeDefaultTrustedRootCertificates,
            false
        )
    }

    func testDecodeConfigurationWithInvalidRegistryKey() throws {
        let json = #"""
        {
            "registries": {
                0: "\#(customRegistryBaseURL)"
            },
            "version": 1
        }
        """#

        XCTAssertThrowsError(try self.decoder.decode(RegistryConfiguration.self, from: json))
    }

    func testDecodeConfigurationWithInvalidRegistryValue() throws {
        let json = #"""
        {
            "registries": {
                "[default]": "\#(customRegistryBaseURL)"
            },
            "version": 1
        }
        """#

        XCTAssertThrowsError(try self.decoder.decode(RegistryConfiguration.self, from: json))
    }

    func testDecodeConfigurationWithInvalidAuthenticationType() throws {
        let json = #"""
        {
            "registries": {},
            "authentication": {
                "packages.example.com": {
                    "type": "foobar"
                }
            },
            "version": 1
        }
        """#

        XCTAssertThrowsError(try self.decoder.decode(RegistryConfiguration.self, from: json))
    }

    func testDecodeConfigurationWithMissingVersion() throws {
        let json = #"""
        {
            "registries": {}
        }
        """#

        XCTAssertThrowsError(try self.decoder.decode(RegistryConfiguration.self, from: json))
    }

    func testDecodeSecurityConfigurationWithInvalidScopeKey() throws {
        let json = #"""
        {
            "registries": {},
            "authentication": {
                "packages.example.com": {
                    "type": "foobar"
                }
            },
            "security": {
                "scopeOverrides": {
                  "mona.": {
                    "signing": {
                      "trustedRootCertificatesPath": "/mona/roots",
                      "includeDefaultTrustedRootCertificates": false
                    }
                  }
                }
            },
            "version": 1
        }
        """#

        XCTAssertThrowsError(try self.decoder.decode(RegistryConfiguration.self, from: json))
    }

    func testDecodeSecurityConfigurationWithInvalidPackageKey() throws {
        let json = #"""
        {
            "registries": {},
            "authentication": {
                "packages.example.com": {
                    "type": "foobar"
                }
            },
            "security": {
                "packageOverrides": {
                  "LinkedList": {
                    "signing": {
                      "trustedRootCertificatesPath": "/mona/LinkedList/roots",
                      "includeDefaultTrustedRootCertificates": false
                    }
                  }
                }
            },
            "version": 1
        }
        """#

        XCTAssertThrowsError(try self.decoder.decode(RegistryConfiguration.self, from: json))
    }

    func testDecodeConfigurationWithInvalidVersion() throws {
        let json = #"""
        {
            "registries": {},
            "version": 999
        }
        """#

        XCTAssertThrowsError(try self.decoder.decode(RegistryConfiguration.self, from: json))
    }

    func testGetAuthenticationConfigurationByRegistryURL() throws {
        var configuration = RegistryConfiguration()
        try configuration.add(authentication: .init(type: .token), for: defaultRegistryBaseURL)

        XCTAssertEqual(try configuration.authentication(for: defaultRegistryBaseURL)?.type, .token)
        XCTAssertNil(try configuration.authentication(for: customRegistryBaseURL))
    }

    func testGetSigning_noOverrides() throws {
        let json = #"""
        {
            "registries": {},
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)

        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        let signing = configuration.signing(for: package, registry: registry)

        XCTAssertEqual(signing.onUnsigned, .warn)
        XCTAssertEqual(signing.onUntrustedCertificate, .warn)
        XCTAssertNil(signing.trustedRootCertificatesPath)
        XCTAssertEqual(signing.includeDefaultTrustedRootCertificates, true)
        XCTAssertEqual(signing.validationChecks?.certificateExpiration, .disabled)
        XCTAssertEqual(signing.validationChecks?.certificateRevocation, .disabled)
    }

    func testGetSigning_globalOverride() throws {
        let json = #"""
        {
            "registries": {},
            "security": {
                "default": {
                    "signing": {
                        "onUnsigned": "error",
                        "trustedRootCertificatesPath": "/custom/roots",
                        "validationChecks": {
                            "certificateExpiration": "enabled"
                        }
                    }
                }
            },
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)

        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        let signing = configuration.signing(for: package, registry: registry)

        XCTAssertEqual(signing.onUnsigned, .error)
        XCTAssertEqual(signing.onUntrustedCertificate, .warn)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/custom/roots")
        XCTAssertEqual(signing.includeDefaultTrustedRootCertificates, true)
        XCTAssertEqual(signing.validationChecks?.certificateExpiration, .enabled)
        XCTAssertEqual(signing.validationChecks?.certificateRevocation, .disabled)
    }

    func testGetSigning_registryOverride() throws {
        let json = #"""
        {
            "registries": {},
            "security": {
                "registryOverrides": {
                    "packages.example.com": {
                        "signing": {
                            "onUntrustedCertificate": "warn",
                            "trustedRootCertificatesPath": "/foo/roots",
                            "validationChecks": {
                                "certificateRevocation": "allowSoftFail"
                            }
                        }
                    },
                    "other.example.com": {
                        "signing": {
                            "onUntrustedCertificate": "error"
                        }
                    }
                }
            },
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)

        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        let signing = configuration.signing(for: package, registry: registry)

        XCTAssertEqual(signing.onUnsigned, .warn)
        XCTAssertEqual(signing.onUntrustedCertificate, .warn)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/foo/roots")
        XCTAssertEqual(signing.includeDefaultTrustedRootCertificates, true)
        XCTAssertEqual(signing.validationChecks?.certificateExpiration, .disabled)
        XCTAssertEqual(signing.validationChecks?.certificateRevocation, .allowSoftFail)
    }

    func testGetSigning_scopeOverride() throws {
        let json = #"""
        {
            "registries": {},
            "security": {
                "scopeOverrides": {
                    "mona": {
                        "signing": {
                            "trustedRootCertificatesPath": "/mona/roots"
                        }
                    },
                    "foo": {
                        "signing": {
                            "trustedRootCertificatesPath": "/foo/roots"
                        }
                    }
                }
            },
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)

        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        let signing = configuration.signing(for: package, registry: registry)

        XCTAssertEqual(signing.onUnsigned, .warn)
        XCTAssertEqual(signing.onUntrustedCertificate, .warn)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/mona/roots")
        XCTAssertEqual(signing.includeDefaultTrustedRootCertificates, true)
        XCTAssertEqual(signing.validationChecks?.certificateExpiration, .disabled)
        XCTAssertEqual(signing.validationChecks?.certificateRevocation, .disabled)
    }

    func testGetSigning_packageOverride() throws {
        let json = #"""
        {
            "registries": {},
            "security": {
                "packageOverrides": {
                    "mona.LinkedList": {
                        "signing": {
                            "trustedRootCertificatesPath": "/mona/linkedlist/roots"
                        }
                    },
                    "foo.bar": {
                        "signing": {
                            "trustedRootCertificatesPath": "/foo/bar/roots"
                        }
                    }
                }
            },
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)

        let package = PackageIdentity.plain("mona.LinkedList").registry!
        let registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        let signing = configuration.signing(for: package, registry: registry)

        XCTAssertEqual(signing.onUnsigned, .warn)
        XCTAssertEqual(signing.onUntrustedCertificate, .warn)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/mona/linkedlist/roots")
        XCTAssertEqual(signing.includeDefaultTrustedRootCertificates, true)
        XCTAssertEqual(signing.validationChecks?.certificateExpiration, .disabled)
        XCTAssertEqual(signing.validationChecks?.certificateRevocation, .disabled)
    }

    func testGetSigning_multipleOverrides() throws {
        let json = #"""
        {
            "registries": {},
            "security": {
                "default": {
                    "signing": {
                        "trustedRootCertificatesPath": "/custom/roots"
                    }
                },
                "registryOverrides": {
                    "packages.example.com": {
                        "signing": {
                            "trustedRootCertificatesPath": "/foo/roots"
                        }
                    }
                },
                "scopeOverrides": {
                    "mona": {
                        "signing": {
                            "trustedRootCertificatesPath": "/mona/roots"
                        }
                    }
                },
                "packageOverrides": {
                    "mona.LinkedList": {
                        "signing": {
                            "trustedRootCertificatesPath": "/mona/linkedlist/roots"
                        }
                    }
                }
            },
            "version": 1
        }
        """#

        let configuration = try decoder.decode(RegistryConfiguration.self, from: json)

        // Package override wins
        var package = PackageIdentity.plain("mona.LinkedList").registry!
        var registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        var signing = configuration.signing(for: package, registry: registry)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/mona/linkedlist/roots")

        // No package override, closest match is scope override
        package = PackageIdentity.plain("mona.Trie").registry!
        registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        signing = configuration.signing(for: package, registry: registry)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/mona/roots")

        // No package override, closest match is registry override
        package = PackageIdentity.plain("foo.bar").registry!
        registry = Registry(url: "https://packages.example.com", supportsAvailability: false)
        signing = configuration.signing(for: package, registry: registry)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/foo/roots")

        // Global override
        package = PackageIdentity.plain("foo.bar").registry!
        registry = Registry(url: "https://other.example.com", supportsAvailability: false)
        signing = configuration.signing(for: package, registry: registry)
        XCTAssertEqual(signing.trustedRootCertificatesPath, "/custom/roots")
    }
}
