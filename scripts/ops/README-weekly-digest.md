# Weekly Engineering Digest

Every Friday, [`weekly_digest.py`](weekly_digest.py) gathers the past week's
**merged pull requests** across the GreenAutarky repos, synthesises a short
one-pager via the Anthropic API, and posts it as a `[BOT]` note to the Odoo
**Product_iHOST** project chatter. Runs from the
[`weekly-digest.yml`](../../.github/workflows/weekly-digest.yml) GitHub Action
(schedule `Fri 13:37 UTC`) or on demand.

## Repos covered

`ha-operating-system`, `ga_manager`, `ga-fleet-manager`, `ga-bootstrap`,
`ga-ihost-docs` (edit `REPOS` in the script to change). Pure release/bake/
version chores are filtered out; the feature/fix signal is kept.

## Required repository secrets

Add these under **Settings → Secrets and variables → Actions** on this repo:

| Secret | What | Notes |
|---|---|---|
| `DIGEST_GH_PAT` | GitHub PAT, `repo:read` on the greenautarky org | The built-in `GITHUB_TOKEN` only sees this repo; a PAT is needed for the cross-repo PR queries. A fine-grained token with *Contents/Pull-requests: read* on the five repos is enough. |
| `ANTHROPIC_API_KEY` | Anthropic API key | For the synthesis step. If missing/erroring, the job **falls back** to a raw grouped PR list — it never fails silently. |
| `ODOO_URL` | e.g. `https://greenautarky.odoo.com` | |
| `ODOO_DB` | Odoo database name | |
| `ODOO_LOGIN` | Odoo login/email of the bot user | |
| `ODOO_APIKEY` | that user's API key | Settings → Users → API Keys. The post is prefixed `[BOT]`. |

## Trigger it manually (test)

**Actions → Weekly Engineering Digest → Run workflow.** Options:
- **dry_run** — prints the digest to the job log instead of posting to Odoo.
- **since** — override the window start (`YYYY-MM-DD`).

## Run locally

```bash
# just gather + print the raw list (only needs gh auth):
python3 scripts/ops/weekly_digest.py --no-llm --dry-run --days 7

# full synth to stdout (needs ANTHROPIC_API_KEY):
python3 scripts/ops/weekly_digest.py --dry-run --days 7

# real post (needs the ODOO_* env too):
set -a; . ~/.config/odoo/odoo.env; set +a
python3 scripts/ops/weekly_digest.py --days 7
```

## Change where it posts

`--odoo-model` / `--odoo-id` (defaults `project.project` / `17`). To post to a
task instead, use `--odoo-model project.task --odoo-id <task-id>`.
