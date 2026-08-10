# UpdateAlertModifier

ASCII reference layouts for the alerts presented by `UpdateAlertModifier`, driven
by `UpdateService.state`. Kept in sync with the SwiftUI view so the intended
structure stays readable without running the app.

Only one alert is shown at a time, selected by the current `UpdateService.State`.

## Update available (`.available`)

```
┌──────────────────────────────────────────────┐
│ Update available                              │
│                                               │
│ Wietty 1.2.0 is available. You have 1.1.0.    │
│                                               │
│ <release notes, when present>                 │
│                                               │
│   [ Download ] [ Skip This Version ] [ Later ]│
└──────────────────────────────────────────────┘
```

## You are up to date (`.upToDate`)

```
┌──────────────────────────────────────────────┐
│ You are up to date                            │
│                                               │
│ Wietty 1.1.0 is the latest version.           │
│                                               │
│                                    [   OK   ] │
└──────────────────────────────────────────────┘
```

## Update check failed (`.failed`)

```
┌──────────────────────────────────────────────┐
│ Update check failed                           │
│                                               │
│ <failure message>                             │
│                                               │
│                                    [   OK   ] │
└──────────────────────────────────────────────┘
```

## Download complete (`.downloaded`)

```
┌──────────────────────────────────────────────┐
│ Download complete                             │
│                                               │
│ The installer was revealed in Finder. Open    │
│ it, then drag Wietty to your Applications     │
│ folder.                                       │
│                                               │
│                                    [   OK   ] │
└──────────────────────────────────────────────┘
```

Notes:

- `Later`, `OK`: the cancel-role button for each alert; all call `updates.dismiss()`.
- `Download` triggers `updates.download(release)`; `Skip This Version` calls
  `updates.skip(release)` so that version is not offered again.
- Version numbers shown are examples; the live values come from the release and
  `AppVersion.current`.
