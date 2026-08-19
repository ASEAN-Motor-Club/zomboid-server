#!/usr/bin/env python3
"""zomboid-server -> Discord changelog relay.

Polls ASEAN-Motor-Club/zomboid-server for new commits to `master`, diffs
backend-options.nix, and posts a readable per-change Discord embed.

Scope: only commits touching backend-options.nix (the mod-list + sandbox
config source of truth) are surfaced as mod/config changes; anything else in
the repo is skipped.

Usage:
  pz_changelog.py --webhook-url URL --state-file PATH [--dry-run] [--repo o/r]
"""
import argparse, json, re, sys, time, urllib.request

API = "https://api.github.com"
REPO = "ASEAN-Motor-Club/zomboid-server"


# ---------- GitHub API ----------

def gh(path):
    req = urllib.request.Request(API + path, headers={"User-Agent": "amc-changelog/1.0", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def list_commits(since_sha, limit=100):
    # newest-first list; return (head_sha, new_shas_newest_first)
    page = 1
    all_shas = []
    head = None
    while True:
        data = gh(f"/repos/{REPO}/commits?sha=master&per_page=100&page={page}")
        if not data:
            break
        for c in data:
            sha = c["sha"]
            if head is None:
                head = sha
            if since_sha and sha == since_sha:
                return head, all_shas
            all_shas.append(sha)
            if len(all_shas) >= limit:
                return head, all_shas
        if len(data) < 100:
            break
        page += 1
    return head, all_shas


def get_commit(sha):
    return gh(f"/repos/{REPO}/commits/{sha}")


# ---------- backend-options.nix diff parsing ----------

def title_for_wid(wid):
    """Best-effort mod title via Steam API; fall back to the WID."""
    try:
        body = f"itemcount=1&publishedfileids[0]={wid}"
        req = urllib.request.Request(
            "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/",
            data=body.encode(), headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.load(r)
        for it in d["response"]["publishedfiledetails"]:
            if it.get("publishedfileid") == str(wid):
                return it.get("title") or wid
            return it.get("title") or wid
    except Exception:
        pass
    return wid


RESERVED_BLOCKS = {"default", "settings", "workshopItems", "mods", "discord",
                "sandboxVars", "options", "inputs", "description", "type",
                "types", "enable", "webhookFile", "interval"}


def parse_patch(patch):
    """Extract (added_wids, removed_wids, config_changes) from a backend-options.nix patch.

    config_changes: list of (block, key, old, new) — block is '' for vanilla
    server settings (top-level `settings` block), else the mod sandbox block name.
    """
    added_wids, removed_wids = [], []
    config_changes = []   # (block, key, old, new)
    last_sandbox_block = ""
    lines = (patch or "").split("\n")
    for ln in lines:
        if ln.startswith("+++") or ln.startswith("---") or ln.startswith("@@"):
            last_sandbox_block = ""
            continue
        if not ln or ln[0] not in "+- ":
            continue
        # a sandbox sub-block opener: `    Block = {` (8-space indent inside sandboxVars)
        m = re.match(r"^[+\- ](\s{0,8})([A-Za-z0-9_]+)\s*=\s*\{$", ln)
        if m and m.group(2) not in RESERVED_BLOCKS:
            last_sandbox_block = m.group(2)
            continue
        # workshop item lines: one or more 7..12 digit quoted strings on a diff line
        m = re.match(r"^([+-])\s*(.*)$", ln)
        if m and re.search(r'"\d{7,12}"', m.group(2)):
            wids = re.findall(r'"(\d{7,12})"', m.group(2))
            if m.group(1) == "+":
                added_wids.extend(wids)
            else:
                removed_wids.extend(wids)
            continue
        # config value line:  Key = "value";
        m = re.match(r"^([+-])\s*([A-Za-z0-9_]+)\s*=\s*\"([^\"]*)\"", ln)
        if m:
            sign, key, val = m.group(1), m.group(2), m.group(3)
            config_changes.append((last_sandbox_block, key,
                                   None if sign == "+" else val,
                                   val if sign == "+" else None))
    return added_wids, removed_wids, config_changes


def build_embed(commit):
    sha = commit["sha"][:7]
    msg = (commit.get("commit", {}).get("message") or "").split("\n")[0]
    url = commit["html_url"]
    files = commit.get("files", [])
    patch = next((f.get("patch", "") for f in files if f.get("filename", "").endswith("backend-options.nix")), None)
    if patch is None:
        return None   # not a config change

    added_wids, removed_wids, config_changes = parse_patch(patch)

    lines = []
    # Mod adds / removes
    for w in [*added_wids, *removed_wids]:
        pass
    for w in removed_wids:
        title = title_for_wid(w)
        lines.append(f"➖ **Removed mod:** {title} (`{w}`)")
    for w in added_wids:
        title = title_for_wid(w)
        lines.append(f"➕ **Added mod:** {title} (`{w}`)")
    # Config changes (dedupe + pair +/old)
    # pair a '-' with a subsequent '+' of same key in same block
    seen = {}
    for block, key, old, new in config_changes:
        keyed = (block, key)
        if keyed in seen:
            o, n = seen[keyed]
            seen[keyed] = (o if o is not None else old, n if n is not None else new)
        else:
            seen[keyed] = (old, new)
    for (block, key), (old, new) in seen.items():
        label = f"{block}.{key}" if block else key
        if old is None and new is not None:
            lines.append(f"⚙️ **Config:** `{label}` → `{new}`")
        elif old is not None and new is not None:
            lines.append(f"⚙️ **Config:** `{label}` `{old}` → `{new}`")
        # removal-only of a key (no paired +) -> skip or note

    if not lines:
        lines.append("• " + msg)

    desc = "\n".join(lines)
    return {
        "embeds": [{
            "title": f"[[{sha}]] {msg}",
            "description": desc,
            "url": url,
            "color": 0x7AA2F7,
            "footer": {"text": "ASEAN Motor Club · PZ config changelog"},
        }]
    }


# ---------- main ----------

def post(url, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=20) as r:
        code = r.getcode()
        r.read()
        return code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--webhook-url", default=None)
    ap.add_argument("--state-file", required=False)
    ap.add_argument("--dry-run", action="store_true")
    ap = ap.parse_args()

    # seeded to current HEAD on first run so we don't replay history
    state_last = None
    if ap.state_file:
        try:
            with open(ap.state_file) as f:
                state_last = f.read().strip() or None
        except FileNotFoundError:
            state_last = None

    head, new_shas = list_commits(state_last)
    new_shas = new_shas[::-1]   # oldest first

    if not new_shas:
        if head:
            with open(ap.state_file, "w") as f:
                f.write(head)
        return 0

    for sha in new_shas:
        commit = get_commit(sha)
        emb = build_embed(commit)
        if emb is None:
            continue
        if ap.dry_run or not ap.webhook_url:
            print(json.dumps(emb, indent=2))
        else:
            try:
                post(ap.webhook_url, emb)
                time.sleep(0.3)
            except Exception as e:
                print(f"POST failed for {sha}: {e}", file=sys.stderr)

    if head:
        with open(ap.state_file, "w") as f:
            f.write(head)
    return 0


if __name__ == "__main__":
    sys.exit(main())