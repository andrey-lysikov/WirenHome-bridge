//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Testing
@testable import WirenHome

@Test func versionHasTwoNumbers() {
    let parts = AppVersion.current.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 2)
    #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
}
