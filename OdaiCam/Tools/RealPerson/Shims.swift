// Mac でアプリのしばり（Sources/Effects.swift・Backdrop.swift）をそのまま動かすための代わりの部品。
// アプリには入らない（project.yml の sources は Sources と Resources だけ）
import AppKit
import CoreVideo
import Vision

typealias UIColor = NSColor

/// 点検では偽カメラ・デモは使わない（いつも本物の Vision を回す）
enum FakeCamera {
    static let isDemo = false
}

/// デモの役者は使わない（Vision が見つけられなかったら、そのまま「見つからない」）
enum DemoActor {
    static func joints(at t: Double) -> [VNHumanBodyPoseObservation.JointName: CGPoint] { [:] }
    static func mask(at t: Double, into pb: CVPixelBuffer) -> Bool { false }
}

enum Words {
    static func text(_ key: String, language: String) -> String { key }
}
