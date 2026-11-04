import XCTest
@testable import LightCore

final class TracerTests: XCTestCase {
    /// 下から真上に出た光が、折り目の 45° の鏡で右へ曲がり、右の的に当たる
    private func simpleStage(targetY: Double = 700) -> Stage {
        Stage(
            id: "t1", title: "test",
            hinge: HingeMirror(center: Vec(500, 700), length: 200, baseDegrees: 45),
            emitters: [Emitter(position: Vec(500, 100), degrees: 90)],
            targets: [Target(center: Vec(900, targetY), radius: 30)]
        )
    }

    func testReflectionOffFortyFiveDegreeMirror() {
        let d = Vec(0, 1).reflected(normal: Segment(center: .init(0, 0), length: 2, degrees: 45).normal)
        XCTAssertEqual(d.x, 1, accuracy: 1e-9)
        XCTAssertEqual(d.y, 0, accuracy: 1e-9)
    }

    func testHitsTargetAtCenterHinge() {
        let result = Tracer.trace(simpleStage(), hinge: 122.5)
        XCTAssertEqual(result.litTargets, [0])
        XCTAssertTrue(result.allLit)
        XCTAssertEqual(result.beams.count, 1)
        XCTAssertEqual(result.beams[0].points.count, 3)
    }

    func testMissesWhenHingeMovesTenDegrees() {
        // 鏡が 10° 傾くと光は 20° 曲がり、400 先では 145 ほどずれる
        XCTAssertFalse(Tracer.trace(simpleStage(), hinge: 132.5).allLit)
        XCTAssertFalse(Tracer.trace(simpleStage(), hinge: 112.5).allLit)
    }

    func testHingeIsClampedToPlayableRange() {
        let mirror = HingeMirror(center: Vec(0, 0), length: 1, baseDegrees: 0)
        XCTAssertEqual(mirror.degrees(atHinge: 0), mirror.degrees(atHinge: 70))
        XCTAssertEqual(mirror.degrees(atHinge: 180), mirror.degrees(atHinge: 175))
    }

    func testWallBlocksBeam() {
        var stage = simpleStage()
        stage.blocks = [Wall(a: Vec(700, 600), b: Vec(700, 800))]
        XCTAssertTrue(Tracer.trace(stage, hinge: 122.5).litTargets.isEmpty)
    }

    func testColoredTargetNeedsMatchingFilter() {
        var stage = simpleStage()
        stage.targets[0].color = .red
        XCTAssertFalse(Tracer.trace(stage, hinge: 122.5).allLit)
        stage.filters = [Filter(a: Vec(700, 600), b: Vec(700, 800), color: .red)]
        let result = Tracer.trace(stage, hinge: 122.5)
        XCTAssertTrue(result.allLit)
        XCTAssertEqual(result.beams.last?.color, .red)
        stage.filters[0].color = .blue
        XCTAssertFalse(Tracer.trace(stage, hinge: 122.5).allLit)
    }

    func testPrismSplitsIntoTwoBeams() {
        var stage = simpleStage()
        stage.prisms = [Prism(center: Vec(700, 700), radius: 20, spread: 30)]
        // 分かれた2本が右上と右下の的に当たる。200 先で ±115 ほど
        let dy = 200 * tan(30 * Double.pi / 180)
        stage.targets = [Target(center: Vec(900, 700 + dy), radius: 20), Target(center: Vec(900, 700 - dy), radius: 20)]
        let result = Tracer.trace(stage, hinge: 122.5)
        XCTAssertTrue(result.allLit)
        XCTAssertEqual(result.beams.count, 3)
    }

    func testMirrorLoopStops() {
        // 向かい合う2枚の鏡の間を垂直に往復する光でも止まる
        let stage = Stage(
            id: "loop", title: "loop",
            hinge: HingeMirror(center: Vec(900, 1300), length: 10, baseDegrees: 0),
            emitters: [Emitter(position: Vec(500, 500), degrees: 90)],
            mirrors: [Mirror(center: Vec(500, 100), length: 100, degrees: 0),
                      Mirror(center: Vec(500, 900), length: 100, degrees: 0)],
            targets: [Target(center: Vec(100, 100), radius: 10)]
        )
        let result = Tracer.trace(stage, hinge: 122.5)
        XCTAssertEqual(result.beams.count, 1)
        XCTAssertLessThanOrEqual(result.beams[0].points.count, Tracer.maxBounces + 3)
    }

    func testStageDecodesWithDefaults() throws {
        let json = """
        {"id":"s1","title":"はじめの光",
         "hinge":{"center":{"x":500,"y":700},"length":220,"baseDegrees":45},
         "emitters":[{"position":{"x":500,"y":100},"degrees":90}],
         "targets":[{"center":{"x":900,"y":700},"radius":40}]}
        """
        let stage = try JSONDecoder().decode(Stage.self, from: Data(json.utf8))
        XCTAssertEqual(stage.width, 1000)
        XCTAssertEqual(stage.hinge.centerHinge, 122.5)
        XCTAssertTrue(stage.mirrors.isEmpty)
        XCTAssertTrue(Tracer.trace(stage, hinge: 122.5).allLit)
    }
}

final class StageCatalogTests: XCTestCase {
    func testBundledStagesLoadInOrder() throws {
        let stages = try StageCatalog.load()
        XCTAssertGreaterThanOrEqual(stages.count, StageCatalog.freeCount)
        XCTAssertEqual(stages.map(\.id), stages.map(\.id).sorted())
    }

    /// どのステージも、遊ぶ範囲の中に「0.5 秒止めて確定」できる幅（2° 以上）の正解がある
    func testEveryStageIsSolvableWithRoomToHold() throws {
        for stage in try StageCatalog.load() {
            let ranges = StageCatalog.solutionRanges(stage)
            let widest = ranges.map { $0.upperBound - $0.lowerBound }.max() ?? 0
            print("stage \(stage.id): \(ranges.map { String(format: "%.1f〜%.1f", $0.lowerBound, $0.upperBound) })")
            XCTAssertGreaterThanOrEqual(widest, 2.0, "stage \(stage.id) has no 2-degree window: \(ranges)")
        }
    }
}
