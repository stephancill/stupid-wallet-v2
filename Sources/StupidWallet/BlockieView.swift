import SwiftUI

#if os(iOS)
  import UIKit

  struct BlockieView: View {
    let seed: String

    var body: some View {
      Image(uiImage: Blockie.make(seed: seed))
        .resizable()
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.2), lineWidth: 1))
    }
  }

  private enum Blockie {
    static func make(seed: String) -> UIImage {
      var random = Random(seed: seed)
      let foreground = random.color()
      let background = random.color()
      let spot = random.color()
      var pixels: [Int] = []
      for _ in 0..<8 {
        var row = (0..<4).map { _ in Int(floor(random.next() * 2.3)) }
        row.append(contentsOf: row.reversed())
        pixels.append(contentsOf: row)
      }

      let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
      return renderer.image { context in
        for index in pixels.indices {
          let color =
            switch pixels[index] {
            case 1: foreground
            case 2: spot
            default: background
            }
          color.setFill()
          context.fill(
            CGRect(x: (index % 8) * 4, y: (index / 8) * 4, width: 4, height: 4))
        }
      }
    }

    private struct Random {
      var state = [UInt32](repeating: 0, count: 4)

      init(seed: String) {
        for (index, scalar) in seed.unicodeScalars.enumerated() {
          let slot = index % 4
          state[slot] = (state[slot] &* 31) &+ scalar.value
        }
      }

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

      mutating func color() -> UIColor {
        let hue = next() * 360
        let saturation = (next() * 60 + 40) / 100
        let lightness = (next() + next() + next() + next()) * 25 / 100
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let component = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let offset = lightness - chroma / 2
        let rgb: (Double, Double, Double) =
          switch hue {
          case 0..<60: (chroma, component, 0)
          case 60..<120: (component, chroma, 0)
          case 120..<180: (0, chroma, component)
          case 180..<240: (0, component, chroma)
          case 240..<300: (component, 0, chroma)
          default: (chroma, 0, component)
          }
        return UIColor(red: rgb.0 + offset, green: rgb.1 + offset, blue: rgb.2 + offset, alpha: 1)
      }
    }
  }
#endif
