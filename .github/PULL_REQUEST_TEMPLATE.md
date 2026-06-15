<!-- Thanks for contributing to RoonSage! Keep this light — delete what doesn't apply. -->

## What & why

<!-- One or two sentences: what does this change and why? Link any issue. -->

## Track

- [ ] macOS app
- [ ] iOS app
- [ ] Analyzer
- [ ] Shared (Core/UI/Protocol)
- [ ] CI / docs / tooling

## Checklist

- [ ] `swift build -c release` passes (CI is stricter than debug)
- [ ] `swift test` passes for affected package(s)
- [ ] `swiftlint lint --config .swiftlint.yml` is clean
- [ ] iOS: `xcodegen generate` regenerated if `project.yml` changed
- [ ] User-facing strings are Dutch (UI convention); feature names left untranslated
- [ ] No secrets/tokens in code or logs

## Notes for the reviewer

<!-- Screenshots for UI changes, migration notes, anything non-obvious. -->
