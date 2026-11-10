import Testing
@testable import AgentDE

@Suite("Termi")
struct TermiTests {
    @Test func moodFollowsTheAgents() {
        #expect(TermiMood.of([.working, .needsYou, .none], quietFor: 0) == .needsYou)
        #expect(TermiMood.of([.working, .doneUnseen], quietFor: 0) == .working)
        #expect(TermiMood.of([.doneUnseen, .none], quietFor: 30) == .wandering)
        #expect(TermiMood.of([], quietFor: 120) == .asleep)
    }
}
