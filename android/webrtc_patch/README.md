# flutter_webrtc MediaProjection stop notification patch

Pinned upstream: flutter_webrtc `1.6.2+hotfix.3`.

Original source: https://github.com/flutter-webrtc/flutter-webrtc/blob/v1.6.2%2Bhotfix.3/android/src/main/java/com/cloudwebrtc/webrtc/GetUserMediaImpl.java

Original SHA-256: `f0edbac2b7253562137dd3b5d04ef08a777b6978ae61725beda3a147fcfb99fb`

Patched SHA-256: `64515ec38d2dc49bdf176c06c7b8013c8a198817273d8d3793ca2413366ba500`

MIT license: see LICENSE in this directory.

Changes:

- Increment a capture generation on each explicit permission request.
- Remember the generation for each created screen capture.
- On MediaProjection stop, notify only the current generation via an explicit-package broadcast `com.familyhelper.CAPTURE_STOPPED`.

The host receiver is not exported and immediately disarms native gestures before asking Dart to close media. The host ignores an old stop broadcast if no capture is active.

`android/build.gradle` substitutes this Java source only within the flutter_webrtc Gradle subproject. The shared Pub cache is unchanged. On any package update, compare upstream, reapply this minimal patch and update both hashes. Do not silently continue using this file with another plugin version.
