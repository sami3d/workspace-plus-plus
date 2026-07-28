### Summary

<!-- what changes, and why -->

### Linked issue(s)

<!-- closes #N / refs #N -->

### Verification

- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — passes locally
- [ ] Workspace++ builds Release via `xcodegen generate` + `xcodebuild`
- [ ] `cd RaycastExtension && npm run lint && npm run build` passes when Raycast code changed
- [ ] Manually smoke-tested on macOS (state which version and what scenario)

### Design impact

<!-- if this changes a recorded design decision in docs/superpowers/specs/, add or update a dated "Design Revision YYYY-MM-DD" entry there in this PR -->

### Screenshots (if UI changed)

<!-- before/after -->
