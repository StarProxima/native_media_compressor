#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <gtest/gtest.h>

#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "image_codec.h"
#include "media_common.h"
#include "video_queue.h"
#include "video_transcoder.h"

namespace native_media_compressor {
namespace test {

namespace {

std::string TempPath(const std::string& name) {
  return std::string(g_get_tmp_dir()) + "/nmc_test_" + name;
}

void WriteBytes(const std::string& path, const std::vector<uint8_t>& bytes) {
  ASSERT_TRUE(g_file_set_contents(path.c_str(), reinterpret_cast<const gchar*>(bytes.data()),
                                  static_cast<gssize>(bytes.size()), nullptr));
}

std::vector<uint8_t> ReadBytes(const std::string& path) {
  gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(path.c_str(), &contents, &length, nullptr)) return {};
  std::vector<uint8_t> bytes(contents, contents + length);
  g_free(contents);
  return bytes;
}

std::string MakeDirectory() {
  gchar* path = g_dir_make_tmp("nmc_test_XXXXXX", nullptr);
  std::string result = path != nullptr ? path : "";
  g_free(path);
  return result;
}

// Counts files, so a leftover temporary output shows up.
int DirectoryEntries(const std::string& path) {
  GDir* directory = g_dir_open(path.c_str(), 0, nullptr);
  if (directory == nullptr) return -1;
  int count = 0;
  while (g_dir_read_name(directory) != nullptr) count++;
  g_dir_close(directory);
  return count;
}

void RemoveDirectory(const std::string& path) {
  GDir* directory = g_dir_open(path.c_str(), 0, nullptr);
  if (directory == nullptr) return;
  while (const gchar* name = g_dir_read_name(directory)) {
    const std::string child = path + "/" + name;
    if (g_file_test(child.c_str(), G_FILE_TEST_IS_DIR)) {
      g_rmdir(child.c_str());
    } else {
      RemoveFile(child);
    }
  }
  g_dir_close(directory);
  g_rmdir(path.c_str());
}

void Append(std::vector<uint8_t>& bytes, const std::string& text) {
  bytes.insert(bytes.end(), text.begin(), text.end());
}

// APP1 segment holding a big-endian EXIF block with only the orientation tag.
std::vector<uint8_t> ExifSegment(uint8_t orientation) {
  std::vector<uint8_t> segment = {0xFF, 0xE1, 0x00, 34};
  Append(segment, std::string("Exif\0\0", 6));
  segment.insert(segment.end(), {'M', 'M', 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08});
  segment.insert(segment.end(), {0x00, 0x01, 0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01,
                                 0x00, orientation, 0x00, 0x00});
  segment.insert(segment.end(), {0x00, 0x00, 0x00, 0x00});
  return segment;
}

GdkPixbuf* SolidPixbuf(int width, int height, bool alpha, guint32 rgba) {
  GdkPixbuf* pixbuf = gdk_pixbuf_new(GDK_COLORSPACE_RGB, alpha, 8, width, height);
  gdk_pixbuf_fill(pixbuf, rgba);
  return pixbuf;
}

std::string SaveJpegWithOrientation(const std::string& name, int width, int height,
                                    uint8_t orientation) {
  const std::string plain = TempPath(name + "-plain.jpg");
  GdkPixbuf* pixbuf = SolidPixbuf(width, height, false, 0x3366CCFF);
  gdk_pixbuf_save(pixbuf, plain.c_str(), "jpeg", nullptr, nullptr);
  g_object_unref(pixbuf);
  std::vector<uint8_t> jpeg = ReadBytes(plain);
  std::vector<uint8_t> rotated = {0xFF, 0xD8};
  const std::vector<uint8_t> exif = ExifSegment(orientation);
  rotated.insert(rotated.end(), exif.begin(), exif.end());
  rotated.insert(rotated.end(), jpeg.begin() + 2, jpeg.end());
  const std::string path = TempPath(name + ".jpg");
  WriteBytes(path, rotated);
  RemoveFile(plain);
  return path;
}

}  // namespace

TEST(FitScale, UsesTheTighterBound) {
  EXPECT_DOUBLE_EQ(FitScale(1200, 1600, {300, 1000}), 0.25);
  EXPECT_DOUBLE_EQ(FitScale(1920, 1080, {720, 1000}), 1000.0 / 1920);
}

TEST(FitScale, NeverScalesUp) { EXPECT_DOUBLE_EQ(FitScale(1200, 800, {std::nullopt, 4000}), 1.0); }

TEST(FitScale, IgnoresAbsentAndNonPositiveBounds) {
  EXPECT_DOUBLE_EQ(FitScale(1920, 1080, {}), 1.0);
  EXPECT_DOUBLE_EQ(FitScale(1920, 1080, {0, -5}), 1.0);
}

TEST(ScaledSides, RoundImagesAndKeepVideoEven) {
  EXPECT_EQ(ScaledSide(1600, 0.5), 800);
  EXPECT_EQ(ScaledSide(3, 0.01), 1);
  EXPECT_EQ(ScaledEvenSide(1206, 720.0 / 1206), 720);
  EXPECT_EQ(ScaledEvenSide(2622, 720.0 / 1206), 1564);
  EXPECT_EQ(ScaledEvenSide(1081, 1.0), 1080);
  EXPECT_EQ(ScaledEvenSide(1, 0.1), 2);
}

TEST(NormalizeCodec, UsesSharedMimeSpellings) {
  EXPECT_EQ(NormalizeVideoCodec("video/x-h264"), "video/avc");
  EXPECT_EQ(NormalizeVideoCodec("video/x-h265"), "video/hevc");
  EXPECT_EQ(NormalizeVideoCodec("video/x-vp9"), "video/x-vnd.on2.vp9");
  EXPECT_EQ(NormalizeVideoCodec("video/x-av1"), "video/av01");
  EXPECT_EQ(NormalizeAudioCodec("audio/mpeg", 4), "audio/mp4a-latm");
  EXPECT_EQ(NormalizeAudioCodec("audio/mpeg", 1), "audio/mpeg");
  EXPECT_EQ(NormalizeAudioCodec("audio/x-opus", 0), "audio/opus");
  EXPECT_EQ(NormalizeAudioCodec("audio/x-wma", 0), "audio/x-wma");
}

TEST(ReadJpegOrientation, ReadsTheExifTag) {
  const std::string path = SaveJpegWithOrientation("orientation", 8, 4, 6);
  EXPECT_EQ(ReadJpegOrientation(path), 6);
  EXPECT_EQ(SniffImageMime(path), "image/jpeg");
  RemoveFile(path);
}

TEST(ReadJpegOrientation, DefaultsToOne) {
  const std::string path = TempPath("no-exif.txt");
  WriteBytes(path, {'n', 'o', 'p', 'e'});
  EXPECT_EQ(ReadJpegOrientation(path), 1);
  RemoveFile(path);
}

TEST(CountGifFrames, CountsImageDescriptors) {
  std::vector<uint8_t> gif;
  Append(gif, "GIF89a");
  gif.insert(gif.end(), {0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00});
  for (int i = 0; i < 3; i++) {
    gif.insert(gif.end(), {0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00});
    gif.insert(gif.end(), {0x2C, 0, 0, 0, 0, 0x02, 0x00, 0x02, 0x00, 0x00});
    gif.insert(gif.end(), {0x02, 0x02, 0x4C, 0x01, 0x00});
  }
  gif.push_back(0x3B);
  const std::string path = TempPath("frames.gif");
  WriteBytes(path, gif);
  EXPECT_EQ(CountGifFrames(path), 3);
  EXPECT_EQ(SniffImageMime(path), "image/gif");
  RemoveFile(path);
}

TEST(CountWebpFrames, CountsAnimationFrames) {
  std::vector<uint8_t> webp;
  Append(webp, "RIFF");
  webp.insert(webp.end(), {0, 0, 0, 0});
  Append(webp, "WEBPVP8X");
  webp.insert(webp.end(), {10, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0});
  Append(webp, "ANIM");
  webp.insert(webp.end(), {6, 0, 0, 0, 0, 0, 0, 0, 0, 0});
  for (int i = 0; i < 3; i++) {
    Append(webp, "ANMF");
    webp.insert(webp.end(), {3, 0, 0, 0, 0, 0, 0, 0});
  }
  const std::string path = TempPath("frames.webp");
  WriteBytes(path, webp);
  EXPECT_EQ(CountWebpFrames(path), 3);
  EXPECT_EQ(SniffImageMime(path), "image/webp");
  RemoveFile(path);
}

TEST(CountPngFrames, ReadsTheAnimationControlChunk) {
  const auto chunk = [](std::vector<uint8_t>& png, const std::string& type,
                        const std::vector<uint8_t>& data) {
    const auto length = static_cast<uint32_t>(data.size());
    png.insert(png.end(), {static_cast<uint8_t>(length >> 24), static_cast<uint8_t>(length >> 16),
                           static_cast<uint8_t>(length >> 8), static_cast<uint8_t>(length)});
    Append(png, type);
    png.insert(png.end(), data.begin(), data.end());
    png.insert(png.end(), {0, 0, 0, 0});
  };
  std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
  chunk(png, "IHDR", std::vector<uint8_t>(13, 0));
  std::vector<uint8_t> plain = png;
  chunk(png, "acTL", {0, 0, 0, 3, 0, 0, 0, 0});
  chunk(png, "IDAT", {0});
  chunk(plain, "IDAT", {0});
  chunk(plain, "acTL", {0, 0, 0, 3, 0, 0, 0, 0});
  const std::string path = TempPath("frames.png");
  WriteBytes(path, png);
  EXPECT_EQ(CountPngFrames(path), 3);
  WriteBytes(path, plain);
  EXPECT_EQ(CountPngFrames(path), 1);
  RemoveFile(path);
}

TEST(AnimatedPng, ProbesAndCompressesTheFirstFrame) {
  const auto crc32 = [](const uint8_t* data, size_t size) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < size; i++) {
      crc ^= data[i];
      for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xEDB88320 & (0 - (crc & 1)));
    }
    return ~crc;
  };
  const auto be32 = [](std::vector<uint8_t>& out, uint32_t value) {
    out.insert(out.end(), {static_cast<uint8_t>(value >> 24), static_cast<uint8_t>(value >> 16),
                           static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)});
  };
  const auto chunk = [&](std::vector<uint8_t>& out, const char* type,
                         const std::vector<uint8_t>& data) {
    be32(out, static_cast<uint32_t>(data.size()));
    std::vector<uint8_t> body(type, type + 4);
    body.insert(body.end(), data.begin(), data.end());
    out.insert(out.end(), body.begin(), body.end());
    be32(out, crc32(body.data(), body.size()));
  };
  const auto frame_control = [&](uint32_t sequence) {
    std::vector<uint8_t> data;
    for (uint32_t value : {sequence, 40u, 30u, 0u, 0u}) be32(data, value);
    data.insert(data.end(), {0, 1, 0, 10, 0, 0});
    return data;
  };

  const std::string plain = TempPath("apng-plain.png");
  GdkPixbuf* pixbuf = SolidPixbuf(40, 30, false, 0x3366CCFF);
  ASSERT_TRUE(gdk_pixbuf_save(pixbuf, plain.c_str(), "png", nullptr, nullptr));
  g_object_unref(pixbuf);
  const std::vector<uint8_t> source = ReadBytes(plain);
  RemoveFile(plain);

  // Split the plain PNG into chunks and add a second frame reusing its pixels.
  std::vector<uint8_t> apng(source.begin(), source.begin() + 8);
  std::vector<uint8_t> image_data;
  for (size_t pos = 8; pos + 12 <= source.size();) {
    const uint32_t length = (uint32_t{source[pos]} << 24) | (uint32_t{source[pos + 1]} << 16) |
                            (uint32_t{source[pos + 2]} << 8) | source[pos + 3];
    const std::string type(source.begin() + pos + 4, source.begin() + pos + 8);
    const std::vector<uint8_t> data(source.begin() + pos + 8, source.begin() + pos + 8 + length);
    if (type == "IDAT") {
      if (image_data.empty()) {
        chunk(apng, "acTL", {0, 0, 0, 2, 0, 0, 0, 0});
        chunk(apng, "fcTL", frame_control(0));
      }
      image_data.insert(image_data.end(), data.begin(), data.end());
      chunk(apng, "IDAT", data);
    } else if (type == "IEND") {
      chunk(apng, "fcTL", frame_control(1));
      std::vector<uint8_t> frame_data;
      be32(frame_data, 2);
      frame_data.insert(frame_data.end(), image_data.begin(), image_data.end());
      chunk(apng, "fdAT", frame_data);
      chunk(apng, "IEND", {});
    } else {
      chunk(apng, type.c_str(), data);
    }
    pos += 12 + length;
  }

  ImageJob job;
  job.source = TempPath("animated.png");
  job.destination = TempPath("animated-out.jpg");
  job.bounds.max_long_side = 20;
  WriteBytes(job.source, apng);
  const std::optional<ImageInfo> info = ProbeImageFile(job.source);
  ASSERT_TRUE(info.has_value());
  EXPECT_EQ(info->width, 40);
  EXPECT_EQ(info->height, 30);
  EXPECT_EQ(info->frame_count, 2);
  EXPECT_EQ(info->mime_type, "image/png");
  const Outcome outcome = CompressImageFile(job);
  EXPECT_EQ(outcome.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) << outcome.message;
  EXPECT_EQ(outcome.width, 20);
  EXPECT_EQ(outcome.height, 15);
  RemoveFile(job.source);
  RemoveFile(job.destination);
}

TEST(SniffImageMime, TellsHeicFromAvif) {
  std::vector<uint8_t> heic = {0, 0, 0, 24};
  Append(heic, "ftypmif1");
  heic.insert(heic.end(), {0, 0, 0, 0});
  Append(heic, "mif1heic");
  const std::string path = TempPath("brand.heic");
  WriteBytes(path, heic);
  EXPECT_EQ(SniffImageMime(path), "image/heic");

  std::vector<uint8_t> avif = {0, 0, 0, 20};
  Append(avif, "ftypavif");
  avif.insert(avif.end(), {0, 0, 0, 0});
  Append(avif, "mif1");
  WriteBytes(path, avif);
  EXPECT_EQ(SniffImageMime(path), "image/avif");
  RemoveFile(path);
}

TEST(ProbeImageFile, SwapsSidesForExifOrientation) {
  const std::string path = SaveJpegWithOrientation("probe", 40, 20, 6);
  const std::optional<ImageInfo> info = ProbeImageFile(path);
  ASSERT_TRUE(info.has_value());
  EXPECT_EQ(info->width, 20);
  EXPECT_EQ(info->height, 40);
  EXPECT_EQ(info->frame_count, 1);
  EXPECT_EQ(info->mime_type, "image/jpeg");
  RemoveFile(path);
}

TEST(ProbeImageFile, RejectsNonImages) {
  const std::string path = TempPath("not-an-image.jpg");
  WriteBytes(path, std::vector<uint8_t>(64, 'x'));
  EXPECT_FALSE(ProbeImageFile(path).has_value());
  RemoveFile(path);
}

TEST(CompressImageFile, BakesInOrientation) {
  const std::string source = SaveJpegWithOrientation("rotate", 160, 120, 6);
  ImageJob job;
  job.source = source;
  job.destination = TempPath("rotate-out.jpg");
  job.bounds.max_long_side = 80;
  const Outcome outcome = CompressImageFile(job);
  EXPECT_EQ(outcome.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) << outcome.message;
  EXPECT_EQ(outcome.width, 60);
  EXPECT_EQ(outcome.height, 80);
  EXPECT_EQ(outcome.size_bytes, FileSize(job.destination));
  const std::optional<ImageInfo> written = ProbeImageFile(job.destination);
  ASSERT_TRUE(written.has_value());
  EXPECT_EQ(written->width, 60);
  EXPECT_EQ(written->height, 80);
  RemoveFile(source);
  RemoveFile(job.destination);
}

TEST(CompressImageFile, FlattensAlphaOntoWhiteForJpeg) {
  const std::string source = TempPath("alpha.png");
  GdkPixbuf* transparent = SolidPixbuf(400, 200, true, 0x00000000);
  ASSERT_TRUE(gdk_pixbuf_save(transparent, source.c_str(), "png", nullptr, nullptr));
  g_object_unref(transparent);
  ImageJob job;
  job.source = source;
  job.destination = TempPath("alpha-out.jpg");
  job.bounds.max_long_side = 100;
  job.quality = 90;
  const Outcome outcome = CompressImageFile(job);
  ASSERT_EQ(outcome.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) << outcome.message;
  EXPECT_EQ(outcome.width, 100);
  EXPECT_EQ(outcome.height, 50);
  GdkPixbuf* written = gdk_pixbuf_new_from_file(job.destination.c_str(), nullptr);
  ASSERT_NE(written, nullptr);
  const guchar* pixel = gdk_pixbuf_read_pixels(written);
  EXPECT_GT(pixel[0], 240);
  EXPECT_GT(pixel[1], 240);
  EXPECT_GT(pixel[2], 240);
  g_object_unref(written);
  RemoveFile(source);
  RemoveFile(job.destination);
}

TEST(CompressImageFile, WritesPngWithoutScalingUp) {
  const std::string source = TempPath("small.png");
  GdkPixbuf* pixbuf = SolidPixbuf(120, 80, true, 0xFF000080);
  ASSERT_TRUE(gdk_pixbuf_save(pixbuf, source.c_str(), "png", nullptr, nullptr));
  g_object_unref(pixbuf);
  ImageJob job;
  job.source = source;
  job.destination = TempPath("small-out.png");
  job.bounds.max_long_side = 4000;
  job.format = NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_PNG;
  const Outcome outcome = CompressImageFile(job);
  ASSERT_EQ(outcome.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) << outcome.message;
  EXPECT_EQ(outcome.width, 120);
  EXPECT_EQ(outcome.height, 80);
  EXPECT_EQ(ProbeImageFile(job.destination)->mime_type, "image/png");
  RemoveFile(source);
  RemoveFile(job.destination);
}

TEST(CompressImageFile, BrokenInputKeepsTheDestination) {
  const std::string directory = MakeDirectory();
  ImageJob job;
  job.source = directory + "/broken.jpg";
  job.destination = directory + "/out.jpg";
  WriteBytes(job.source, std::vector<uint8_t>(256, 'x'));
  WriteBytes(job.destination, {'s', 't', 'a', 'l', 'e'});
  const Outcome outcome = CompressImageFile(job);
  EXPECT_EQ(outcome.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED);
  EXPECT_EQ(ReadBytes(job.destination), (std::vector<uint8_t>{'s', 't', 'a', 'l', 'e'}));
  EXPECT_EQ(DirectoryEntries(directory), 2);
  RemoveDirectory(directory);
}

TEST(CompressImageFile, CompressesInPlace) {
  const std::string directory = MakeDirectory();
  const std::string path = directory + "/photo.png";
  GdkPixbuf* pixbuf = SolidPixbuf(400, 300, false, 0x3366CCFF);
  ASSERT_TRUE(gdk_pixbuf_save(pixbuf, path.c_str(), "png", nullptr, nullptr));
  g_object_unref(pixbuf);
  ImageJob job;
  job.source = path;
  job.destination = path;
  job.bounds.max_long_side = 200;
  const Outcome outcome = CompressImageFile(job);
  ASSERT_EQ(outcome.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) << outcome.message;
  EXPECT_EQ(outcome.size_bytes, FileSize(path));
  const std::optional<ImageInfo> written = ProbeImageFile(path);
  ASSERT_TRUE(written.has_value());
  EXPECT_EQ(written->mime_type, "image/jpeg");
  EXPECT_EQ(written->width, 200);
  EXPECT_EQ(DirectoryEntries(directory), 1);
  RemoveDirectory(directory);
}

TEST(CompressImageFile, LeavesADirectoryDestinationAlone) {
  const std::string directory = MakeDirectory();
  const std::string source = directory + "/photo.png";
  GdkPixbuf* pixbuf = SolidPixbuf(40, 30, false, 0x3366CCFF);
  ASSERT_TRUE(gdk_pixbuf_save(pixbuf, source.c_str(), "png", nullptr, nullptr));
  g_object_unref(pixbuf);
  const std::string target = directory + "/target";
  ASSERT_EQ(g_mkdir(target.c_str(), 0700), 0);
  ImageJob job;
  job.source = source;
  job.destination = target;
  EXPECT_EQ(CompressImageFile(job).status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED);
  EXPECT_TRUE(g_file_test(target.c_str(), G_FILE_TEST_IS_DIR));
  EXPECT_EQ(DirectoryEntries(directory), 2);
  RemoveDirectory(directory);
}

TEST(PendingOutput, SitsNextToTheDestinationWithItsExtension) {
  PendingOutput output("/some/dir/clip.mp4");
  EXPECT_TRUE(g_str_has_prefix(output.path().c_str(), "/some/dir/"));
  EXPECT_TRUE(g_str_has_suffix(output.path().c_str(), ".mp4"));
  EXPECT_NE(output.path(), "/some/dir/clip.mp4");
}

TEST(VideoQueue, CancelsAQueuedTaskWithoutRunningIt) {
  std::mutex mutex;
  std::condition_variable changed;
  bool started = false;
  bool released = false;
  std::vector<int64_t> ran;
  std::vector<std::pair<int64_t, NmcCompressionStatus>> done;

  {
    VideoQueue queue([&](VideoQueue::Task& task) {
      std::unique_lock<std::mutex> lock(mutex);
      ran.push_back(task.id);
      started = true;
      changed.notify_all();
      changed.wait(lock, [&] { return released; });
      return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED);
    });
    for (int64_t id : {1, 2, 3}) {
      auto task = std::make_shared<VideoQueue::Task>();
      task->id = id;
      task->on_done = [&, id](const Outcome& outcome) {
        std::lock_guard<std::mutex> lock(mutex);
        done.emplace_back(id, outcome.status);
        changed.notify_all();
      };
      queue.Enqueue(task);
    }
    {
      std::unique_lock<std::mutex> lock(mutex);
      changed.wait(lock, [&] { return started; });
    }
    queue.Cancel(2);
    queue.Cancel(42);
    {
      std::lock_guard<std::mutex> lock(mutex);
      // Not ASSERT: returning early would leave the runner blocked forever.
      EXPECT_EQ(done.size(), 1u);
      if (!done.empty()) {
        EXPECT_EQ(done[0].first, 2);
        EXPECT_EQ(done[0].second, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_CANCELLED);
      }
      released = true;
      changed.notify_all();
    }
    std::unique_lock<std::mutex> lock(mutex);
    changed.wait(lock, [&] { return done.size() == 3; });
  }

  EXPECT_EQ(ran, (std::vector<int64_t>{1, 3}));
  EXPECT_EQ(done[1].first, 1);
  EXPECT_EQ(done[2].first, 3);
}

TEST(TranscodeVideo, NonVideoInputIsRejected) {
  VideoJob job;
  job.source = TempPath("not-a-video.mp4");
  job.destination = TempPath("not-a-video-out.mp4");
  WriteBytes(job.source, std::vector<uint8_t>(4096, 'x'));
  std::atomic<bool> cancelled{false};
  const Outcome outcome = TranscodeVideo(job, cancelled, nullptr);
  EXPECT_TRUE(outcome.status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED ||
              outcome.status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED)
      << outcome.status << " " << outcome.message;
  EXPECT_EQ(FileSize(job.destination), -1);
  EXPECT_FALSE(ProbeVideoFile(job.source).has_value());
  RemoveFile(job.source);
}

TEST(TranscodeVideo, CancelledBeforeStartKeepsTheDestination) {
  const std::string directory = MakeDirectory();
  VideoJob job;
  job.source = directory + "/missing.mp4";
  job.destination = directory + "/out.mp4";
  WriteBytes(job.destination, {'s', 't', 'a', 'l', 'e'});
  std::atomic<bool> cancelled{true};
  const Outcome outcome = TranscodeVideo(job, cancelled, nullptr);
  EXPECT_TRUE(outcome.status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_CANCELLED ||
              outcome.status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED);
  EXPECT_EQ(ReadBytes(job.destination), (std::vector<uint8_t>{'s', 't', 'a', 'l', 'e'}));
  EXPECT_EQ(DirectoryEntries(directory), 1);
  RemoveDirectory(directory);
}

TEST(VideoEncoderCandidates, HevcFallsBackToH264) {
  const std::vector<VideoEncoderChoice> hevc = VideoEncoderCandidates(true);
  ASSERT_FALSE(hevc.empty());
  EXPECT_STREQ(hevc.front().encoder, "x265enc");
  EXPECT_STREQ(hevc.front().mime, "video/hevc");
  EXPECT_TRUE(hevc.front().parser_required);
  EXPECT_STREQ(hevc.front().output_caps, "video/x-h265,stream-format=hvc1,alignment=au");
  EXPECT_STREQ(hevc.back().mime, "video/avc");

  const std::vector<VideoEncoderChoice> h264 = VideoEncoderCandidates(false);
  ASSERT_FALSE(h264.empty());
  EXPECT_STREQ(h264.front().encoder, "x264enc");
  for (const VideoEncoderChoice& choice : h264) {
    EXPECT_STREQ(choice.mime, "video/avc");
    EXPECT_FALSE(choice.parser_required);
  }
}

TEST(AacEncoderCandidates, PrefersLibav) {
  const std::vector<const char*> encoders = AacEncoderCandidates();
  ASSERT_EQ(encoders.size(), 3u);
  EXPECT_STREQ(encoders.front(), "avenc_aac");
}

TEST(CombineVideoOrientation, AddsClockwiseTurns) {
  EXPECT_EQ(CombineVideoOrientation(kOrientationIdentity, 0), kOrientationIdentity);
  EXPECT_EQ(CombineVideoOrientation(kOrientationIdentity, 1), kOrientation90R);
  EXPECT_EQ(CombineVideoOrientation(kOrientationIdentity, 3), kOrientation90L);
  EXPECT_EQ(CombineVideoOrientation(kOrientation90R, 1), kOrientation180);
  EXPECT_EQ(CombineVideoOrientation(kOrientation90L, 1), kOrientationIdentity);
  EXPECT_EQ(CombineVideoOrientation(kOrientation180, 2), kOrientationIdentity);
  EXPECT_EQ(CombineVideoOrientation(kOrientation90R, 5), kOrientation180);
  EXPECT_EQ(CombineVideoOrientation(kOrientation90R, -1), kOrientationIdentity);
}

TEST(CombineVideoOrientation, KeepsTheMirrorOfFlippedSources) {
  EXPECT_EQ(CombineVideoOrientation(kOrientationHoriz, 0), kOrientationHoriz);
  EXPECT_EQ(CombineVideoOrientation(kOrientationHoriz, 1), kOrientationUrLl);
  EXPECT_EQ(CombineVideoOrientation(kOrientationHoriz, 2), kOrientationVert);
  EXPECT_EQ(CombineVideoOrientation(kOrientationHoriz, 3), kOrientationUlLr);
  EXPECT_EQ(CombineVideoOrientation(kOrientationUlLr, 1), kOrientationHoriz);
  EXPECT_EQ(CombineVideoOrientation(kOrientationVert, 2), kOrientationHoriz);
  EXPECT_EQ(CombineVideoOrientation(42, 1), kOrientation90R);
}

TEST(ResolveKeptRange, ClampsToTheSource) {
  const std::optional<KeptRange> whole = ResolveKeptRange(std::nullopt, std::nullopt, 5000);
  ASSERT_TRUE(whole.has_value());
  EXPECT_EQ(whole->start_ms, 0);
  EXPECT_EQ(whole->end_ms, 5000);
  EXPECT_FALSE(whole->partial);

  const std::optional<KeptRange> tail = ResolveKeptRange(1000, 30000, 2000);
  ASSERT_TRUE(tail.has_value());
  EXPECT_EQ(tail->start_ms, 1000);
  EXPECT_EQ(tail->end_ms, 2000);
  EXPECT_TRUE(tail->partial);

  const std::optional<KeptRange> head = ResolveKeptRange(std::nullopt, 3000, 5000);
  ASSERT_TRUE(head.has_value());
  EXPECT_EQ(head->start_ms, 0);
  EXPECT_EQ(head->end_ms, 3000);
  EXPECT_TRUE(head->partial);

  const std::optional<KeptRange> negative = ResolveKeptRange(-500, 5000, 5000);
  ASSERT_TRUE(negative.has_value());
  EXPECT_EQ(negative->start_ms, 0);
  EXPECT_FALSE(negative->partial);
}

TEST(ResolveKeptRange, HandlesAnUnknownDuration) {
  const std::optional<KeptRange> open = ResolveKeptRange(2000, std::nullopt, 0);
  ASSERT_TRUE(open.has_value());
  EXPECT_FALSE(open->end_ms.has_value());
  EXPECT_TRUE(open->partial);

  const std::optional<KeptRange> bounded = ResolveKeptRange(std::nullopt, 4000, 0);
  ASSERT_TRUE(bounded.has_value());
  EXPECT_EQ(bounded->end_ms, 4000);
  EXPECT_TRUE(bounded->partial);
}

TEST(ResolveKeptRange, RejectsARangeThatKeepsNothing) {
  EXPECT_FALSE(ResolveKeptRange(5000, std::nullopt, 5000).has_value());
  EXPECT_FALSE(ResolveKeptRange(6000, 9000, 5000).has_value());
  EXPECT_FALSE(ResolveKeptRange(3000, 3000, 5000).has_value());
  EXPECT_FALSE(ResolveKeptRange(3000, 1000, 5000).has_value());
  EXPECT_FALSE(ResolveKeptRange(std::nullopt, 0, 5000).has_value());
}

TEST(TrimSample, KeepsTheHalfOpenRange) {
  const int64_t second = 1000000000;
  EXPECT_EQ(TrimSample(-1, 0, -1), TrimStep::kDrop);
  EXPECT_EQ(TrimSample(second, 2 * second, 5 * second), TrimStep::kDrop);
  EXPECT_EQ(TrimSample(2 * second, 2 * second, 5 * second), TrimStep::kKeep);
  EXPECT_EQ(TrimSample(5 * second - 1, 2 * second, 5 * second), TrimStep::kKeep);
  EXPECT_EQ(TrimSample(5 * second, 2 * second, 5 * second), TrimStep::kEnd);
  EXPECT_EQ(TrimSample(100 * second, 2 * second, -1), TrimStep::kKeep);
}

TEST(PickThumbnailFrame, KeepsTheLastFrameAtOrBeforeThePosition) {
  EXPECT_EQ(PickThumbnailFrame(0, 1000, false), FramePick::kTake);
  EXPECT_EQ(PickThumbnailFrame(1000, 1000, true), FramePick::kTake);
  EXPECT_EQ(PickThumbnailFrame(1033, 1000, true), FramePick::kStop);
  EXPECT_EQ(PickThumbnailFrame(1033, 1000, false), FramePick::kTakeAndStop);
  EXPECT_EQ(PickThumbnailFrame(-1, 1000, true), FramePick::kTake);
}

TEST(ThumbnailSeekMs, StaysInsideTheSource) {
  EXPECT_EQ(ThumbnailSeekMs(0, 5000), -1);
  EXPECT_EQ(ThumbnailSeekMs(1000, 5000), 1000);
  EXPECT_EQ(ThumbnailSeekMs(30000, 5000), 4999);
  EXPECT_EQ(ThumbnailSeekMs(30000, 0), 30000);
}

TEST(RgbRowStride, PrefersFourBytePaddedRows) {
  EXPECT_EQ(RgbRowStride(3, 2, 24), 12);
  EXPECT_EQ(RgbRowStride(3, 2, 18), 9);
  EXPECT_EQ(RgbRowStride(3, 2, 17), 0);
  EXPECT_EQ(RgbRowStride(4, 2, 24), 12);
  EXPECT_EQ(RgbRowStride(0, 2, 24), 0);
}

TEST(WriteRgbFrame, ScalesDownWithoutGrowing) {
  const int width = 64;
  const int height = 36;
  const int stride = RgbRowStride(width, height, static_cast<size_t>(192 * height));
  ASSERT_EQ(stride, 192);
  std::vector<uint8_t> pixels(static_cast<size_t>(stride) * height, 0x80);
  const std::string output = TempPath("frame-out.jpg");
  const Outcome scaled = WriteRgbFrame(RgbFrame{pixels.data(), width, height, stride},
                                       {std::nullopt, 32}, NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG,
                                       80, output);
  ASSERT_EQ(scaled.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) << scaled.message;
  EXPECT_EQ(scaled.width, 32);
  EXPECT_EQ(scaled.height, 18);
  EXPECT_EQ(ProbeImageFile(output)->mime_type, "image/jpeg");

  const Outcome kept = WriteRgbFrame(RgbFrame{pixels.data(), width, height, stride},
                                     {std::nullopt, 4000}, NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_PNG,
                                     80, output);
  ASSERT_EQ(kept.status, NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) << kept.message;
  EXPECT_EQ(kept.width, width);
  EXPECT_EQ(kept.height, height);
  RemoveFile(output);
}

TEST(VideoThumbnail, NonVideoInputLeavesNoOutput) {
  const std::string directory = MakeDirectory();
  ThumbnailJob job;
  job.source = directory + "/not-a-video.mp4";
  job.destination = directory + "/frame.jpg";
  WriteBytes(job.source, std::vector<uint8_t>(4096, 'x'));
  const Outcome outcome = VideoThumbnail(job);
  EXPECT_TRUE(outcome.status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED ||
              outcome.status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED)
      << outcome.status << " " << outcome.message;
  EXPECT_EQ(DirectoryEntries(directory), 1);
  RemoveDirectory(directory);
}

}  // namespace test
}  // namespace native_media_compressor
