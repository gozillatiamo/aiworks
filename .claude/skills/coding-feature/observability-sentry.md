# Observability with Sentry (logging · tracing · metrics)

How the app implements logging, tracing, and error/performance monitoring on Android + iOS. **Sentry is the single observability backend** — do not introduce a second one. Apply this whenever you add or modify a feature.

> SDK moves fast — verify option names against https://docs.sentry.io/platforms/dart/guides/flutter/ before relying on anything here. Verified against `sentry_flutter` **9.21.0** (latest in the 9.x line).

## 1. SDK & versions

- `sentry_flutter` **9.0+** (use latest 9.x).
- `sentry_logging` (same major as `sentry_flutter`) — bridges the Dart `logging` package into Sentry.
- Requires **Dart ≥ 3.5** and **Flutter ≥ 3.24**. Confirm against the chosen version's `pubspec.yaml` before bumping.
- Optional: `sentry_dio` (if the app uses Dio) for automatic HTTP tracing; `sentry_dart_plugin` for CI symbol upload.

```yaml
# pubspec.yaml
dependencies:
  sentry_flutter: ^9.21.0
  sentry_logging: ^9.21.0
  logging: ^1.2.0
dev_dependencies:
  sentry_dart_plugin: ^3.0.0   # CI symbol upload
```

## 2. Initialization — minimal working `main.dart`

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sentry_logging/sentry_logging.dart';

Future<void> main() async {
  // Forward all app logging through dart:logging (see §4). No raw print().
  Logger.root.level = kReleaseMode ? Level.INFO : Level.ALL;

  await SentryFlutter.init(
    (options) {
      options.dsn = const String.fromEnvironment('SENTRY_DSN');

      // §5 Environment derived from build mode.
      options.environment = kReleaseMode
          ? 'production'
          : (kProfileMode ? 'profile' : 'development');
      // e.g. "your-app@1.2.0+34" — pass via --dart-define at build time.
      options.release = const String.fromEnvironment('APP_RELEASE');

      // §4 Structured logs -> Sentry, and route dart:logging records in too.
      options.enableLogs = true;
      options.addIntegration(
        LoggingIntegration(
          minBreadcrumbLevel: Level.INFO,   // INFO+ become breadcrumbs
          minEventLevel: Level.SEVERE,      // SEVERE+ become Sentry events
        ),
      );

      // §3 Tracing — keep production LOW (see §3).
      options.tracesSampleRate = kReleaseMode ? 0.2 : 1.0;

      // §5 Session replay — privacy-first; widgets masked by default (§7).
      options.replay.sessionSampleRate = 0.0;                 // don't record everyone
      options.replay.onErrorSampleRate = kReleaseMode ? 0.1 : 1.0;

      // §7 Privacy — only send PII when EU consent is granted.
      options.sendDefaultPii = false;

      // §7 Last-line PII scrubbing before anything leaves the device.
      options.beforeSend = (event, hint) => _scrubPii(event);
    },
    // The SDK installs FlutterError.onError + PlatformDispatcher.onError and
    // runs this inside its own guarded zone. Do NOT wrap in runZonedGuarded.
    appRunner: () => runApp(SentryWidget(child: const MyApp())),
  );
}

SentryEvent? _scrubPii(SentryEvent event) {
  // Strip emails, tokens, exact location, etc. before send. Return null to drop.
  return event;
}
```

## 3. Error capture — all three channels (verify, don't duplicate)

The SDK auto-hooks the standard channels when you pass `appRunner:`:

| Channel | Who installs it |
| --- | --- |
| `FlutterError.onError` (framework errors) | **SDK, automatically** |
| `PlatformDispatcher.instance.onError` (uncaught async) | **SDK, automatically** |
| Guarded zone around `runApp` | **SDK, automatically** (via `appRunner`) |

- **Do not** add your own `runZonedGuarded` or reassign `FlutterError.onError` on top of this — running two guarded zones throws `Zone mismatch` errors and double-reports.
- Only wire a channel manually if you deliberately opt out of the SDK's automatic handler.
- Capture handled errors explicitly where you catch-and-continue: `await Sentry.captureException(e, stackTrace: st);`

## 4. Logging — structured, no `print()`

Two complementary mechanisms, both enabled in §2:

1. **Structured logs** (`options.enableLogs = true`) — emit via the Sentry logger:
   ```dart
   Sentry.logger.info('Pet draft autosaved', attributes: {
     'pet_id': SentryAttribute.string(pet.id),
     'step': SentryAttribute.string('basicInfo'),
   });
   Sentry.logger.warning('Weight out of expected range');
   ```
   Levels: `trace, debug, info, warning, error, fatal`. Use `Sentry.logger.fmt.*` for parameterized messages.

2. **`logging` package bridge** (`LoggingIntegration`) — feature code logs through standard `dart:logging`, which flows to Sentry automatically:
   ```dart
   final _log = Logger('pet_profile.add_pet');
   _log.info('Wizard advanced to health step');
   _log.severe('Failed to persist draft', error, stackTrace); // -> Sentry event
   ```

- **Never use `print()`** — it's invisible to Sentry. Use a `Logger` or `Sentry.logger`.
- Prefer one `Logger` per feature/file, named by feature (`Logger('health_record.weight')`).

## 5. Tracing & metrics

- **Sampling:** `tracesSampleRate` **0.1–0.2 in production** (never `1.0`). Full rate is fine in dev/profile.
- **Instrument selectively** — only spans that matter: **cold start**, **key network calls**, and **heavy parsing/compute**. Don't blanket-instrument every method.
  ```dart
  final tx = Sentry.startTransaction('add_pet.commit', 'task');
  try {
    await addPetUseCase(draft);          // child spans via tx.startChild(...)
  } catch (e, st) {
    tx.throwable = e; tx.status = const SpanStatus.internalError();
    await Sentry.captureException(e, stackTrace: st);
    rethrow;
  } finally {
    await tx.finish();
  }
  ```
- **Network:** if using Dio, add `sentry_dio` and the Sentry interceptor for automatic HTTP spans; otherwise wrap `SentryHttpClient`.
- **Metrics:** track derived signals as transaction/span data or structured-log attributes (e.g. parse duration, record counts). Keep cardinality low — no PII or unbounded ids in tag/metric keys.

## 6. Config conventions

- **Environment** from build mode (see §2): `production` / `profile` / `development`.
- **Release** via `--dart-define=APP_RELEASE=your-app@<version>+<build>` so issues group by release.
- **Consistent tags / context** set once after init:
  ```dart
  Sentry.configureScope((scope) {
    scope.setTag('app_version', appVersion);
    scope.setTag('device_segment', deviceSegment);  // e.g. low_end / tablet
    scope.setTag('user_segment', userSegment);       // non-PII bucket
    scope.setContexts('feature_flags', enabledFlags);
  });
  ```
- **DSN** never hard-coded — inject via `--dart-define=SENTRY_DSN=...`.

## 7. Privacy

- **PII off by default:** `sendDefaultPii = false`. Only enable when **EU consent** is granted; gate it behind your consent state and re-init / reconfigure scope when consent changes.
- **Session replay masking is ON by default** — the SDK aggressively masks `Text`, `EditableText`, `RichText`, and `Image`. **Keep these defaults.** Fine-tune with `SentryMask` / `SentryUnmask` widgets only for confirmed-safe content.
- **Scrub logs & events** in `options.beforeSend` (and review log attributes) — strip emails, tokens, precise location, pet/owner identifiers you don't need.
- **Consent-gate** replay and PII: if consent is absent, keep `sessionSampleRate`/`onErrorSampleRate` effectively off and `sendDefaultPii = false`.

## 8. Symbolication (release builds)

Build obfuscated with split debug info, then upload symbols in CI:

```bash
flutter build apk   --release --obfuscate --split-debug-info=build/debug-info
flutter build ipa   --release --obfuscate --split-debug-info=build/debug-info
```

- Upload as a **CI step** with `sentry_dart_plugin` (reads org/project/auth-token from env or the `sentry:` block in `pubspec.yaml`):
  ```bash
  dart run sentry_dart_plugin
  ```
- Without symbol upload, obfuscated release stack traces are unreadable in Sentry.

## 9. Engineer checklist

- [ ] `sentry_flutter` 9.x + `sentry_logging` added; Dart ≥3.5 / Flutter ≥3.24.
- [ ] `SentryFlutter.init` with `appRunner: () => runApp(SentryWidget(child: MyApp()))`.
- [ ] DSN + release + environment injected via `--dart-define` (no hard-coding).
- [ ] Did **not** add a manual `runZonedGuarded` / duplicate `FlutterError.onError`.
- [ ] `enableLogs = true` and `LoggingIntegration` added; feature code logs via `Logger`/`Sentry.logger` — **zero `print()`**.
- [ ] `tracesSampleRate` 0.1–0.2 in production; transactions only around cold start, key network, heavy parsing.
- [ ] Consistent tags set (app version, device, user segment, feature flags).
- [ ] `replay.onErrorSampleRate` set; replay masking left at defaults.
- [ ] `sendDefaultPii = false`; PII scrubbed in `beforeSend`; replay/PII gated on EU consent.
- [ ] Release builds use `--obfuscate --split-debug-info`; CI uploads symbols.
- [ ] Builds and runs on Android **and** iOS; Sentry wiring is in place (error → Sentry, a log appears, a transaction is recorded). Runtime confirmation of this behavior is covered by the E2E automation suite / Sentry dashboards, not driven here.
