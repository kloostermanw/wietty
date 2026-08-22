import Testing
import Foundation
@testable import Wietty

/// The prompt-template value type: parsing a `.md` file into name, description,
/// argument hint and body, working out which argument fields a body asks for, and
/// substituting values back into it. All pure, so all asserted here rather than only
/// visible by picking a template in the popup.
@Suite struct PromptTemplateTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/prompt_templates/\(name)")
    }

    // MARK: Parsing

    @Test func parsesFrontmatterFieldsAndBody() {
        let contents = """
        ---
        name: Fix bug
        description: Investigate and propose a fix
        argument-hint: <ticket-id> <area>
        ---
        Investigate bug $1 and propose a fix. Focus on $ARGUMENTS.
        """
        let template = PromptTemplate.parse(contents: contents, fileURL: url("fix-bug.md"))
        #expect(template.name == "Fix bug")
        #expect(template.summary == "Investigate and propose a fix")
        #expect(template.argumentHint == "<ticket-id> <area>")
        #expect(template.body == "Investigate bug $1 and propose a fix. Focus on $ARGUMENTS.")
    }

    @Test func nameFallsBackToFilenameWhenNoFrontmatter() {
        let template = PromptTemplate.parse(contents: "Just a body, no frontmatter.",
                                            fileURL: url("refactor-helper.md"))
        #expect(template.name == "refactor-helper")
        #expect(template.summary.isEmpty)
        #expect(template.argumentHint.isEmpty)
        #expect(template.body == "Just a body, no frontmatter.")
    }

    @Test func nameFallsBackToFilenameWhenFrontmatterOmitsName() {
        let contents = """
        ---
        description: no name here
        ---
        Body.
        """
        let template = PromptTemplate.parse(contents: contents, fileURL: url("my-template.md"))
        #expect(template.name == "my-template")
        #expect(template.summary == "no name here")
    }

    @Test func malformedFrontmatterIsTreatedAsBody() {
        // An opening delimiter with no closing one is not frontmatter: the whole file
        // is the body, so a user does not silently lose the first half of a prompt.
        let contents = """
        ---
        name: Broken
        Investigate the thing.
        """
        let template = PromptTemplate.parse(contents: contents, fileURL: url("broken.md"))
        #expect(template.name == "broken")
        #expect(template.body == contents)
    }

    // MARK: Argument fields

    @Test func detectsPositionalPlaceholdersLabelledFromHint() {
        let contents = """
        ---
        argument-hint: <ticket-id> <area>
        ---
        Investigate bug $1 in $2.
        """
        let template = PromptTemplate.parse(contents: contents, fileURL: url("t.md"))
        #expect(template.argumentFields.map(\.index) == [1, 2])
        #expect(template.argumentFields.map(\.label) == ["<ticket-id>", "<area>"])
    }

    @Test func placeholderWithoutHintTokenLabelsItselfByNumber() {
        let template = PromptTemplate.parse(contents: "Do $1 then $2.", fileURL: url("t.md"))
        #expect(template.argumentFields.map(\.label) == ["$1", "$2"])
    }

    @Test func argumentsOnlyBodyOffersASingleField() {
        // A body that references $ARGUMENTS but no $N still needs somewhere to type,
        // so it gets one field.
        let contents = """
        ---
        argument-hint: <the task>
        ---
        Do this: $ARGUMENTS
        """
        let template = PromptTemplate.parse(contents: contents, fileURL: url("t.md"))
        #expect(template.argumentFields.map(\.index) == [1])
        #expect(template.argumentFields.map(\.label) == ["<the task>"])
    }

    @Test func bodyWithNoPlaceholdersHasNoFields() {
        let template = PromptTemplate.parse(contents: "A fixed prompt.", fileURL: url("t.md"))
        #expect(template.argumentFields.isEmpty)
        #expect(template.hasArguments == false)
    }

    // MARK: Rendering

    @Test func rendersPositionalAndAllArguments() {
        let template = PromptTemplate.parse(contents: "Bug $1 in $2. All: $ARGUMENTS.",
                                            fileURL: url("t.md"))
        let rendered = template.render(arguments: [1: "123", 2: "auth"])
        #expect(rendered == "Bug 123 in auth. All: 123 auth.")
    }

    @Test func missingArgumentRendersEmpty() {
        let template = PromptTemplate.parse(contents: "Bug $1 in $2.", fileURL: url("t.md"))
        #expect(template.render(arguments: [1: "123"]) == "Bug 123 in .")
    }

    @Test func multiDigitPlaceholderIsNotConfusedWithSingleDigit() {
        let template = PromptTemplate.parse(contents: "$1 and $10.", fileURL: url("t.md"))
        var args: [Int: String] = [:]
        for n in 1...10 { args[n] = String(n) }
        #expect(template.render(arguments: args) == "1 and 10.")
    }

    @Test func bodyWithNoPlaceholdersRendersUnchanged() {
        let template = PromptTemplate.parse(contents: "A fixed prompt.", fileURL: url("t.md"))
        #expect(template.render(arguments: [:]) == "A fixed prompt.")
    }

    /// The bug the review caught: a body whose lowest placeholder is not $1 must keep
    /// the value the user typed for it, not drop it. Values are keyed by placeholder
    /// index, so $2 gets its value even when there is no $1.
    @Test func aPlaceholderNotStartingAtOneKeepsItsValue() {
        let template = PromptTemplate.parse(contents: "Ticket $2.", fileURL: url("t.md"))
        #expect(template.render(arguments: [2: "ABC"]) == "Ticket ABC.")
    }

    @Test func nonContiguousPlaceholdersKeepTheirValues() {
        let template = PromptTemplate.parse(contents: "$1 and $3.", fileURL: url("t.md"))
        #expect(template.render(arguments: [1: "v1", 3: "v3"]) == "v1 and v3.")
    }

    /// $ARGUMENTS is the provided values in ascending index order, joined by a space,
    /// with no gap for an index the body never used.
    @Test func allArgumentsJoinsProvidedValuesInIndexOrder() {
        let template = PromptTemplate.parse(contents: "$2 $1 all: $ARGUMENTS",
                                            fileURL: url("t.md"))
        #expect(template.render(arguments: [1: "a", 2: "b"]) == "b a all: a b")
    }
}
