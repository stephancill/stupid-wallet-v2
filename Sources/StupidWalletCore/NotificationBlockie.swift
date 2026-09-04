import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic 8x8 blockie renderer shared by the app and the Notification
/// Service Extension so both targets draw the same account visual. It matches the
/// existing app account blockie pixel grid and is rendered to PNG via Core
/// Graphics (no UIKit/SwiftUI), so the same code runs in both processes.
public enum NotificationBlockie {
  public struct RGB: Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) {
      self.red = red
      self.green = green
      self.blue = blue
    }
  }

  /// 64 tile classes in the 8x8 grid (0 = background, 1 = foreground, 2 = accent).
  public static func pixels(for seed: String) -> [Int] {
    let state = seedHash(seed)
    var generator = Random(state: state)
    var pixels: [Int] = []
    for _ in 0..<8 {
      var row = (0..<4).map { _ in Int(floor(generator.next() * 2.3)) }
      row.append(contentsOf: row.reversed())
      pixels.append(contentsOf: row)
    }
    return pixels
  }

  public static func renderPNG(seed: String, pixelsPerCell: Int = 12) -> Data? {
    guard pixelsPerCell > 0 else { return nil }
    let grid = pixels(for: seed)
    let (foreground, background, accent) = palette(for: seed)
    let cells = 8
    let width = cells * pixelsPerCell
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: width,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    for index in grid.indices {
      let value = grid[index]
      let rgb: RGB = value == 1 ? foreground : value == 2 ? accent : background
      context.setFillColor(
        CGColor(
          red: CGFloat(rgb.red) / 255,
          green: CGFloat(rgb.green) / 255,
          blue: CGFloat(rgb.blue) / 255,
          alpha: 1)
      )
      let col = index % cells
      let row = index / cells
      context.fill(
        CGRect(
          x: col * pixelsPerCell, y: row * pixelsPerCell, width: pixelsPerCell,
          height: pixelsPerCell))
    }

    guard let image = context.makeImage() else { return nil }
    guard let data = CFDataCreateMutable(nil, 0) else { return nil }
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  // MARK: - Deterministic PRNG (matches the app blockie seed handling).

  private struct Random {
    var state: [UInt32]

    mutating func next() -> Double {
      let value = state[0] ^ (state[0] << 11)
      state[0] = state[1]
      state[1] = state[2]
      state[2] = state[3]
      let tail = Int32(bitPattern: state[3])
      let mixed = Int32(bitPattern: value)
      state[3] = UInt32(bitPattern: tail ^ (tail >> 19) ^ mixed ^ (mixed >> 8))
      return Double(state[3]) / Double(Int32.max)
    }
  }

  private static func seedHash(_ seed: String) -> [UInt32] {
    var state = [UInt32](repeating: 0, count: 4)
    for (index, scalar) in seed.unicodeScalars.enumerated() {
      let slot = index % 4
      state[slot] = (state[slot] &* 31) &+ scalar.value
    }
    return state
  }

  private static func palette(for seed: String) -> (foreground: RGB, background: RGB, accent: RGB) {
    var random = Random(state: seedHash(seed))
    let foreground = color(from: &random)
    let background = color(from: &random)
    let accent = color(from: &random)
    return (foreground, background, accent)
  }

  private static func color(from random: inout Random) -> RGB {
    let hue = random.next() * 360
    let saturation = (random.next() * 60 + 40) / 100
    let lightness = (random.next() + random.next() + random.next() + random.next()) * 25 / 100
    return hsv(hue: hue, saturation: saturation, lightness: lightness)
  }

  private static func hsv(hue: Double, saturation: Double, lightness: Double) -> RGB {
    let chroma = (1 - abs(2 * lightness - 1)) * saturation
    let component = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
    let offset = lightness - chroma / 2
    let rgb: (Double, Double, Double)
    switch hue {
    case 0..<60: rgb = (chroma, component, 0)
    case 60..<120: rgb = (component, chroma, 0)
    case 120..<180: rgb = (0, chroma, component)
    case 180..<240: rgb = (0, component, chroma)
    case 240..<300: rgb = (component, 0, chroma)
    default: rgb = (chroma, 0, component)
    }
    return RGB(
      red: UInt8(((rgb.0 + offset).clamped01) * 255),
      green: UInt8(((rgb.1 + offset).clamped01) * 255),
      blue: UInt8(((rgb.2 + offset).clamped01) * 255))
  }
}

extension Double {
  fileprivate var clamped01: Double { min(max(self, 0), 1) }
}
