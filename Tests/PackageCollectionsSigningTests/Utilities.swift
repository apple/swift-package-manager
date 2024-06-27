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

import Basics
import Dispatch
import Foundation
@testable import PackageCollectionsSigning
import X509

// Set `REAL_CERT_USER_ID` and `REAL_CERT_ORG_UNIT` env vars when running ENABLE_REAL_CERT_TEST tests
let expectedSubjectUserID = Environment.current["REAL_CERT_USER_ID"] ?? "<USER ID>"
let expectedSubjectOrgUnit = Environment.current["REAL_CERT_ORG_UNIT"] ?? "<ORG UNIT>"

// MARK: - CertificatePolicy for test certs

struct TestCertificatePolicy: CertificatePolicy {
    static let testCertValidDate: Date = {
        // This is the datetime that the tests use to validate test certs (Test_rsa.cer, Test_ec.cer).
        // Make sure it falls within the certs' validity period, across timezones.
        // For example, suppose the current date is April 17, 2023, the cert validation runs as if
        // the date were July 18, 2023.
        var dateComponents = DateComponents()
        dateComponents.year = 2023
        dateComponents.month = 7
        dateComponents.day = 18
        return Calendar.current.date(from: dateComponents)!
    }()

    static let testCertInvalidDate: Date = {
        var dateComponents = DateComponents()
        dateComponents.year = 2000
        dateComponents.month = 11
        dateComponents.day = 16
        return Calendar.current.date(from: dateComponents)!
    }()

    let trustedRoots: [Certificate]?

    init(trustedRoots: [Certificate]?) {
        self.trustedRoots = trustedRoots
    }

    func validate(
        certChain: [Certificate],
        validationTime: Date
    ) async throws {
        try await self.verify(
            certChain: certChain,
            trustedRoots: self.trustedRoots,
            policies: {
                // Must be a code signing certificate
                _CodeSigningPolicy()
                // Basic validations including expiry check
                RFC5280Policy(validationTime: validationTime)
                // Doesn't require OCSP
            },
            observabilityScope: ObservabilitySystem.NOOP
        )
    }
}

// MARK: - Test keys

let ecPrivateKey = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIMFnwA1gjIFnFZim4B2QvoXJIG2L4B8nH1BBZFlotA24oAoGCCqGSM49
AwEHoUQDQgAEkc2FgXZVz9llhV6+jAGPVHEcxBxK5tui9HWzvtE+ogKPr7i3e2JO
Xwm91hecppS11y/S8bLmrFxA+dCP/V7bnw==
-----END EC PRIVATE KEY-----
"""

let ecPublicKey = """
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEkc2FgXZVz9llhV6+jAGPVHEcxBxK
5tui9HWzvtE+ogKPr7i3e2JOXwm91hecppS11y/S8bLmrFxA+dCP/V7bnw==
-----END PUBLIC KEY-----
"""

let rsaPrivateKey = """
-----BEGIN RSA PRIVATE KEY-----
MIIEpQIBAAKCAQEAoQIWz/MQ+mRShQxxxs+zlCLHRz+R1zUPKZhg3eggbXartfyI
OSPEDaVANCjE1QLg0dtGCpkbMAVQLkC7os5ZuW6A6qtSAU6WUBOvnDBPVumqmDUq
AeXGEQyDZqReRm3D4Ov4qOTlIk34pRhoCymaNTiw7GfyzzWOcPxcRGGTz6fv1gmS
wDnURBeL9QUAb2/sdAAsY/SZzziNF+womF8y3mn+IvlKL3EhtSxUfdZpPdFmxPza
oVIlllFQcKnxH4/0PZeyPK0Npq4kCqATXcYXmaa3Ms9tPcsQUggtAR/QepyrKmB1
SRAouHqKi+bGTlCpFSFbDgW422gfqXEEboh39QIDAQABAoIBAQCRUR9hxFHYjF9m
MhsmgyPjWZhel+N7RypOMneLEQzjfy3vbONOHxe98R4HdZxhXN2oyq1mt1UwfDsn
48j2YiPdFv1H0CSNhW5pC7t9zqRtHyyXf7RQTh/8Fz0pkMR98GfQQ2oElcKwuYrn
ByYwnPXPf0E/vXoKxp2vIDXuidssmUl37mvbyppGaVl+Is6GmAiZkNOKN8ZEXPvz
4BivJ3yhs/RiM5RUF93qj8j/3P6R8rXLemAE9jrKjGG7Vv966p1Fh9+wNnnnbT8t
zLDUVwD7Q/JERr+3Wdecp+pZIfWTvJJhE8R3IM4WrLQNeUEKo7YovfYA7rah3gP/
ixM2BM5pAoGBAM5+c7Sxl7hzII2yPxN2fIslyKw3E8HP1nnqUPUegFsU3TZRQUnZ
gm5JgQRPqFYy6fwouL07KdSb/zIes3ra/qkhaOewHsAvvvxKKM6FGqYrkb5BKv0s
gF/m4qg6GLSW3BVb/QfnwHdWE7z7KPGuomzg+pqshxTyKYkGN2l8IIu7AoGBAMeb
81636nRy62CYQhNCp13wqmmUJ8/VnNj2jdwdXQ5vlgQdrwFm2p52cEFn/AhL5WIn
GShRLKL/keK71tsD0hCsTuZISR1xFiFk0TFmjxSX+z2D9VGvSECtNfySRuroKorS
xIXsrx6dvk/Ef54yDus1O5vvdT3l6vSDbVJESFgPAoGBAIAFJ8kT/YNOZRVUOATi
Ba7jGvmiH+6d41OscMq3QU62rbr6P2cAofusOH+qvyvJ3wUFXht7raBxopK5M/7r
/MxwuTBDIZ13PIn/lDMNlIsHIhF5J6TUzTYn18gCVMTJbuMTJ9mZ1dpmlFAqyqSj
53FnPhdc9VaIGDYqk3ojia33AoGAd52bzNH3vMq1BJCZYANcWm4DIPu4k9JViKrP
Pe2WuzThOBw1qGhjb/xXrspKfQpGLnhxmfhzAEaYvL+FtH9onbc0HMmKjwsakO5i
cfEcouGknCt8kfOxH5jstitONizkeYZuYDcChh1PU2vUcg9bY1XmH77yiiJClz4+
/8KNe78CgYEArTT+XVctYq5jaFCtGqq3DD/DrgJeWS6V5Op0QgVrVKFeCH2mImOg
6+95qwqyl3xCTJNvLwcNB+yricsWfUicEPKfDJX1w8m5/fANMRZYXr2nmAZvS9Kw
pkG0a65+K/m4wnZIszEuNZ2ybjrHEwYdWygRkJUmHp5rzmjdKjCBkwU=
-----END RSA PRIVATE KEY-----
"""

let rsaPublicKey = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoQIWz/MQ+mRShQxxxs+z
lCLHRz+R1zUPKZhg3eggbXartfyIOSPEDaVANCjE1QLg0dtGCpkbMAVQLkC7os5Z
uW6A6qtSAU6WUBOvnDBPVumqmDUqAeXGEQyDZqReRm3D4Ov4qOTlIk34pRhoCyma
NTiw7GfyzzWOcPxcRGGTz6fv1gmSwDnURBeL9QUAb2/sdAAsY/SZzziNF+womF8y
3mn+IvlKL3EhtSxUfdZpPdFmxPzaoVIlllFQcKnxH4/0PZeyPK0Npq4kCqATXcYX
maa3Ms9tPcsQUggtAR/QepyrKmB1SRAouHqKi+bGTlCpFSFbDgW422gfqXEEboh3
9QIDAQAB
-----END PUBLIC KEY-----
"""

let certECPrivateKey = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIGfOkQcQq6oTC06KkGMVBAr2MiYFRaLo4/wKdNBpIjhnoAoGCCqGSM49
AwEHoUQDQgAE6SjFVQRtU/+ywvxslaVsl+iZf65YgkQShuxsbAbNJBTVkEkMGyNL
8nbaj6B4Jskjo1loNPLirNE7mKeTLYbrcw==
-----END EC PRIVATE KEY-----
"""

let certRSAPrivateKey = """
-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEA13XgJ9lIhR2LefNxQdo3tVrbXEZ3o4T8+MgteVJVohbPMypf
yGgGlJJ/r7+hhL/klsPDyR4SAtgLZUGFVt3WzGMolGyV11VUTTFHMWZ10tcgrUmR
5wg2n5E59FsJf3y3WTs5CpD2tM8igWyAUOyS/MWvhgnMtvBG8I4Mg9xyyWi/GW3g
PLXfnyULW/v2Zg+yG9j+/Bbpx+AP8TCvWoiPyiLEZ/DKZK2kC+8mkwOtHYDMkBO5
2nIrxopB42VUWYBfAzHm0M2XlEuc26PVojqno2ht5WU486uJXzWILvW3zFdlNDF/
SLeqQy1mNLRt5/An6la7e3sjOcuI1W2Qe7dkrwIDAQABAoIBAES+eUx9iSPfr1az
k5k9NLUKTh785MMpdUUzKT8iQ+w5dtaOWI0qk57ntxGuBKzERPzNbTRIAdsib1BZ
PV/f297ObG4ezxgrQ4B1jo92b3Vb6jMf3AtolXUH8wPB4B/q/Nzdhm+WnQBHbmz4
31/ye1tm/3+2tLhRpXCvAdM4jO8xhJlH+Pxg20fliAuiJ+ggSL56CyBR4kg80KtA
omeGB1DOVFd23aDO/79Mii/2tf6EpmVFB/4zBkPHOH3zucwt8XUttwBeOcGdIbP+
CiU9VdZmG0XOJfC3apAXf9YwU3WVbmbvUWSwt6iHGZD4AuKY2R0ECTZnYS8ThDhd
ZwPXzCECgYEA6xe9MpBCIVRK51Hb083mDg16UjRvPJA4T8w9xFg4UtAwe/u3CC67
4fAOSe0P3NtsXhcQFby7PEJwoeo2Hn6hUifxVMsKWmHb+FCg+CG/oBSwRKCa5BwG
WpJ0jEt6KHZf0u+b/N1aOjVi/9tMrsHXFV3s2Gm9LQqA8u8izshDqakCgYEA6p8t
KVK2mA+JjvSGyR6WfpVZ1OIi6CEEUhRU3aNHRB2zPf6J3PQLjz+Ad50BCVHXQSy/
aG3LpR44eUu5Q9AmTwDr8eiC8AT6uyE19zJHbK//E40Bn6khQvtymwByjav/5ZB+
ZAhE7E31eCZO8bqufSlnMNTD0Z8oqB5YR8uDApcCgYAkPcGd5N089Bij9luUGD6p
1ewQdiLbzEPSEWNIPG1aXtvKkTBTI5k1KGObg98ZJf5btuR05WZb0MY6P7feFZla
5+ttLevHqSRW8F8QQWugCvBtc/DMz4EvPzqWUiBf0nfNNcDvR1RcetRrKux0WE+G
7LbRWeOe6OqeCL1t8TN1GQKBgHPaH6m8/w689VbSpc+fu/5Lby0wcL4gt4p0IafD
nUgkRkLBcn/ZPfABEkV+EGnysJCtMOK2/IzPDGHQo2251YDDWr576lPskYZfks86
U4x2p0SXJwsYr6Tslp21LduI5/YKUG7Cqo3ovOIUQH0ailihXiP9m6fhqGjDeyIQ
euOHAoGAfDpntw1HRuk812au430Stl5eaTsH+w1msLLKZOukr6qWc2xFeC3fYPWQ
BBkyzM3p6Se9FsfHY6LMxrEkz9fSdeVOeHenyUCTMqhqrc6o9f79zIlocsMzVGsK
XKcULjpf67Igyx12eh3rqAEKwm6PGhbv9pK5/NpuzsP1atArMRg=
-----END RSA PRIVATE KEY-----
"""
