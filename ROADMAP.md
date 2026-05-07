# Roadmap

## v0.1 — initial release

### Done

- Visual editor: minimap + per-row layout, navigation, move/resize/rotate, primary/disable/enable.
- Apply via xrandr; defensive `--auto` fallback if no mode known.
- Profile management: save (overwrite-aware), load, delete (autorandr).
- Hot-plug watcher (off by default, `darr-watch-mode`).
- Disconnected-display guards: clean `user-error` instead of crash.
- Lint-clean, byte-compile clean (`byte-compile-error-on-warn t`).
- ERT tests for parser + xrandr-args round-trip (8 tests, all passing).
- Makefile targets: `test`, `lint`, `compile`, `clean`, `all`.
- CI workflow on Emacs 28.1 / 29.4 / snapshot.
- README, `melpa-recipe`, `.gitignore`, GPL3.
- `fixik` Claude skill for self-doctoring.

### Remaining (publishing tasks)

- [ ] Push the repo to `github.com/rails-to-cosmos/darr`.
- [ ] Verify GitHub Actions goes green on the first run.
- [ ] Add a screenshot of `*Displays*` (with the minimap visible) to the
      top of `README.md`.
- [ ] Open a PR to `melpa/melpa` adding `recipes/darr` (contents of
      `melpa-recipe`).
- [ ] Once MELPA merges, recommend `(use-package darr :ensure t)` in the
      README install section.

## v0.2 — Wayland support

The differentiator. Without this, darr is just another xrandr wrapper.
With it, sway/Hyprland/river users have a real reason to install.

1. Introduce `darr-backend` defcustom: `'xrandr` or `'wlr-randr`.
2. Refactor `darr--call` and `darr--parse-xrandr` behind a backend
   dispatch; split into `darr-backend-xrandr.el` and
   `darr-backend-wlr.el`.
3. Implement the wlr-randr backend: query parser + apply-args builder.
4. Auto-detect backend (env: `WAYLAND_DISPLAY` non-empty → `wlr-randr`).
5. Profile management: autorandr is X11-only. Either skip on Wayland or
   document `kanshi` / `shikane` as equivalents and link from README.
6. Tests with wlr-randr fixture data.

Estimate: ~300 lines + tests.

## v0.3 — UX polish

1. **EDID-aware naming**: parse monitor model from `/sys/class/drm/*/edid`
   (or `xrandr --prop`). Render as `HDMI-1 (Dell U2723QE)`. Optional via
   defcustom.
2. **Direct manipulation in the minimap**: when point is inside the
   minimap region, arrow keys move the box under point instead of the
   line. Mouse drag bonus.
3. **Smarter `darr-cycle-rate`**: offer the closest rate to current when
   switching resolutions, instead of jumping to whatever's first in the
   new mode's rate list.
4. **Auto-fit minimap width** to the window instead of fixed
   `darr-canvas-width`.

## v0.4+ — niche / optional

1. **Scale + DPI controls**: `xrandr --scale 1.5x1.5`, `--dpi 144`. Big
   win for HiDPI users.
2. **udev-based watcher** (Linux): subscribe to `drm` udev events
   instead of polling, removing the 5-second timer.
3. **Brightness control**: `xrandr --brightness` per-display.
4. **Modeline indicator**: tiny ` 2 displays` in the modeline showing
   layout count, click to invoke `darr`.

## Known issues

- `darr--move` picks the *first* enabled display as its anchor, not the
  *nearest*. With 3+ displays, this can move the wrong direction.
- The minimap doesn't show **disconnected** outputs at all — intentional,
  but undocumented. Could add a faded / dashed-border rendering for them.
- `darr-on-connect-hook` is documented in README, but the example doesn't
  show that an `autorandr --change` invocation is the canonical handler.
