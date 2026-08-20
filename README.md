# WeakestAuras

A clone/backport of [WeakAuras](https://github.com/WeakAuras/WeakAuras2) for the
1.12 client. WeakestAuras is an independent project, not an official WeakAuras
release.

Custom buff, debuff, cooldown and resource displays — icons, progress bars and
groups, driven by triggers and conditions and configured in-game.

This project is in an early public stage. Expect bugs, incomplete features and
client-specific differences. An aura that looks correct in the editor may still
need testing in-game, especially when it depends on timing, custom code or
unusual events.

## Requirements

Three client patches, none of them bundled. WeakestAuras refuses to load
without them. **ClassicAPI is the primary dependency:** it backports a broad,
modern WoW API surface to the 1.12 client, which WeakestAuras uses throughout
the addon.

| Patch | What it provides |
| --- | --- |
| **ClassicAPI** | Modern API surface for 1.12, including aura data, spells and casting, cooldowns, items, timers, serialization/encoding, event utilities and related compatibility helpers |
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

### Documentation

Start with the [official WeakAuras documentation](https://github.com/WeakAuras/WeakAuras2/wiki).
Most of the concepts and options are intentionally modelled after the reference
addon, so its documentation is the best guide to how WeakestAuras is meant to be
used. Not every WeakAuras feature exists on the 1.12 client, however, and the
differences described below can affect an aura's behaviour.

### Wago.io and WeakAuras imports

WeakestAuras can translate many WeakAuras2 export strings, including exports
from [Wago.io](https://wago.io/). Prefer auras made for Classic/Vanilla
WeakAuras when possible. Retail auras, and especially complicated custom auras,
can require substantial manual repair or may not work at all.

The two addons do not run on the same client or API. Events and event payloads
may be missing or behave differently, custom code may use Lua syntax or APIs
that do not exist in Lua 5.0, and triggers, actions, regions, media and other
settings may have no local equivalent. The importer reports fields it had to
drop when it can, but a successful import is not a guarantee that the aura is
working. Review the import summary and test the result in-game.

## WeakAuras2 feature coverage

WeakestAuras has a broad portion of WeakAuras2's core architecture, but the
coverage is not one-to-one. A current trigger audit finds local equivalents for
38 of 51 named WeakAuras2 generic trigger prototypes; those equivalents often
have fewer fields, units, events or clone modes.

The status column uses plain-language descriptions of what users can expect. It
describes practical coverage, not byte-for-byte upstream parity or complete
in-game verification.

| Feature area | Practical status | State and notes |
| --- | --- | --- |
| Core display engine | Core functionality implemented | State handling, multi-trigger runtime, saved data, loading and display updates are implemented. Edge-case behavior is still being tested. |
| Display regions | Core region types implemented | Icon, progress bar, text, texture, linear progress texture, group and dynamic group regions are available. Model, Stop Motion and circular progress textures are not. |
| Sub-regions | Core sub-regions implemented | Text, border, glow and tick sub-regions are available where the parent region supports them. |
| Triggers | Broad trigger coverage (38/51) | Aura, cooldown, health, power, casts, items, equipment, range, talents, location, chat and other Vanilla-relevant triggers are available; parity varies by trigger. |
| Custom triggers and TSU | Core modes implemented | Status, event and Trigger State Updater modes are available, including custom states and clones, but several modern state fields and event systems are missing. |
| Conditions and load rules | Classic/Vanilla coverage | Conditions, nested AND/OR checks and many load filters are available, with a smaller Classic/Vanilla status and instance surface. |
| Clones and dynamic groups | Core clone/group behavior implemented | Clone state handling, sorting, limits, stagger and per-unit anchoring are available. Custom, circular and grid growth, plus some group movement animation, are not. |
| Animations | Core animations implemented | Region and sub-region animations are available. Dynamic-group movement animation and some upstream animation details remain different. |
| Actions | Core actions implemented | Custom code, chat messages, sounds, looping and local glow actions are available, with fewer channels, sound controls and external glow targets. |
| Text replacement and formats | Common formats implemented | Common dynamic text and numeric/time formats are available. Inline icons, coin art, raid markers and rotated text need ClassicAPI 1.10.0 or newer and fall back to plain text without one. Some upstream formats are still unavailable. |
| Import/export and sharing | Native round-trip; foreign imports best effort | WeakestAuras has its own round-trip format, can translate many WeakAuras2 strings, and supports chat links. It does not export a WeakAuras2-compatible string. |

The table describes practical feature coverage, not a guarantee that every aura
or edge case works without testing. The [official WeakAuras documentation](https://github.com/WeakAuras/WeakAuras2/wiki)
remains the best usage reference; the Wago.io and limitation notes below explain
where an aura can diverge on this client.

## Known limitations and differences

WeakestAuras follows WeakAuras2's data model and user interface where practical,
but it is not a drop-in replacement. The 1.12 client and Lua 5.0 impose real
limits:

- **Triggers:** coverage and available fields are narrower. Combat Log is not
  available, and many modern systems such as spell charges, encounter events,
  specializations and PvP talents have no equivalent here. Existing triggers
  may also support fewer units, filters, states, clones or events.
- **Aura timing:** aura scanning is partly poll-based, and duration and
  expiration data are a best-effort client-side cache, especially for units
  other than the player. Timers can occasionally lag or be inaccurate.
- **Regions and groups:** Model and Stop Motion regions, circular progress
  textures, custom/circular/grid group growth and some dynamic-group animation
  features are unavailable. Unsupported imported region types are displayed as
  a fallback message rather than working as they do in WeakAuras2.
- **Text:** inline icons (`%i`), the Money format's coin art, raid markers and
  rotated text require ClassicAPI 1.10.0 or newer; on an older one they fall
  back to plain text rather than failing. Turning a marker name back into
  `{rtN}` is not supported on any build. Some WeakAuras2 text formats, including
  GUID and GCDTime, are unavailable or reduced.
- **Custom code and actions:** custom code must use Lua 5.0 and this client's
  APIs and events. The aura environment is not sandboxed like WeakAuras2, so
  only use custom code and imported auras you trust. Some action destinations,
  sound controls and external glow targets are also unavailable or reduced.

These differences are in addition to the Wago.io translation limitations above;
they are the main reason a simple imported aura may work while a more elaborate
one needs manual changes.

### Sharing and import/export

WeakestAuras auras can be moved with the in-game **Export** and **Import**
windows. The native format is intended for WeakestAuras and is separate from a
WeakAuras2/Wago export.

You can also share an aura through chat: open a chat edit box and Shift-click
the aura, or choose **Link to Chat** from its menu. A recipient running
WeakestAuras can click the link to request the aura and review it in the import
window before confirming it. Players without the addon simply see readable
plain text.

Chat sharing has limits:

- Both players need WeakestAuras and the required client patches.
- The sender and recipient must share a party, raid or guild channel; direct
  addon whispers are not available on this client.
- Transfers are rate-limited and large groups may take time or exceed the chat
  transport limit.
- Sharing uses WeakestAuras' own format. It does not make a Wago.io or
  WeakAuras2 aura compatible, and any problems from translating that aura remain.
- Complex or nested groups and other unsupported data may not survive a
  transfer exactly.

Nothing is installed without the recipient confirming the import.

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
