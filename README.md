# 5ranger-arma3-egg

The Arma 3 yolk image the 5 RANGER Operations servers run, as a thin overlay over upstream's.
Published as `ghcr.io/gibsx/5ranger-arma3:latest` and pulled by Wings for Pterodactyl egg 68.

`Dockerfile` replaces `/entrypoint.sh` and nothing else. Base packages, locale, the NSS wrapper,
tini and the container user are all inherited from `ghcr.io/parkervcp/games:arma3`, so the image
keeps tracking upstream everywhere except the one file. The entrypoint needs only `curl` and `awk`,
both already in `debian:bookworm-slim`, so no packages are added.

`upstream.patch` is the exact diff against upstream's `games/arma3/entrypoint.sh`. The copy here
additionally carries a header comment, which is not part of that patch.

## Why it exists

**Mod update checks are rate limited into silence.** Upstream reads each mod's Steam Workshop
changelog *web page* to decide whether it needs updating — one page per mod, on every boot. Steam
rate limits those pages. A server with 131 mods trips the limit part way through its own start-up,
every later page returns HTTP 429, the scrape then parses as an empty string, and the mod is treated
as current with nothing printed. Because each boot re-trips the limit, mods stay frozen.

Measured on Operations (G1), from inside the game container: one page cold returned HTTP 200, the
full 131-page pass ended in 429, and a single page minutes later was still 429. 112 of its 131 mod
directories were still dated 2026-01-12, 19 mods were behind the Workshop (one by 279 days), and
SteamCMD's own `appworkshop_107410.acf` still held January's `latest_manifest` for 18 of those 19 —
it had never been asked.

This fork asks the Steam Web API once instead (`ISteamRemoteStorage/GetPublishedFileDetails`,
no API key, 100 IDs per request), reads the reply with `awk`, compares timestamps numerically rather
than as strings, and reports items the Workshop no longer serves instead of retrying them every
boot. If the API cannot be reached it says so and still downloads *missing* mods, because silence is
the defect being fixed.

**Every mod download pays for its own Steam login.** Upstream starts a separate `steamcmd`
process with a fresh `+login` for each mod. Steam rate limits logins rather than downloads, so a
boot that needs many mods runs out of sign-ins partway through and every mod after that point fails
with `Logging in user ... ERROR (Rate Limit Exceeded)`, reported as an unknown SteamCMD error. On
Operations (G1) a pass of 56 downloads got 44 and failed the last 12; because the loop runs in
sorted ID order the failures are always the tail of the list, which is why the same handful of mods
appeared to fail every time. This fork collects what needs fetching and passes 30 mods to one
`steamcmd` session, so 131 mods take 5 logins instead of 131, and retries only what did not arrive.

It also refuses to rebuild a mod's `@<id>` folder from an empty download. That rebuild starts with
`rm -rf` and runs whenever SteamCMD exits without an error, which it does when it believes an item
is current while the item's files are absent — the state 53 of G1's 133 recorded items were in. The
hard-link copy is then the only one left, and the rebuild would replace it with nothing.

**Optional mods lose their Workshop files.** Upstream deletes an optional mod's content once its
`.bikey` files are copied, without telling SteamCMD, which goes on recording the item as installed
at a manifest whose files are gone — 59 of the 139 items in G1's ACF were in that state. Signing
keys matter here because `verifySignatures = 2`, and key filenames are often version-stamped
(`enh_8.7.1`, `BCE_1.1.1`), so a mod that updates while the server holds only the old key gets its
players rejected. `OPTIONALMODS_KEEP_FILES` gates the deletion; **this fork defaults it to `1`**
where upstream would default to `0`, because keeping all 56 optional mods costs 4.8 GB here.

Three smaller fixes ride along: a mod that cannot be downloaded no longer aborts the whole start,
`$BASIC_URL` becomes `$BASIC_CFG_URL` (the name the current egg actually defines, so the `basic.cfg`
fallback stopped writing an empty file), `ModsLowercase` no longer word-splits on names containing
spaces, and the title lookup no longer costs a second HTTP request per mod.

## Retiring this

Every change here is a fix to upstream, not a 5 RANGER customisation, bar the
`OPTIONALMODS_KEEP_FILES` default. When upstream carries them, point egg 68 back at
`ghcr.io/parkervcp/games:arma3`, set `OPTIONALMODS_KEEP_FILES=1` on the servers, and delete this
repository.

## Licence

Upstream's `entrypoint.sh` is AGPL-3.0-or-later (David Wolfe / Red-Thirten and contributors).
The changes here are under the same licence.
