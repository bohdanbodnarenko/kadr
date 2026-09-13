import Foundation

/// Which way a scrolling capture grows (docs/03 §1.6, CleanShot §4.8).
public enum ScrollAxis: String, Sendable, Hashable, Codable, CaseIterable {
  case vertical
  case horizontal
}
