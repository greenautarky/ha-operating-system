#!/usr/bin/env python3
"""GreenAutarky weekly engineering digest.

Gathers the past week's merged pull requests across the GreenAutarky repos,
synthesises a short one-pager via the Anthropic API, and posts it as a
``[BOT]`` note to the Odoo *Product_iHOST* project chatter.

Designed to run unattended from a Friday GitHub Action (see
``.github/workflows/weekly-digest.yml``) but also runs locally for testing.

Environment / secrets
----------------------
  GH_TOKEN            GitHub token with read access to the greenautarky repos
                      (the Action passes a PAT; locally `gh` uses your login).
  ANTHROPIC_API_KEY   used for the synthesis step.
  ODOO_URL ODOO_DB ODOO_LOGIN ODOO_APIKEY   Odoo XML-RPC credentials.

Flags
-----
  --days N        look-back window in days (default 7).
  --since DATE    explicit window start (YYYY-MM-DD); overrides --days.
  --dry-run       print the digest to stdout, do NOT post to Odoo.
  --no-llm        skip synthesis, emit a plain grouped PR list (no API key needed).
  --model ID      Anthropic model (default claude-sonnet-5).
  --odoo-model M  Odoo model to post to (default project.project).
  --odoo-id N     Odoo record id to post to (default 17 = Product_iHOST).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.request
import xmlrpc.client

REPOS = [
    "greenautarky/ha-operating-system",
    "greenautarky/ga_manager",
    "greenautarky/ga-fleet-manager",
    "greenautarky/ga-bootstrap",
    "greenautarky/ga-ihost-docs",
]

# Commit-type prefixes that are noise in a feature digest.
_SKIP_PREFIXES = ("chore(bake):", "chore(release):", "chore(version):", "ci:")


def _log(msg: str) -> None:
    print(f"weekly-digest: {msg}", file=sys.stderr)


# ── 1. gather merged PRs ────────────────────────────────────────────────────
def merged_prs(repo: str, since: str) -> list[dict]:
    """Merged PRs in ``repo`` since ``since`` (YYYY-MM-DD), via the gh CLI."""
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "--repo", repo, "--state", "merged",
             "--search", f"merged:>={since}", "--limit", "100",
             "--json", "number,title,url,mergedAt"],
            capture_output=True, text=True, timeout=60, check=True,
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
        _log(f"WARN gh pr list failed for {repo}: {e}")
        return []
    prs = json.loads(out or "[]")
    for p in prs:
        p["repo"] = repo.split("/", 1)[1]
    return prs


def gather(since: str) -> list[dict]:
    all_prs: list[dict] = []
    for r in REPOS:
        prs = merged_prs(r, since)
        _log(f"{r}: {len(prs)} merged PR(s) since {since}")
        all_prs += prs
    # Drop pure release/bake/version chores — keep the feature/fix signal.
    kept = [p for p in all_prs
            if not p["title"].lower().startswith(_SKIP_PREFIXES)]
    kept.sort(key=lambda p: p.get("mergedAt", ""), reverse=True)
    return kept


# ── 2. synthesise ───────────────────────────────────────────────────────────
_SYSTEM = """You are the release-notes editor for GreenAutarky's iHost / \
Home-Assistant-OS fleet engineering. Turn a week's merged pull requests into a \
tight, skimmable one-pager for the internal team. Be concrete and factual; \
never invent work that isn't in the list.

Output valid Odoo-chatter HTML only (no <html>/<head>, no CSS, no markdown). \
Allowed tags: <p>, <b>, <ul>, <li>, <br>. Structure:
  <p><b>Week of &lt;Mon D&gt;&ndash;&lt;D Mon YYYY&gt;</b></p>
  <p>&lt;one-sentence headline of the week's theme&gt;</p>
  <ul>
    <li><b>[Area]</b> &lt;what shipped, in plain language a PM would grok&gt;</li>
    ... 4-8 items, most important first ...
  </ul>
Group related PRs into a single bullet; collapse a version march into one line. \
Area is one of: OS, Addon, Fleet, Telemetry, Infra, Docs, Security. Prefer \
outcomes over mechanics. Keep it to what fits on one screen."""


def synthesise(prs: list[dict], since: str, model: str) -> str:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError("ANTHROPIC_API_KEY not set (use --no-llm to skip synthesis)")
    lines = [f"- [{p['repo']}] {p['title']}  ({p['url']})" for p in prs]
    user = (f"Merged PRs since {since} ({len(prs)} items), newest first:\n\n"
            + "\n".join(lines))
    body = json.dumps({
        "model": model,
        "max_tokens": 1800,
        "system": _SYSTEM,
        "messages": [{"role": "user", "content": user}],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=body,
        headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.load(r)
    return "".join(b.get("text", "") for b in data.get("content", [])).strip()


def plain_list(prs: list[dict], since: str) -> str:
    """Fallback digest (no LLM): a grouped raw PR list as chatter HTML."""
    by_repo: dict[str, list[dict]] = {}
    for p in prs:
        by_repo.setdefault(p["repo"], []).append(p)
    out = [f"<p><b>Merged since {since}</b> — {len(prs)} PRs "
           "(raw list; synthesis skipped)</p>"]
    for repo, items in by_repo.items():
        out.append(f"<p><b>{repo}</b></p><ul>")
        out += [f'<li><a href="{p["url"]}">#{p["number"]}</a> {p["title"]}</li>'
                for p in items]
        out.append("</ul>")
    return "".join(out)


# ── 3. post to Odoo ─────────────────────────────────────────────────────────
def odoo_post(html: str, model: str, res_id: int) -> int:
    url = os.environ["ODOO_URL"].rstrip("/")
    db = os.environ["ODOO_DB"]
    login = os.environ["ODOO_LOGIN"]
    apikey = os.environ["ODOO_APIKEY"]
    common = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/common")
    uid = common.authenticate(db, login, apikey, {})
    if not uid:
        raise RuntimeError("Odoo authentication failed")
    models = xmlrpc.client.ServerProxy(f"{url}/xmlrpc/2/object")
    if not html.startswith("[BOT]"):
        html = "<p><b>[BOT]</b> Weekly engineering digest</p>" + html
    # Odoo 19's message_post escapes a raw HTML string, so post then write the
    # Html body field directly (the odoo skill's verified `post` pattern).
    msg_id = models.execute_kw(db, uid, apikey, model, "message_post",
                               [[res_id]], {"body": "digest"})
    models.execute_kw(db, uid, apikey, "mail.message", "write",
                      [[msg_id], {"body": html}])
    stored = models.execute_kw(db, uid, apikey, "mail.message", "read",
                               [[msg_id], ["body"]])[0]["body"]
    if "&lt;p&gt;" in stored:
        raise RuntimeError("Odoo stored the body escaped — render check failed")
    return msg_id


# ── main ────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--since")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-llm", action="store_true")
    ap.add_argument("--model", default="claude-sonnet-5")
    ap.add_argument("--odoo-model", default="project.project")
    ap.add_argument("--odoo-id", type=int, default=17)
    a = ap.parse_args()

    since = a.since or (dt.date.today() - dt.timedelta(days=a.days)).isoformat()
    prs = gather(since)
    if not prs:
        _log("no feature/fix PRs merged this window — nothing to post")
        return 0

    if a.no_llm:
        html = plain_list(prs, since)
    else:
        try:
            html = synthesise(prs, since, a.model)
        except Exception as e:  # never let synthesis failure swallow the week
            _log(f"WARN synthesis failed ({e}); falling back to the raw PR list")
            html = plain_list(prs, since)

    if a.dry_run:
        print(html)
        _log(f"dry-run: {len(prs)} PRs, digest NOT posted")
        return 0

    msg_id = odoo_post(html, a.odoo_model, a.odoo_id)
    _log(f"posted digest to Odoo {a.odoo_model}/{a.odoo_id} (message {msg_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
