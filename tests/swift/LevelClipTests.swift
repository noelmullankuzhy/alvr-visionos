// SOURCES: tools/diag/clip-policy.swift
import Foundation

@main enum LevelClipTests {
    static func main() throws {
        let nits: [Double] = [203, 400, 600, 800, 1000, 1500, 2000, 4000]
        let codes: [UInt16] = [573, 636, 674, 701, 723, 761, 789, 855]
        for (i, n) in nits.enumerated() {
            let level = try LevelClip(nits: n)
            expectEqual(level.code, codes[i], "hand PQ code for \(n) nits")
            expect(abs(level.side * level.side - 1920 * 1080 * 0.1) < 1e-8, "10% continuous area")
            expect(abs(level.originX + level.side / 2 - 960) < 1e-9, "centred x")
            expect(abs(level.originY + level.side / 2 - 540) < 1e-9, "centred y")
            expect(!level.labelBounds.intersects(level.bounds), "top label outside patch")
            expect(level.labelBounds.y + level.labelBounds.height < level.bounds.y, "top band")
            let pixels = level.raster()
            expectEqual(pixels[540 * 1920 + 960], codes[i] << 6, "patch centre")
            expectEqual(pixels[0], 64 << 6, "black surround")
            expect(pixels.contains(pqCode(100) << 6), "100-nit label")
        }
        for n in [0.0, -1, Double.nan, Double.infinity, 10001] {
            do { _ = try LevelClip(nits: n); expect(false, "invalid nits rejected") }
            catch { expect(true, "invalid nits rejected") }
        }
        finishTests("LevelClip")
    }
}
