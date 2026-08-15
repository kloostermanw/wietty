import Testing
import Foundation
@testable import Wietty

/// The sound preference: what it offers, what it stores, and what it does with a
/// value it cannot read.
@Suite struct BellSoundTests {
    @Test func everyCaseSurvivesTheRoundTrip() {
        for sound in [BellSound.silent, .systemDefault, .named("Submarine")] {
            #expect(BellSound(stored: sound.stored) == sound)
        }
    }

    /// A preference written by a later build, or a store that has never had one, is
    /// the default sound rather than silence. Falling back to silence would turn an
    /// unreadable value into a feature that quietly stopped working.
    @Test func anythingUnreadableIsTheDefaultSound() {
        #expect(BellSound(stored: "") == .systemDefault)
        #expect(BellSound(stored: "sideways") == .systemDefault)
        #expect(BellSound(stored: "named:") == .systemDefault)
    }

    /// "none" and "default" are spelled out in the stored form, so a sound that
    /// happens to be called either is still a named sound.
    @Test func aSoundNamedLikeAKeywordIsStillASound() {
        #expect(BellSound(stored: BellSound.named("none").stored) == .named("none"))
        #expect(BellSound(stored: BellSound.named("default").stored) == .named("default"))
    }

    /// Silence and the system default come first and always, so the picker has both
    /// even on a machine whose sound folder cannot be read.
    @Test func thePickerAlwaysOffersSilenceAndTheDefault() {
        let missing = URL(fileURLWithPath: "/System/Library/Sounds-that-are-not-there")
        #expect(BellSound.available(in: missing) == [.silent, .systemDefault])
    }

    /// The installed sounds follow, by name and without the extension, sorted.
    /// Written into a temporary folder rather than read from the real one, so the
    /// assertion does not depend on which sounds a given macOS ships.
    @Test func theInstalledSoundsFollowSortedAndWithoutTheirExtension() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Submarine.aiff", "Blow.aiff", "read-me.txt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        #expect(BellSound.available(in: folder)
                == [.silent, .systemDefault, .named("Blow"), .named("Submarine")])
    }

    /// Silence means no sound on the notification, which is not the same as the
    /// default sound.
    @Test func silenceHangsNoSoundOnTheNotification() {
        #expect(BellSound.silent.notificationSound == nil)
        #expect(BellSound.systemDefault.notificationSound != nil)
        #expect(BellSound.named("Ping").notificationSound != nil)
    }

    /// The Test button reports honestly rather than looking broken, so "nothing to
    /// play" and "that file is not there" are both false.
    @Test func playingReportsWhetherAnythingWasPlayed() {
        #expect(BellSound.silent.play() == false)
        #expect(BellSound.named("NoSuchSound").play() == false)
    }

    /// Every entry the picker offers is labelled and uniquely identified, since it
    /// is a `Picker` over `Identifiable` values.
    @Test func everyOfferedSoundIsLabelledAndUnique() {
        let sounds = BellSound.available()
        let ids = Set(sounds.map(\.id))
        #expect(ids.count == sounds.count)
        #expect(sounds.allSatisfy { !$0.title.isEmpty })
    }
}
