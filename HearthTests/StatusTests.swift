import Foundation
import Testing
@testable import Hearth

@Test func launchctlRunningStoppedAndNotLoaded() {
    #expect(LaunchctlParser.parse(exitCode: 1, output: "state = running") == .notLoaded)
    #expect(LaunchctlParser.parse(exitCode: 0, output: "  state = running\n") == .running)
    #expect(LaunchctlParser.parse(exitCode: 0, output: "state = spawn scheduled") == .stopped)
}

@Test func cardStateFollowsLaunchdAndThePort() {
    #expect(ServiceStatus.card(launchd: .running, portOpen: true, errorLine: "") == .running)
    #expect(ServiceStatus.card(launchd: .running, portOpen: false, errorLine: "") == .starting)
    #expect(ServiceStatus.card(launchd: .notLoaded, portOpen: false, errorLine: "boom") == .stopped)
    #expect(ServiceStatus.card(launchd: .stopped, portOpen: false, errorLine: "boom") == .failed("boom"))
}

@Test func windowWordUsesStartingThenFailedThenRunning() {
    #expect(ServiceStatus.window(cards: [.running, .starting, .running], operationInProgress: false) == "Starting")
    #expect(ServiceStatus.window(cards: [.running, .failed("x"), .running], operationInProgress: false) == "Failed")
    #expect(ServiceStatus.window(cards: [.running, .running, .running], operationInProgress: false) == "Running")
    #expect(ServiceStatus.window(cards: [.stopped, .stopped, .stopped], operationInProgress: false) == "Stopped")
    #expect(ServiceStatus.window(cards: [.failed("x")], operationInProgress: true) == "Starting")
}

@Test func stopButtonAppearsWhenACardIsUp() {
    #expect(ServiceStatus.primaryIsStop(cards: [.running, .stopped, .stopped]))
    #expect(ServiceStatus.primaryIsStop(cards: [.starting]))
    #expect(!ServiceStatus.primaryIsStop(cards: [.stopped, .failed("")]))
}

@Test func logTailKeepsTheLastTwoHundredLines() {
    let lines = (1...250).map(String.init).joined(separator: "\n")
    let tail = LogTail.last(lines, count: 200)
    #expect(tail.hasPrefix("51"))
    #expect(tail.hasSuffix("250"))
    #expect(!tail.contains("\n50\n"))
}

@Test func logStoreDropsLinesPastFourThousand() {
    let store = LogStore()
    for number in 0...4000 {
        store.append("\(number)\n")
    }
    let log = store.snapshot().log
    #expect(log.hasPrefix("1\n"))
    #expect(log.hasSuffix("4000"))
    #expect(!log.hasPrefix("0"))
}

@Test func launchctlArgumentsMatchTheLabels() {
    let label = "com.jerodprice.hearth.httpd"
    #expect(Launchctl.printArguments(uid: 501, label: label) == ["print", "gui/501/\(label)"])
    #expect(Launchctl.bootstrapArguments(uid: 501, plist: "/tmp/\(label).plist") == ["bootstrap", "gui/501", "/tmp/\(label).plist"])
    #expect(Launchctl.bootoutArguments(uid: 501, label: label) == ["bootout", "gui/501/\(label)"])
    #expect(Launchctl.kickstartArguments(uid: 501, label: label) == ["kickstart", "-k", "gui/501/\(label)"])
    #expect(Launchctl.enableArguments(uid: 501, label: label) == ["enable", "gui/501/\(label)"])
    #expect(Launchctl.disableArguments(uid: 501, label: label) == ["disable", "gui/501/\(label)"])
}

@Test func resetStampUsesTheGivenCalendar() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let date = Date(timeIntervalSince1970: 1_780_000_000)
    let stamp = ResetStamp.string(from: date, calendar: calendar)
    let digitsOnly = stamp.allSatisfy { $0.isNumber }
    #expect(stamp.count == 14)
    #expect(digitsOnly)
}

@Test func adminerPinMatchesTheSpec() {
    #expect(StackLayout.adminerSHA256Pin == "cd5d65d3e85c9e1233126625232150e2de405f3d56c76fdc171f4133a401e8d2")
}
