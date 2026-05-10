// mpd — Runtime-level hook events
//
// Reserved for events fired around runtime lifecycle — e.g. when a
// runtime is built, started, stopped, or removed. v1 ships none of
// these because no concrete need has surfaced yet; per docs/HOOKS.md
// §"Future trajectory", we add events only when there's a real use
// case driving them.
//
// When a runtime event lands, define it here. Examples that may show
// up:
//
//   - EventRuntimePreBuild   (assets layer pre-build customization)
//   - EventRuntimePostBuild  (assets layer post-build customization)
//   - EventRuntimePreStart   (per-runtime warm-up)
//   - EventRuntimePostStart  (per-runtime announcement)

import Foundation
