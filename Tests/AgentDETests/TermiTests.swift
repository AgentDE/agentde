import Foundation
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

@Suite("Notifications feed and Termi's popup")
struct NoticeTests {
    @Test func theFeedKeepsTheNewestFirstUpToItsLimit() {
        var feed: [AgentNotice] = []
        for i in 0..<(Store.noticeLimit + 5) {
            feed = Store.adding(AgentNotice(tab: UUID(), kind: i.isMultiple(of: 2) ? .done : .needsYou,
                                            title: "n\(i)", group: "g", body: ""), to: feed)
        }
        #expect(feed.count == Store.noticeLimit)
        #expect(feed.first?.title == "n\(Store.noticeLimit + 4)")
        #expect(feed.last?.title == "n5")
    }

    @Test func termiStandsJustLeftOfTheBannerColumn() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = TermiPopup.frame(visible: visible)
        #expect(frame.size == TermiPopup.size)
        #expect(frame.maxY == visible.maxY)
        #expect(frame.maxX == visible.maxX - TermiPopup.bannerMargin - TermiPopup.bannerWidth - TermiPopup.gap)
        #expect(TermiPopup.stay(.needsYou) > TermiPopup.stay(.done))
    }
}

@Suite("Alert style")
struct AlertStyleTests {
    @Test func eachChoiceRoundTripsThroughItsTwoFlags() {
        for style in AlertStyle.allCases {
            #expect(AlertStyle(banner: style.banner, termi: style.termi) == style)
        }
        #expect(AlertStyle(banner: true, termi: false) == .banner)
        #expect(AlertStyle(banner: false, termi: true) == .termi)
    }
}
