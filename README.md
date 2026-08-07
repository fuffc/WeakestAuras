# WeakestAuras

A WeakAura clone for the 1.12 Client.

Custom buff, debuff, cooldown and resource displays — icons, progress bars and
groups, driven by triggers and conditions and configured in-game.

## Requirements

Three client patches, none of them bundled. WeakestAuras refuses to load
without them.

| Patch | What it provides |
| --- | --- |
| **ClassicAPI** | `C_UnitAuras`, `C_Spell`, `C_Timer`, `C_EncodingUtil` |
| **SuperWoW** | GUID-addressable units, `UNIT_CASTEVENT` |
| **Nampower** | real aura and cast durations |

## Install

**With git** — clone into your AddOns folder, then `git pull` to update:

```sh
cd Interface/AddOns
git clone https://github.com/fuffc/WeakestAuras.git
```

**From a zip** — download the archive from
[Releases](https://github.com/fuffc/WeakestAuras/releases) and extract it into
`Interface/AddOns/`. It unpacks to a single `WeakestAuras/` folder.

Either way the result has to be
`Interface/AddOns/WeakestAuras/WeakestAuras.toc`. The folder name matters — the
client will not find the addon under any other one.

## Usage

`/wa` (or `/weakestauras`) opens the options window.

## Reporting a bug

[Open an issue](https://github.com/fuffc/WeakestAuras/issues). Please include
the `## Version:` line from the top of `WeakestAuras.toc` and which versions of the three
client patches above you are running.

## License

**GPL-2.0-or-later** — see [LICENSE](LICENSE).

WeakestAuras reimplements the architecture of
[WeakAuras](https://github.com/WeakAuras/WeakAuras2) for a client its own source
cannot run on.

`libs/LibWidgets/` is separate work under the MIT licence; see
[libs/LibWidgets/LICENSE](libs/LibWidgets/LICENSE).
