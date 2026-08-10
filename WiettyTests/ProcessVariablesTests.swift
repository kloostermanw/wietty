import Testing
@testable import Wietty

@Suite struct ProcessVariablesTests {
    @Test func detectsBareReference() {
        let unresolved = ProcessVariables.unresolved(in: "gh pr view $WIETTY_PR_NUMBER", available: [:])
        #expect(unresolved == ["WIETTY_PR_NUMBER"])
    }

    @Test func detectsBracedReference() {
        let unresolved = ProcessVariables.unresolved(in: "echo ${WIETTY_BRANCH}", available: [:])
        #expect(unresolved == ["WIETTY_BRANCH"])
    }

    @Test func resolvedReferenceIsNotReported() {
        let unresolved = ProcessVariables.unresolved(
            in: "gittower $WIETTY_WORKSPACE_PATH", available: ["WIETTY_WORKSPACE_PATH": "/x"]
        )
        #expect(unresolved.isEmpty)
    }

    @Test func nonWiettyVariablesAreIgnored() {
        let unresolved = ProcessVariables.unresolved(in: "echo $HOME ${PATH}", available: [:])
        #expect(unresolved.isEmpty)
    }

    @Test func unknownWiettyNameCountsAsUnresolved() {
        let unresolved = ProcessVariables.unresolved(in: "echo $WIETTY_TYPO", available: ["WIETTY_BRANCH": "main"])
        #expect(unresolved == ["WIETTY_TYPO"])
    }

    @Test func reportsEachUnresolvedOnceSorted() {
        let unresolved = ProcessVariables.unresolved(
            in: "$WIETTY_REPO $WIETTY_OWNER $WIETTY_REPO", available: [:]
        )
        #expect(unresolved == ["WIETTY_OWNER", "WIETTY_REPO"])
    }

    @Test func mixesResolvedAndUnresolved() {
        let unresolved = ProcessVariables.unresolved(
            in: "run ${WIETTY_BRANCH} $WIETTY_PR_NUMBER", available: ["WIETTY_BRANCH": "main"]
        )
        #expect(unresolved == ["WIETTY_PR_NUMBER"])
    }

    @Test func commandWithoutReferencesIsEmpty() {
        #expect(ProcessVariables.unresolved(in: "npm run dev", available: [:]).isEmpty)
    }

    @Test func loneDollarAndUnclosedBraceAreNotReferences() {
        #expect(ProcessVariables.unresolved(in: "cost is $ and ${WIETTY_BRANCH", available: [:]).isEmpty)
    }
}
