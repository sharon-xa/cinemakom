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

- *(none yet)*

**To update:** copy the new version over this one (keeping the exclusions
above), then re-apply the changes listed here and check them against
docs/PLAYER.md §14.
