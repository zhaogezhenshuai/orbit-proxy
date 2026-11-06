# Third-party notices

Orbit is free software, licensed under the GNU General Public License v3.0 (see `LICENSE`).
Copyright (C) 2026 Orbit contributors. It comes with ABSOLUTELY NO WARRANTY.

Orbit.app bundles or builds on the components below. In the app, these files are in
`Orbit.app/Contents/Resources/Licenses/`.

## Bundled in Orbit.app

| Component | License | Where | Source |
|---|---|---|---|
| mihomo core (version set in `scripts/build-core.sh`, v1.19.33 by default) | GPL-3.0 | `Contents/Resources/mihomo` | https://github.com/MetaCubeX/mihomo |
| mieru protocol (`github.com/enfein/mieru/v3`), compiled into the core | GPL-3.0 | inside the core | https://github.com/enfein/mieru |
| Other Go modules compiled into the core | Various (MIT, BSD, Apache-2.0, GPL-3.0, …) | inside the core | full texts: `mihomo-core-licenses.txt` |
| Go standard library and runtime | BSD-3-Clause | inside the core | https://go.dev |
| Rule sets (`Resources/ruleset/*.mrs`) | GPL-3.0 | `Contents/Resources/ruleset` | https://github.com/MetaCubeX/meta-rules-dat |
| Yams 6.2.2 | MIT | compiled into Orbit | https://github.com/jpsim/Yams (`Yams-LICENSE.txt`) |
| libyaml, part of Yams | MIT | compiled into Orbit | https://github.com/yaml/libyaml (`libyaml-LICENSE.txt`) |

### Corresponding source of the core

The core is built from mihomo's source by `scripts/build-core.sh`: it fetches the version above
through the Go module proxy (checksum-verified), applies `patches/mihomo-*.patch`, and builds it.
Those patches are licensed under GPL-3.0 like mihomo:

- `mihomo-mieru-resolve-local.patch` adds the `resolve-local` option to mieru proxies.
- `mihomo-no-restart-upgrade.patch` removes the `/restart` and `/upgrade` REST endpoints.

The script also packs the patched source tree as `mihomo-<version>-orbit-src.tar.gz`; every
release ships that archive next to the app (`scripts/package.sh`). `scripts/gen-core-licenses.py`
collects the licenses of every module listed in the built binary into `mihomo-core-licenses.txt`.

The rule sets are derived by MetaCubeX from Loyalsoldier/v2ray-rules-dat (GPL-3.0) and
v2fly/domain-list-community (MIT). The bundled copies are the `meta` branch of
MetaCubeX/meta-rules-dat as of the release date; Orbit refreshes them at run time from
`raw.githubusercontent.com/MetaCubeX/meta-rules-dat`.

## Online services used at run time (not bundled)

| Service | Used for | Terms |
|---|---|---|
| ip-api.com, ipwho.is, api.ip.sb, ipinfo.io | Showing the exit IP and its location after connecting (one is enough; the others are fallbacks) | Each service's own terms. The free tiers of ip-api.com and ipwho.is are for non-commercial use only. |
| 223.5.5.5 / doh.pub (Alibaba, Tencent); 1.1.1.1 / 8.8.8.8 (Cloudflare, Google) | DNS over HTTPS for domestic / overseas domains | Each provider's own terms |
| raw.githubusercontent.com | Rule-set updates | GitHub's terms |

## Trademarks

Shadowrocket, Clash, sing-box, v2rayN and other product names are trademarks of their owners and are
mentioned only to describe compatibility. Orbit isn't affiliated with or endorsed by them.
Orbit's interface shows SF Symbols through Apple's system APIs; its app icon doesn't use them.
