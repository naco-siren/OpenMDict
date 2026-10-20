import Testing
import Foundation
@testable import OpenMDict

@Suite
struct EntryLinkTests {

    @Test("Plain targets and anchors")
    func plain() {
        #expect(EntryLink.parse("entry://stomach")! == ("stomach", nil))
        #expect(EntryLink.parse("entry://take#take-up")! == ("take", "take-up"))
        #expect(EntryLink.parse("ENTRY://Take")! == ("Take", nil))
        #expect(EntryLink.parse("entry://word#")! == ("word", nil))
    }

    @Test("Targets with characters that end a URL host")
    func reservedCharacters() {
        #expect(EntryLink.parse("entry://9/11")! == ("9/11", nil))
        #expect(EntryLink.parse("entry://A/C")! == ("A/C", nil))
        #expect(EntryLink.parse("entry://24/7#x")! == ("24/7", "x"))
        #expect(EntryLink.parse("entry://Capital%3A%20Critique%20of%20Political%20Economy")!
                == ("Capital: Critique of Political Economy", nil))
        #expect(EntryLink.parse("entry://counts%2Fminute")! == ("counts/minute", nil))
    }

    @Test("Percent-encoded non-ASCII targets and fragments")
    func nonASCII() {
        #expect(EntryLink.parse("entry://%E5%A5%BD")! == ("好", nil))
        #expect(EntryLink.parse("entry://%CE%BB%CF%8C%CE%B3%CE%BF%CF%82#s%C3%A9ns")! == ("λόγος", "séns"))
    }

    @Test("Not an entry link")
    func notEntry() {
        #expect(EntryLink.parse("sound://uk/a.mp3") == nil)
        #expect(EntryLink.parse("https://example.com") == nil)
    }

    @Test("Rewriting keeps targets parseable")
    func encodeRoundTrip() throws {
        // ("%" is kept as is so already-escaped targets are not encoded
        // twice; a literal "%" in a target is therefore not supported.)
        for target in ["Capital: Critique", "9/11", "who?", "a@b", "x;y", "λόγος", "o'clock"] {
            let encoded = try #require(target.addingPercentEncoding(withAllowedCharacters: EntryLink.targetAllowedCharacters))
            let url = try #require(URL(string: "entry://" + encoded), "\(target)")
            #expect(EntryLink.parse(url.absoluteString)?.word == target)
        }
    }
}

private func == (lhs: (word: String, fragment: String?), rhs: (String, String?)) -> Bool {
    lhs.word == rhs.0 && lhs.fragment == rhs.1
}
