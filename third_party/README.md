# Vendored packages

Packages we build from a copy here instead of pub.dev, through
`dependency_overrides` in `pubspec.yaml`. Each one says which upstream version
it is and what we changed, so it can be compared and updated.

## media_kit_video 2.0.1

From pub.dev ([media-kit/media-kit](https://github.com/media-kit/media-kit),
MIT, `LICENSE`), without its example app and its iOS and macOS code (Apple
platforms aren't supported, AGENTS.md).

**Changed: Linux only** (`linux/`). Windows, Android and the Dart code are
upstream's. Nothing else changed:

- **The render waits for a frame's display time only while the video is
  alone on screen** (2026-11-27, docs/PLAYER.md §14): `VideoOutput` keeps a
  `block_for_target_time` flag (atomic, 1 by default) that `texture_gl.cc`
  passes as `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME`; the app sets it through
  a new channel method, `VideoOutputManager.SetBlockForTargetTime`
  (`handle`: string, `block`: bool), from `MediaKitEngine.setVideoAlone`.
  Files: `video_output.{h,cc}`, `video_output_manager.{h,cc}`,
  `media_kit_video_plugin.cc`, `texture_gl.cc`, each marked `Cinemakom`.

**To update:** copy the new version over this one (keeping the exclusions
above), then re-apply the changes listed here and check them against
docs/PLAYER.md §14.
