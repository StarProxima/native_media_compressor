#include "image_codec.h"

#include <gdk-pixbuf/gdk-pixbuf.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <utility>

namespace native_media_compressor {

namespace {

std::string MimeOf(const std::string& path, GdkPixbufFormat* format) {
  std::string sniffed = SniffImageMime(path);
  if (!sniffed.empty()) return sniffed;
  g_autofree gchar* name = gdk_pixbuf_format_get_name(format);
  static const struct {
    const char* name;
    const char* mime;
  } kKnown[] = {
      {"jpeg", "image/jpeg"}, {"png", "image/png"}, {"gif", "image/gif"},
      {"webp", "image/webp"}, {"bmp", "image/bmp"}, {"tiff", "image/tiff"},
      {"heif", "image/heif"}, {"avif", "image/avif"},
  };
  for (const auto& known : kKnown) {
    if (name != nullptr && strcmp(name, known.name) == 0) return known.mime;
  }
  gchar** mime_types = gdk_pixbuf_format_get_mime_types(format);
  std::string mime = mime_types != nullptr && mime_types[0] != nullptr ? mime_types[0] : "";
  g_strfreev(mime_types);
  return mime;
}

int64_t FrameCount(const std::string& path, const std::string& mime) {
  int64_t frames = -1;
  if (mime == "image/gif") frames = CountGifFrames(path);
  if (mime == "image/webp") frames = CountWebpFrames(path);
  return std::max<int64_t>(frames, 1);
}

// Same mapping as gdk_pixbuf_apply_embedded_orientation, for loaders that do
// not attach the "orientation" option to a downscaled pixbuf.
GdkPixbuf* Orient(GdkPixbuf* source, int orientation) {
  switch (orientation) {
    case 2:
      return gdk_pixbuf_flip(source, TRUE);
    case 3:
      return gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_UPSIDEDOWN);
    case 4:
      return gdk_pixbuf_flip(source, FALSE);
    case 5:
    case 7: {
      GdkPixbuf* rotated = gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_CLOCKWISE);
      if (rotated == nullptr) return nullptr;
      GdkPixbuf* flipped = gdk_pixbuf_flip(rotated, orientation == 5);
      g_object_unref(rotated);
      return flipped;
    }
    case 6:
      return gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_CLOCKWISE);
    case 8:
      return gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_COUNTERCLOCKWISE);
    default:
      return GDK_PIXBUF(g_object_ref(source));
  }
}

GdkPixbuf* FlattenOnWhite(GdkPixbuf* source) {
  const int width = gdk_pixbuf_get_width(source);
  const int height = gdk_pixbuf_get_height(source);
  GdkPixbuf* flat = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, width, height);
  if (flat == nullptr) return nullptr;
  gdk_pixbuf_fill(flat, 0xFFFFFFFF);
  gdk_pixbuf_composite(source, flat, 0, 0, width, height, 0, 0, 1, 1, GDK_INTERP_NEAREST, 255);
  return flat;
}

bool NeedsLoaderPlugin(const std::string& mime) {
  return mime == "image/heic" || mime == "image/heif" || mime == "image/avif" ||
         mime == "image/webp";
}

bool IsUnknownType(const GError* error) {
  return error != nullptr && error->domain == GDK_PIXBUF_ERROR &&
         error->code == GDK_PIXBUF_ERROR_UNKNOWN_TYPE;
}

Outcome Fail(NmcCompressionStatus status, std::string message) {
  return Outcome::Of(status, std::move(message));
}

Outcome Encode(const ImageJob& job, const std::string& output) {
  gint width = 0;
  gint height = 0;
  GdkPixbufFormat* format = gdk_pixbuf_get_file_info(job.source.c_str(), &width, &height);
  if (format == nullptr || width <= 0 || height <= 0) {
    const std::string sniffed = SniffImageMime(job.source);
    if (NeedsLoaderPlugin(sniffed)) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED,
                  "No gdk-pixbuf loader for " + sniffed);
    }
    return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED,
                "Unrecognized or unreadable image");
  }
  const std::string mime = MimeOf(job.source, format);

  // The bounds are on the short and long side, so the factor is the same
  // before and after orientation is applied.
  const double scale = FitScale(width, height, job.bounds);
  const int target_width = static_cast<int>(ScaledSide(width, scale));
  const int target_height = static_cast<int>(ScaledSide(height, scale));

  GError* error = nullptr;
  GdkPixbuf* decoded = gdk_pixbuf_new_from_file_at_scale(job.source.c_str(), target_width,
                                                         target_height, FALSE, &error);
  if (decoded == nullptr) {
    // The HEIF and WebP loaders recognize the file but decode through
    // separately packaged codecs (libheif plugins), so a decoding error there
    // usually means the codec is not installed.
    const NmcCompressionStatus status = IsUnknownType(error) || NeedsLoaderPlugin(mime)
                                            ? NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED
                                            : NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED;
    std::string message = error != nullptr ? error->message : "Decoding failed";
    g_clear_error(&error);
    return Fail(status, std::move(message));
  }

  GdkPixbuf* oriented = nullptr;
  if (gdk_pixbuf_get_option(decoded, "orientation") != nullptr) {
    oriented = gdk_pixbuf_apply_embedded_orientation(decoded);
  } else {
    oriented = Orient(decoded, mime == "image/jpeg" ? ReadJpegOrientation(job.source) : 1);
  }
  g_object_unref(decoded);
  if (oriented == nullptr) {
    return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, "Out of memory");
  }

  const bool jpeg = job.format == NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG;
  if (jpeg && gdk_pixbuf_get_has_alpha(oriented)) {
    GdkPixbuf* flat = FlattenOnWhite(oriented);
    g_object_unref(oriented);
    oriented = flat;
    if (oriented == nullptr) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, "Out of memory");
    }
  }

  gboolean saved;
  if (jpeg) {
    g_autofree gchar* quality =
        g_strdup_printf("%d", static_cast<int>(std::clamp<int64_t>(job.quality, 0, 100)));
    saved = gdk_pixbuf_save(oriented, output.c_str(), "jpeg", &error, "quality", quality,
                            nullptr);
  } else {
    saved = gdk_pixbuf_save(oriented, output.c_str(), "png", &error, nullptr);
  }
  Outcome outcome;
  if (saved) {
    outcome.status = NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED;
    outcome.width = gdk_pixbuf_get_width(oriented);
    outcome.height = gdk_pixbuf_get_height(oriented);
  } else {
    outcome = Fail(IsUnknownType(error) ? NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED
                                        : NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED,
                   error != nullptr ? error->message : "Writing failed");
  }
  g_clear_error(&error);
  g_object_unref(oriented);
  return outcome;
}

}  // namespace

std::optional<ImageInfo> ProbeImageFile(const std::string& path) {
  try {
    gint width = 0;
    gint height = 0;
    GdkPixbufFormat* format = gdk_pixbuf_get_file_info(path.c_str(), &width, &height);
    if (format == nullptr || width <= 0 || height <= 0) return std::nullopt;
    ImageInfo info;
    info.mime_type = MimeOf(path, format);
    const bool swapped = info.mime_type == "image/jpeg" && ReadJpegOrientation(path) >= 5;
    info.width = swapped ? height : width;
    info.height = swapped ? width : height;
    info.frame_count = FrameCount(path, info.mime_type);
    return info;
  } catch (const std::exception&) {
    return std::nullopt;
  }
}

Outcome CompressImageFile(const ImageJob& job) {
  try {
    // Unwinding deletes the temporary file too.
    PendingOutput output(job.destination);
    if (output.destination_is_directory()) {
      return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED,
                         "The destination is a directory");
    }
    return output.Finish(Encode(job, output.path()));
  } catch (const std::exception& error) {
    return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, error.what());
  }
}

}  // namespace native_media_compressor
