#include "image_codec.h"

#include <gdk-pixbuf/gdk-pixbuf.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <initializer_list>
#include <utility>

#include "jpeg_exif.h"

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

// gdk-pixbuf 2.44 with glycin loaders gives no file info for an animated PNG,
// so PNG sizes fall back to the file header.
bool ReadImageHeader(const std::string& path, gint* width, gint* height, std::string* mime) {
  GdkPixbufFormat* format = gdk_pixbuf_get_file_info(path.c_str(), width, height);
  if (format != nullptr && *width > 0 && *height > 0) {
    *mime = MimeOf(path, format);
    return true;
  }
  if (ReadPngSize(path, width, height)) {
    *mime = "image/png";
    return true;
  }
  return false;
}

// Some gdk-pixbuf versions refuse APNG files outright, so the first frame is
// decoded from the default image with the animation chunks stripped.
GdkPixbuf* DecodePngAtSize(const std::string& png, int width, int height, GError** error) {
  GdkPixbufLoader* loader = gdk_pixbuf_loader_new_with_type("png", error);
  if (loader == nullptr) return nullptr;
  gdk_pixbuf_loader_set_size(loader, width, height);
  const bool written = gdk_pixbuf_loader_write(
      loader, reinterpret_cast<const guchar*>(png.data()), png.size(), error);
  // A loader must be closed even after a failed write.
  const bool closed = gdk_pixbuf_loader_close(loader, written ? error : nullptr);
  GdkPixbuf* pixbuf = written && closed ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
  GdkPixbuf* result = nullptr;
  if (pixbuf != nullptr) {
    result = gdk_pixbuf_get_width(pixbuf) == width && gdk_pixbuf_get_height(pixbuf) == height
                 ? GDK_PIXBUF(g_object_ref(pixbuf))
                 : gdk_pixbuf_scale_simple(pixbuf, width, height, GDK_INTERP_BILINEAR);
  }
  g_object_unref(loader);
  return result;
}

int64_t FrameCount(const std::string& path, const std::string& mime) {
  int64_t frames = -1;
  if (mime == "image/gif") frames = CountGifFrames(path);
  if (mime == "image/webp") frames = CountWebpFrames(path);
  if (mime == "image/png") frames = CountPngFrames(path);
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

std::string WritableFormat(std::initializer_list<const char*> names) {
  GSList* formats = gdk_pixbuf_get_formats();
  std::string found;
  for (GSList* item = formats; item != nullptr && found.empty(); item = item->next) {
    auto* format = static_cast<GdkPixbufFormat*>(item->data);
    if (!gdk_pixbuf_format_is_writable(format)) continue;
    g_autofree gchar* name = gdk_pixbuf_format_get_name(format);
    for (const char* candidate : names) {
      if (name != nullptr && strcmp(name, candidate) == 0) found = name;
    }
  }
  g_slist_free(formats);
  return found;
}

// gdk-pixbuf writes JPEG and PNG itself; WebP and HEIF come from separately
// packaged loader modules, which may be missing or load-only.
std::string SaverName(NmcImageFormat format) {
  switch (format) {
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG:
      return "jpeg";
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_PNG:
      return "png";
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_WEBP:
      return WritableFormat({"webp"});
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_HEIC:
      return WritableFormat({"heif", "heic"});
  }
  return {};
}

const char* OutputMime(NmcImageFormat format) {
  switch (format) {
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG:
      return "image/jpeg";
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_PNG:
      return "image/png";
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_WEBP:
      return "image/webp";
    case NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_HEIC:
      return "image/heic";
  }
  return "";
}

Outcome NoEncoder(NmcImageFormat format) {
  return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED,
              std::string("No gdk-pixbuf encoder for ") + OutputMime(format));
}

// Takes ownership of `image`.
Outcome Save(GdkPixbuf* image, NmcImageFormat format, int64_t quality, const std::string& output) {
  const std::string saver = SaverName(format);
  if (saver.empty()) {
    g_object_unref(image);
    return NoEncoder(format);
  }
  const bool jpeg = format == NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG;
  if (jpeg && gdk_pixbuf_get_has_alpha(image)) {
    GdkPixbuf* flat = FlattenOnWhite(image);
    g_object_unref(image);
    image = flat;
    if (image == nullptr) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, "Out of memory");
    }
  }

  GError* error = nullptr;
  gboolean saved;
  if (format == NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_PNG) {
    saved = gdk_pixbuf_save(image, output.c_str(), "png", &error, nullptr);
  } else {
    g_autofree gchar* level =
        g_strdup_printf("%d", static_cast<int>(std::clamp<int64_t>(quality, 0, 100)));
    saved = gdk_pixbuf_save(image, output.c_str(), saver.c_str(), &error, "quality", level,
                            nullptr);
  }
  Outcome outcome;
  if (saved && SniffImageMime(output) != OutputMime(format)) {
    // A module registered under the name may still write another container
    // (HEIF with AV1 is AVIF); that is not the format that was asked for.
    outcome = NoEncoder(format);
  } else if (saved) {
    outcome.status = NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED;
    outcome.width = gdk_pixbuf_get_width(image);
    outcome.height = gdk_pixbuf_get_height(image);
  } else {
    const bool unsupported =
        IsUnknownType(error) || (error != nullptr && error->domain == GDK_PIXBUF_ERROR &&
                                 error->code == GDK_PIXBUF_ERROR_UNSUPPORTED_OPERATION);
    outcome = Fail(unsupported ? NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED
                               : NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED,
                   error != nullptr ? error->message : "Writing failed");
  }
  g_clear_error(&error);
  g_object_unref(image);
  return outcome;
}

Outcome Encode(const ImageJob& job, const std::string& output) {
  if (SaverName(job.format).empty()) return NoEncoder(job.format);
  gint width = 0;
  gint height = 0;
  std::string mime;
  if (!ReadImageHeader(job.source, &width, &height, &mime)) {
    const std::string sniffed = SniffImageMime(job.source);
    if (NeedsLoaderPlugin(sniffed)) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED,
                  "No gdk-pixbuf loader for " + sniffed);
    }
    return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED,
                "Unrecognized or unreadable image");
  }

  // The bounds are on the short and long side, so the factor is the same
  // before and after orientation is applied.
  const double scale = FitScale(width, height, job.bounds);
  const int target_width = static_cast<int>(ScaledSide(width, scale));
  const int target_height = static_cast<int>(ScaledSide(height, scale));

  GError* error = nullptr;
  GdkPixbuf* decoded = nullptr;
  std::string default_image;
  if (mime == "image/png" && ReadApngDefaultImage(job.source, &default_image)) {
    decoded = DecodePngAtSize(default_image, target_width, target_height, &error);
  } else {
    decoded = gdk_pixbuf_new_from_file_at_scale(job.source.c_str(), target_width, target_height,
                                                FALSE, &error);
  }
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
  Outcome outcome = Save(oriented, job.format, job.quality, output);
  if (outcome.status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED &&
      job.keep_metadata && job.format == NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG &&
      mime == "image/jpeg") {
    std::string error;
    if (!CopyJpegExif(job.source, output, &error)) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED,
                  "Could not write the metadata: " + error);
    }
  }
  return outcome;
}

}  // namespace

Outcome WriteRgbFrame(const RgbFrame& frame, const SizeBounds& bounds, NmcImageFormat format,
                      int64_t quality, const std::string& output) {
  try {
    if (frame.pixels == nullptr || frame.width <= 0 || frame.height <= 0 ||
        frame.stride < frame.width * 3) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, "No frame was decoded");
    }
    // gdk-pixbuf only reads the wrapped pixels; the copy or the scaled image
    // owns its own memory before the caller's buffer goes away.
    GdkPixbuf* wrapped = gdk_pixbuf_new_from_data(frame.pixels, GDK_COLORSPACE_RGB, FALSE, 8,
                                                  frame.width, frame.height, frame.stride,
                                                  nullptr, nullptr);
    if (wrapped == nullptr) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, "Out of memory");
    }
    const double scale = FitScale(frame.width, frame.height, bounds);
    const int width = static_cast<int>(ScaledSide(frame.width, scale));
    const int height = static_cast<int>(ScaledSide(frame.height, scale));
    GdkPixbuf* image = width == frame.width && height == frame.height
                           ? gdk_pixbuf_copy(wrapped)
                           : gdk_pixbuf_scale_simple(wrapped, width, height, GDK_INTERP_BILINEAR);
    g_object_unref(wrapped);
    if (image == nullptr) {
      return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, "Out of memory");
    }
    return Save(image, format, quality, output);
  } catch (const std::exception& error) {
    return Fail(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, error.what());
  }
}

std::optional<ImageInfo> ProbeImageFile(const std::string& path) {
  try {
    gint width = 0;
    gint height = 0;
    ImageInfo info;
    if (!ReadImageHeader(path, &width, &height, &info.mime_type)) return std::nullopt;
    const bool swapped = info.mime_type == "image/jpeg" && ReadJpegOrientation(path) >= 5;
    info.width = swapped ? height : width;
    info.height = swapped ? width : height;
    info.frame_count = FrameCount(path, info.mime_type);
    if (const int64_t size = FileSize(path); size >= 0) info.size_bytes = size;
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
