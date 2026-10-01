//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

@testable import Common
import Testing

@Test func trimsAndDecodesText() {
    #expect("  a b \t".trimmed == "a b")
    #expect("".trimmed == "")
    #expect("1.11%2C1.3".percentDecoded == "1.11,1.3")
    #expect("%D0%94%D0%BE%D0%BC".percentDecoded == "Дом")
    #expect("%2".percentDecoded == nil)
    #expect(UInt8(0x0A).hex == "0A")
    #expect(UInt8(0xFF).hex == "FF")
}

@Test func runsSubprocesses() async {
    let echo = await Subprocess.run("/bin/echo", ["hello", "world"])
    #expect(echo == Subprocess.Result(status: 0, output: "hello world\n"))

    let failing = await Subprocess.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
    #expect(failing.status == 3)
    #expect(failing.output == "oops\n")

    let missing = await Subprocess.run("/nonexistent/tool", [])
    #expect(missing.status != 0)
}
