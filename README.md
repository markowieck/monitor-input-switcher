# Monitor Input Switcher

MQTT-driven monitor input switching via DDC/CI.

- **macOS**: [`mac/`](mac/README.md) - menu bar app. See its README for
  build instructions, settings, and troubleshooting.
- **Windows**: not built yet.

## Releasing

Pushing a tag matching `v*` (e.g. `v1.0.0`) triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml), which
builds the macOS app as a universal (arm64 + x86_64) binary and attaches
it to a GitHub Release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The release is unsigned/ad-hoc (no Apple Developer account), so
downloaders will need to right-click → Open the first time to get past
Gatekeeper.

You can also trigger a build without tagging via the workflow's "Run
workflow" button in the Actions tab (pass the tag name to attach the
release to).

Once a Windows build exists, add a `build-windows` job to the same
workflow and list it in the `release` job's `needs:` so both platforms
ship together.
