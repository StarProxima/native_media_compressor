import Foundation
import ImageIO

/// Picks the metadata of a source image worth carrying into a re-encoded
/// copy.
enum ImageMetadata {
  /// Dictionaries describing the capture rather than the stored pixels.
  /// Format-specific ones (JFIF, PNG, HEIF) and pixel layout keys are left to
  /// the encoder, which knows the output it writes.
  private static let keptDictionaries: [CFString] = [
    kCGImagePropertyExifDictionary,
    kCGImagePropertyExifAuxDictionary,
    kCGImagePropertyTIFFDictionary,
    kCGImagePropertyGPSDictionary,
    kCGImagePropertyIPTCDictionary,
    kCGImagePropertyMakerAppleDictionary,
    kCGImagePropertyMakerCanonDictionary,
    kCGImagePropertyMakerNikonDictionary,
    kCGImagePropertyMakerMinoltaDictionary,
    kCGImagePropertyMakerFujiDictionary,
    kCGImagePropertyMakerOlympusDictionary,
    kCGImagePropertyMakerPentaxDictionary,
  ]

  /// Properties from `CGImageSourceCopyPropertiesAtIndex` to write with an
  /// image of `width` x `height` whose pixels already have the orientation
  /// applied: the orientation is reset to normal, or viewers would turn the
  /// picture a second time.
  static func kept(from source: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
    var kept: [CFString: Any] = [:]
    for key in keptDictionaries {
      if let dictionary = source[key] as? [CFString: Any] { kept[key] = dictionary }
    }
    kept[kCGImagePropertyOrientation] = 1
    if var tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      tiff[kCGImagePropertyTIFFOrientation] = 1
      kept[kCGImagePropertyTIFFDictionary] = tiff
    }
    if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
      exif[kCGImagePropertyExifPixelXDimension] = width
      exif[kCGImagePropertyExifPixelYDimension] = height
      kept[kCGImagePropertyExifDictionary] = exif
    }
    return kept
  }
}
