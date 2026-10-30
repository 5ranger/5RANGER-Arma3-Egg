"""Bring a server's SteamCMD records back in step with what is on disk.

Upstream:   the server's data directory (run on the node, server stopped)
Downstream: the next boot, which refetches whatever this marks as absent
Uses:       nothing outside the standard library

Needed once per server, on any server that ran the old entrypoint. That version deleted
optional mods' Workshop files without telling SteamCMD, so appworkshop_107410.acf goes on
recording those items as installed at a manifest whose files are gone, and SteamCMD is then
asked to update content it no longer has. Pruning the record alone is not enough: the
@<id>_optional marker is what the entrypoint checks, so it has to go too or the mod is never
refetched.

Run with --apply to write; without it, nothing is changed and the plan is printed.

    python3 repair-steamcmd-records.py /var/lib/pterodactyl/volumes/<server-uuid> --apply
"""
import os
import re
import shutil
import sys
import time

GAME_ID = 107410

vol = sys.argv[1]
apply_changes = "--apply" in sys.argv

acf = os.path.join(vol, f"Steam/steamapps/workshop/appworkshop_{GAME_ID}.acf")
content = os.path.join(vol, f"Steam/steamapps/workshop/content/{GAME_ID}")
stamp = time.strftime("%Y%m%d-%H%M%S")

have = set(os.listdir(content)) if os.path.isdir(content) else set()
text = open(acf, encoding="utf-8", errors="replace").read()
recorded = set(re.findall(r'^\t\t"(\d{6,})"$', text, re.M))
phantom = sorted(i for i in recorded if i not in have)

print(f"recorded items {len(recorded)}, content dirs {len(have)}, "
      f"recorded with no files on disk {len(phantom)}")
if not phantom:
    print("nothing to repair")
    sys.exit(0)

backup = f"{acf}.bak-{stamp}"
print(f"  backup -> {backup}")
if apply_changes:
    shutil.copy2(acf, backup)

# Each item appears in both WorkshopItemsInstalled and WorkshopItemDetails, so one id can
# account for two blocks. Depth counting keeps the surrounding structure intact.
out, removed, depth, skipping = [], 0, 0, False
for line in text.splitlines(keepends=True):
    match = re.match(r'^\t\t"(\d{6,})"$', line.rstrip("\n"))
    if match and match.group(1) in phantom and not skipping:
        skipping, depth, removed = True, 0, removed + 1
        continue
    if skipping:
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            skipping = False
        continue
    out.append(line)
print(f"  pruning {removed} blocks covering {len(phantom)} distinct items")
if apply_changes:
    open(acf, "w", encoding="utf-8").write("".join(out))

markers = [d for d in os.listdir(vol)
           if d.endswith("_optional") and d.lstrip("@")[:-len("_optional")] in phantom]
print(f"  removing {len(markers)} @<id>_optional markers so the next boot refetches them")
if apply_changes:
    for d in markers:
        shutil.rmtree(os.path.join(vol, d))

print("APPLIED" if apply_changes else "DRY RUN - nothing written")
