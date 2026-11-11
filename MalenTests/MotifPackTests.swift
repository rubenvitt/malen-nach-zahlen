import Testing
import UIKit
@testable import Malen

@MainActor struct MotifPackTests {
    @Test func everyPackMotifShipsItsImage() {
        let motifs = MotifPack.all.flatMap(\.motifs)
        #expect(!MotifPack.all.isEmpty)
        #expect(Set(motifs.map(\.id)).count == motifs.count)
        for pack in MotifPack.all { #expect(!pack.motifs.isEmpty, "\(pack.id)") }
        for motif in motifs { #expect(motif.image != nil, "\(motif.id) has no asset") }
    }
}
