# darr — Display Arranger for Emacs

Buffer-based interactive editor for monitor layout. Currently shells out
to `xrandr` and `autorandr` (X11); a Wayland backend is on the roadmap.
No native code, pure Elisp.

## Install

### From a clone

```sh
git clone https://github.com/rails-to-cosmos/darr.git
```

```elisp
(use-package darr
  :load-path "/path/to/darr"
  :commands (darr darr-show darr-watch-mode)
  :bind ("C-x y d" . darr))
```

### From MELPA

(Once published)

```elisp
(use-package darr
  :ensure t
  :commands (darr darr-show darr-watch-mode)
  :bind ("C-x y d" . darr))
```

## Usage

```
M-x darr                 ; alias for darr-show
```

Opens a `*Displays*` buffer showing each output, plus a 2D minimap of the
relative layout. Selected display is highlighted; `n`/`p` cycle, `h`/`j`/`k`/`l`
move it relative to its neighbour.

```
Displays

┌──────────────────────────────┐┌──────────────────────────┐
│                              ││                          │
│             eDP-1            ││          HDMI-1          │
│                              ││                          │
└──────────────────────────────┘└──────────────────────────┘

* eDP-1   2160x1350 @ 60Hz  +0+0  ★ primary
  HDMI-1  1920x1080 @ 60Hz  +2160+0
  DP-1    (disconnected)

n/p select  •  hjkl move  •  r/R res  F rate  o rotate  •  P primary  d disable  e enable
C-c C-c apply  •  C-c C-s save  •  C-c C-l load  •  C-c C-d delete  •  g refresh  •  ? help
```

The buffer shows `[unapplied]` after any change until you `C-c C-c`.

### Keys

| Key       | Action                                                           |
|-----------|------------------------------------------------------------------|
| `n` / `p` | Select next / previous display                                   |
| `h j k l` | Move selected display left/down/up/right of an enabled neighbour |
| `r` / `R` | Cycle resolution forward / backward                              |
| `F`       | Cycle refresh rate (within current resolution)                   |
| `o`       | Cycle rotation: normal → left → inverted → right                 |
| `P`       | Mark display as primary                                          |
| `d` / `e` | Disable / enable display (enable seeds sensible defaults)        |
| `g`       | Refresh from `xrandr --query`                                    |
| `C-c C-c` | Apply current layout via `xrandr`                                |
| `C-c C-s` | Save current layout as autorandr profile (with overwrite prompt) |
| `C-c C-l` | Load autorandr profile (with completion)                         |
| `C-c C-d` | Delete saved autorandr profile                                   |
| `?`       | Help                                                             |

## Hot-plug watcher

```elisp
(darr-watch-mode 1)
```

Polls `xrandr` every 5 s and runs hooks on connect / disconnect:

```elisp
(add-hook 'darr-on-connect-hook
          (lambda (name) (message "Display %s connected" name)))
```

**Probably not what you want.** Most distros wire autorandr to udev
(`/usr/lib/udev/rules.d/40-monitor-hotplug.rules` triggers
`autorandr --change`), which already auto-applies the matching profile
on plug events. Enable `darr-watch-mode` only if that's missing on
your system.

## Profile interop

Profiles are saved via `autorandr --save`, so the system-wide
`autorandr.service` keeps handling hot-plug. `darr` is the *editor*;
autorandr is the *daemon*.

## Roadmap

- **Wayland backend**: `wlr-randr` (Sway, Hyprland, river, …) for v0.2.
  The xrandr coupling will be hidden behind a `darr-backend` defcustom.
- **Direct manipulation in the minimap**: drag boxes with arrow keys
  while focus is on the layout grid.
- **EDID-aware naming**: show a friendly monitor model under the output
  name, so `HDMI-1` becomes "HDMI-1 (Dell U2723QE)".

## License

GPL v3+. See `LICENSE`.
