import Testing

@testable import Uso

struct CursorSessionTests {
    private let sealed = "cursor-safe-storage:v1:dGhpcyBpcyBub3QgYSB0b2tlbg=="

    @Test func plaintextDesktopTokenComesBeforeTheCLI() {
        let session = CursorSession.resolve(desktop: "desktop-token", membership: "ultra", cli: { "cli-token" })
        #expect(session.tokens == ["desktop-token", "cli-token"])
        #expect(!session.isSealed)
        #expect(session.membership == "ultra")
    }

    @Test func sealedDesktopTokenIsNeverSentAndTheCLIIsUsed() {
        let session = CursorSession.resolve(desktop: sealed, membership: "", cli: { "cli-token\n" })
        #expect(session.tokens == ["cli-token"])
        #expect(session.isSealed)
    }

    @Test func sealedDesktopWithoutCLILeavesNothingToSend() {
        let session = CursorSession.resolve(desktop: sealed, membership: "", cli: { nil })
        #expect(session.tokens.isEmpty)
        #expect(session.isSealed)
    }

    @Test func signedOutEverywhereIsNotSealed() {
        for desktop in [nil, "", "  "] {
            let session = CursorSession.resolve(desktop: desktop, membership: "", cli: { "" })
            #expect(session.tokens.isEmpty)
            #expect(!session.isSealed)
        }
    }

    @Test func sameTokenInBothPlacesIsSentOnce() {
        let session = CursorSession.resolve(desktop: "shared", membership: "", cli: { "shared" })
        #expect(session.tokens == ["shared"])
    }
}
