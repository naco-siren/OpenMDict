//
//  MDictPerfLog.swift
//
//  `OSSignposter` instances for the OpenMDict core lib so hosts can profile
//  dictionary loading in Instruments (Points of Interest template) or
//  filter unified-log output on-device.
//
//  Usage from Instruments:
//    1. Profile the iOS app in Instruments.
//    2. Pick the "Points of Interest" or "os_signpost" template.
//    3. Filter by subsystem `io.github.naco-siren.openmdict`.
//
//  Usage from `log stream` (attached device or Mac):
//    log stream --predicate 'subsystem == "io.github.naco-siren.openmdict"'
//
//  This instrumentation is always-on. `OSSignposter` has essentially zero
//  cost when no one is collecting events (the underlying `os_signpost`
//  intrinsic checks a single flag and returns), so there's no reason to
//  conditionally compile it out for release.
//

import os

/// Shared signposter for all core-lib performance intervals. Thread-safe;
/// can be captured by any thread / actor without ceremony.
///
/// Category `"perf"` groups the signposts in Instruments so they don't
/// mix with app-level events from other subsystems. The subsystem matches
/// the iOS app's bundle identifier for consistency in log filters.
internal let mdictPerfSignposter = OSSignposter(
    subsystem: "io.github.naco-siren.openmdict",
    category: "perf"
)
