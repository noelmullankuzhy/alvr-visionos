// SOURCES: tools/diag/clip-policy.swift
import Foundation

@main enum GridClipTests {
    static func main() throws {
        let grid = try GridClip(area: 10, range: "coarse")
        expectEqual(grid.cells.map { $0.name }, ["A1","A2","A3","A4","A5","B5","B4","B3","B2","B1","C1","C2","C3","C4","C5","D5","D4","D3","D2","D1","E1","E2","E3","E4","E5"], "snake order")
        expectEqual(grid.cells.first!.nits, 100, "coarse start")
        expectEqual(grid.cells.last!.nits, 10000, "coarse end")
        expectEqual(grid.cells[0].code, 509, "100 nits by hand")
        expectEqual(grid.cells[12].code, 723, "1000 nits by hand")
        expectEqual(grid.cells[24].code, 940, "10000 nits endpoint")
        expectEqual(pqCode(203), 573, "203 nits by hand")
        for i in 1..<25 {
            expect(abs(grid.cells[i].nits / grid.cells[i - 1].nits - pow(100, 1.0 / 24)) < 1e-12, "log spacing")
        }
        for (lo, hi) in [(600.0, 2000.0), (203, 1000)] {
            let fine = try GridClip(area: 1, range: "fine", lo: lo, hi: hi)
            expectEqual(fine.cells.first!.nits, lo, "fine start")
            expectEqual(fine.cells.last!.nits, hi, "fine end")
            expect(abs(fine.cells[12].nits - sqrt(lo * hi)) < 1e-9, "fine geometric midpoint")
        }
        for area in [1, 10, 50] {
            let g = try GridClip(area: area, range: "coarse")
            expect(abs(25 * g.side * g.side - Double(1920 * 1080 * area) / 100) < 1e-8, "exact continuous area")
            expect(abs(g.originX + 2.5 * g.side - 960) < 1e-9, "centred x")
            expect(abs(g.originY + 2.5 * g.side - 540) < 1e-9, "centred y")
            let raster = g.raster()
            var pixels = 0
            for cell in g.cells {
                let r = g.bounds(cell)
                pixels += r.width * r.height
                for y in r.y..<(r.y + r.height) {
                    expectEqual(raster[y * 1920 + r.x], cell.code << 6, "left edge tiles")
                    expectEqual(raster[y * 1920 + r.x + r.width - 1], cell.code << 6, "right edge tiles")
                }
            }
            let b = g.gridBounds
            expectEqual(pixels, b.width * b.height, "raster cells tile grid exactly")
            expect(abs(Double(b.x) + Double(b.width) / 2 - 960) <= 0.5, "raster centred x")
            expect(abs(Double(b.y) + Double(b.height) / 2 - 540) <= 0.5, "raster centred y")
            expectEqual(g.labels.map { $0.text }, ["A","B","C","D","E","1","2","3","4","5"], "axis labels")
            for label in g.labels {
                expect(!label.rect.intersects(b), "label outside cells")
                expect(label.rect.x >= 0 && label.rect.y >= 0 && label.rect.x + label.rect.width <= 1920 && label.rect.y + label.rect.height <= 1080, "label in frame")
            }
            expectEqual(raster[0], 64 << 6, "black surround")
            expect(raster.contains(pqCode(100) << 6), "100-nit label pixels")
        }
        for (area, range, lo, hi) in [(2,"coarse",600.0,2000.0), (10,"bad",600,2000), (10,"fine",0,1000), (10,"fine",2000,600), (10,"fine",100,10001), (10,"fine",Double.nan,1000)] {
            do { _ = try GridClip(area: area, range: range, lo: lo, hi: hi); expect(false, "invalid grid rejected") }
            catch { expect(true, "invalid grid rejected") }
        }
        finishTests("GridClip")
    }
}
