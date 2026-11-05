import DMCore
import Foundation
import Testing

struct MessageTimelineTests {
    private func message(_ id: String, minute: Int, sender: String = "them", own: Bool = false) -> Message {
        Message(id: id, threadID: "thread", senderID: sender, text: "Message", timestamp: Int64(minute) * 60_000, isOwn: own)
    }

    @Test func groupsNearbyMessagesWithoutRepeatingNamesOrTimes() {
        let rows = MessageTimelineRow.make(from: [message("1", minute: 0), message("2", minute: 1), message("3", minute: 2, sender: "me", own: true), message("4", minute: 3, sender: "me", own: true)])
        #expect(rows.map(\.showsTimestamp) == [true, false, false, false])
        #expect(rows.map(\.startsSenderGroup) == [true, false, true, false])
        #expect(rows.map(\.showsSentStatus) == [false, false, false, true])
    }

    @Test func timeGapsAndDayBoundariesStartNewGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rows = MessageTimelineRow.make(from: [message("1", minute: 1430), message("2", minute: 1435), message("3", minute: 1439), message("4", minute: 1440)], calendar: calendar)
        #expect(rows.map(\.showsTimestamp) == [true, true, false, true])
        #expect(rows.map(\.startsSenderGroup) == [true, true, false, true])
        #expect(MessageTimelineRow.make(from: []).isEmpty)
    }

    @Test func dockBadgeClearsAtZeroAndOnlyCapsAboveFour() {
        #expect((-1...6).map(UnreadBadge.label) == [nil, nil, "1", "2", "3", "4", "4+", "4+"])
    }
}
