import Testing
@testable import EchoCore

@Suite("ConversationContext Tests")
struct ConversationContextTests {

    @Test("Empty context")
    func emptyContext() {
        let context = ConversationContext.empty

        #expect(context.recentTexts.isEmpty)
        #expect(context.userTerms.isEmpty)
    }

    @Test("Adding text creates new context (immutable)")
    func addingText() {
        let original = ConversationContext.empty
        let updated = original.adding(text: "Hello")

        #expect(original.recentTexts.isEmpty) // Original unchanged
        #expect(updated.recentTexts.count == 1)
        #expect(updated.recentTexts[0] == "Hello")
    }

    @Test("Adding text respects max history")
    func maxHistory() {
        var context = ConversationContext(maxHistory: 3)

        context = context.adding(text: "First")
        context = context.adding(text: "Second")
        context = context.adding(text: "Third")
        context = context.adding(text: "Fourth")

        #expect(context.recentTexts.count == 3)
        #expect(context.recentTexts[0] == "Fourth")
    }

    @Test("Newest text is first in list")
    func ordering() {
        var context = ConversationContext.empty

        context = context.adding(text: "First")
        context = context.adding(text: "Second")

        #expect(context.recentTexts[0] == "Second")
        #expect(context.recentTexts[1] == "First")
    }

    @Test("Adding user terms creates new context")
    func userTerms() {
        let context = ConversationContext.empty
            .withUserTerms(["Claude", "Echo"])

        #expect(context.userTerms.count == 2)
    }

    @Test("Format for prompt includes context")
    func formatForPrompt() {
        let context = ConversationContext(
            recentTexts: ["Hello"],
            userTerms: ["Claude"]
        )

        let formatted = context.formatForPrompt()

        #expect(formatted.contains("Recent context"))
        #expect(formatted.contains("Hello"))
        #expect(formatted.contains("User dictionary terms"))
        #expect(formatted.contains("Claude"))
    }

    @Test("Empty context produces empty prompt")
    func emptyPrompt() {
        let formatted = ConversationContext.empty.formatForPrompt()
        #expect(formatted.isEmpty)
    }
}
