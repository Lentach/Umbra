// Boot loader for #fp-boot (styling: the #fp-boot CSS in web/index.html <head>).
//
// EXTERNAL, same-origin file on purpose: the prod CSP (infra/nginx/
// security-headers.conf) pins each INLINE <script> by sha256 and
// scripts/verify-csp-inline-hashes.mjs fails on drift. `script-src` already
// carries 'self', so an external file needs no hash — index.html keeps exactly
// two inline blocks (theme-flash killer + passcode curtain) and this loader
// costs no CSP maintenance and is safe when the policy flips to enforcing.
//
// Loaded (plain, not defer/async) right after the #fp-boot element so it runs
// the instant that element is parsed — NO DOMContentLoaded wait, because the
// deferred jsqr.js blocks DCL for seconds on the exact slow connection this
// loader exists for. Accent + locale mirror the two <head> scripts
// (localStorage, shared_preferences `flutter.` prefix). Removed on Flutter's
// first rendered frame.
(function () {
  try {
    var read = function (k) {
      return (localStorage.getItem(k) || '').replace(/"/g, '');
    };
    // Same values as the #fp-curtain accents in index.html <head>
    // (RpgTheme.ephemeralAccent). The curtain copy is the one pinned by
    // web_document_background_test.dart; keep this copy in sync with it.
    var accents = {
      dark: '#5C9EAD', blue: '#2AABEE', cosmic: '#8FD8FF',
      teal: '#0F766E', light: '#C2410C'
    };
    var boot = document.getElementById('fp-boot');
    if (boot) {
      boot.style.color =
        accents[read('flutter.theme_preference')] || accents.light;
    }
    // Match the app's own default: settings_provider.dart hard-defaults to
    // Polish for any unset/evicted value, so NEVER sniff navigator.language
    // (that would show a Polish user an English loader then a Polish app).
    var lang = read('flutter.locale_preference') === 'en' ? 'en' : 'pl';
    var s = lang === 'en'
      ? { label: 'Loading\u2026',
          hint: 'First launch after an update can take a moment.' }
      : { label: 'Wczytywanie\u2026',
          hint: 'Pierwsze uruchomienie po aktualizacji mo\u017Ce chwil\u0119 potrwa\u0107.' };
    var label = document.getElementById('fp-boot-label');
    if (label) label.textContent = s.label;
    // Fake but always-moving progress: a determinate bar reassures far more
    // than an indeterminate one. Decelerate asymptotically toward 99% (always
    // moving, never stalling and never claiming done); finish to 100% only when
    // Flutter's first frame lands.
    var fill = boot ? boot.querySelector('.fp-boot-bar > i') : null;
    var pct = 6;
    var progressTimer = window.setInterval(function () {
      // Asymptotic toward 99 (never a hard clamp): on a 15-30 s idle-return
      // load the bar must keep visibly creeping, or a frozen bar reads as
      // "broken" exactly like the blank screen did.
      pct += Math.max(0.08, (99 - pct) * 0.055);
      if (pct > 99) pct = 99;
      if (fill) fill.style.width = pct.toFixed(1) + '%';
    }, 220);
    // Only the SLOW path needs reassurance: reveal the "may take a moment"
    // line after 6 s so a warm, instant boot never flashes it.
    var hintTimer = window.setTimeout(function () {
      var hint = document.getElementById('fp-boot-hint');
      if (hint) { hint.textContent = s.hint; hint.style.opacity = '1'; }
    }, 6000);
    var remove = function () {
      window.clearTimeout(hintTimer);
      window.clearInterval(progressTimer);
      if (fill) fill.style.width = '100%';
      // Let the bar animate to full before tearing the loader down.
      window.setTimeout(function () {
        if (boot && boot.parentNode) boot.parentNode.removeChild(boot);
      }, 180);
    };
    window.__fpBoot = { hide: remove };
    // Flutter dispatches this on its first rendered frame; initEvent sets
    // bubbles=true, so it reaches window (main.dart.js, "flutter-first-frame").
    window.addEventListener('flutter-first-frame', remove, { once: true });
  } catch (e) { /* loader is best-effort — never block boot */ }
})();
