# GitHub Repo Backup

Back up **all** your GitHub repositories — public **and** private — to a local folder
or external hard drive. One command. Run it whenever you want a fresh copy.

Why: GitHub outages, account bans, or accidental deletes shouldn't put your code at risk.
Git is distributed, so a full mirror on your own disk = a complete, independent copy you
can restore from offline, forever.

Two equivalent scripts are included — use whichever fits your system:

| Script | Use on |
|--------|--------|
| `Backup-GitHubRepos.ps1` | Windows (PowerShell) |
| `backup-github-repos.sh` | Linux, macOS, WSL, Git-Bash |

---

## What it does

- Lists **every repo your token can access** (your own + org + collaborator), with API pagination — no limit on repo count.
- For each repo:
  - **First run:** a *mirror clone* — a bare copy holding **everything** (all branches, tags, notes, full history).
  - **Later runs:** a fast *incremental update* — only new commits are fetched.
- Optional **`.bundle`** snapshot per repo — the whole repo as one portable file (see [Mirror vs Bundle](#mirror-vs-bundle)).
- Optional **Git LFS** download — pulls real large files, not just pointers.
- **Token never touches your backup drive.** It's passed to git per-command via an auth header; the saved repo configs contain plain URLs only.
- **Per-repo error isolation** — one broken repo never stops the rest.
- **Timestamped log** + a pass/fail **summary** every run.

---

## Requirements

**Both scripts need:**
- **git** — https://git-scm.com
- A **GitHub Personal Access Token (PAT)** — see [below](#1-create-a-personal-access-token).

**PowerShell script:** nothing else (Windows 10/11 ships PowerShell).

**Bash script also needs:**
- **curl** (ships with most systems / Git-for-Windows)
- **jq** — https://jqlang.github.io/jq/
  - Debian/Ubuntu: `sudo apt install jq`
  - macOS: `brew install jq`

**Optional (only if you use `--lfs` / `-Lfs`):**
- **git-lfs** — https://git-lfs.com

---

## Setup

### 1. Create a Personal Access Token

A PAT is what lets the script see your **private** repos. The token **is your identity** —
you do **not** need to enter a username anywhere.

1. Go to **https://github.com/settings/tokens** → **Generate new token (classic)**.
2. Give it a name, set an expiry.
3. Scopes:
   - ✅ **`repo`** (full) — required, gives access to private repos.
   - ✅ **`read:org`** — add this if you also want repos from organizations you belong to.
4. Generate, then **copy the token** (it looks like `ghp_xxxxxxxx...`). You won't see it again.

> Keep the token secret. Treat it like a password. If leaked, revoke it on the same page.

### 2. Make the token available to the script

**Easiest — set it once as an environment variable:**

Windows (PowerShell), then **open a new terminal**:
```powershell
setx GITHUB_BACKUP_TOKEN "ghp_xxxxYOURTOKENxxxx"
```

Linux / macOS:
```bash
export GITHUB_BACKUP_TOKEN="ghp_xxxxYOURTOKENxxxx"
# (add that line to ~/.bashrc or ~/.zshrc to persist)
```

**Or do nothing** — if the variable isn't set, the script prompts you to paste the token
securely (input hidden) each run.

---

## Usage

### Windows (PowerShell)

```powershell
cd D:\Git\github

# Interactive: lists your drives, you pick one + a folder name
.\Backup-GitHubRepos.ps1

# Or name the destination directly
.\Backup-GitHubRepos.ps1 -Destination "E:\GitHubBackup"

# Everything: mirrors + LFS large files + portable bundles
.\Backup-GitHubRepos.ps1 -Destination "E:\GitHubBackup" -Lfs -Bundle
```

If PowerShell blocks the script ("running scripts is disabled"):
```powershell
powershell -ExecutionPolicy Bypass -File .\Backup-GitHubRepos.ps1 -Destination "E:\GitHubBackup"
```

### Linux / macOS / WSL / Git-Bash

```bash
cd /path/to/scripts
chmod +x backup-github-repos.sh        # first time only

# Interactive: lists mounted volumes, you type the destination path
./backup-github-repos.sh

# Or name the destination directly
./backup-github-repos.sh -d /mnt/usb/GitHubBackup

# Everything: mirrors + LFS + bundles
./backup-github-repos.sh -d /mnt/usb/GitHubBackup --lfs --bundle
```

### Options

| PowerShell | Bash | Meaning |
|-----------|------|---------|
| `-Destination <path>` | `-d <path>` | Where to store backups. Omit → interactive picker. |
| `-Bundle` | `--bundle` | Also write a single-file `<repo>.bundle` per repo. |
| `-Lfs` | `--lfs` | Also download Git LFS large files (needs git-lfs). |
| `-Affiliation <list>` | `-a <list>` | Which repos to include. Default `owner,collaborator,organization_member`. |
| `-Token <pat>` | *(env/prompt only)* | Pass the PAT inline (not recommended; prefer env var). |

---

## What you get on disk

```
E:\GitHubBackup\
├─ _logs\
│   └─ backup_2026-06-28_14-03-11.log     ← full run log
├─ your-username\
│   ├─ project-a.git\                     ← bare mirror (sync target)
│   ├─ project-a.bundle                   ← portable snapshot (if -Bundle)
│   └─ project-b.git\
└─ some-org\
    └─ shared-repo.git\
```

---

## Restoring

### From a mirror folder
```bash
git clone "E:\GitHubBackup\your-username\project-a.git" project-a
```

### From a bundle file
```bash
git clone "E:\GitHubBackup\your-username\project-a.bundle" project-a
```

Either gives you a normal working repo with all files and full history. To push it back
up to GitHub (or anywhere):
```bash
cd project-a
git remote set-url origin git@github.com:you/project-a.git
git push --all
git push --tags
```

### Inspecting a bundle (without cloning)

You can check a `.bundle` is valid and see what's inside it before restoring:

```bash
# Verify the bundle is intact and usable (integrity check)
git bundle verify project-a.bundle

# List the branches/tags packed inside, without unpacking
git bundle list-heads project-a.bundle
```

`verify` confirms the file isn't corrupt and contains a complete history.
`list-heads` prints every ref (branch/tag) stored in the bundle. Neither modifies anything.

---

## Mirror vs Bundle

Both contain the **exact same data** — full history, all branches, all tags. Nothing is
lost in either. They differ only in *shape*:

| | Mirror (`repo.git/` folder) | Bundle (`repo.bundle` file) |
|---|---|---|
| Form | A folder of git objects | **One single file** |
| Browse files directly? | No (bare repo) | No (packed) — clone it first to see files |
| Re-sync incrementally? | **Yes** (fast updates) | No — rebuilt fresh each run |
| Copy / move / archive? | Many files | **One file — easiest to move around** |
| Restore | `git clone repo.git out` | `git clone repo.bundle out` |

**In short:** a bundle is just as safe and complete as a clone — it simply packs the whole
repo into one file you can't peek inside until you clone from it. Use mirrors for repeated
syncing; add bundles when you want a tidy single-file snapshot to stash somewhere.

---

## Git LFS note

If some repos store large binaries via **Git LFS**, a plain mirror copies only the LFS
*pointer files*, not the actual large content. Pass `-Lfs` / `--lfs` to download the real
files too. Harmless to always enable — if a repo uses no LFS, there's simply nothing extra
to fetch. Requires **git-lfs** installed; if missing, the script warns and continues without it.

---

## Recommended routine (the 3-2-1 rule)

Don't rely on any single location. Keep:

- **3** copies of your data,
- on **2** different kinds of media,
- with **1** kept offsite.

Practical setup:
1. **GitHub** — your primary remote.
2. **This backup** — on your external HDD (run the script periodically).
3. Optionally a **second remote** (e.g. a free Codeberg/GitLab account, or a self-hosted
   Gitea) so a copy lives online but independent of GitHub.

Plug the HDD in every so often, run the script, unplug. New commits sync in seconds.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Could not authenticate to GitHub` | Token wrong/expired, or missing `repo` scope. Regenerate it. |
| No private repos appear | Token needs the **`repo`** scope (full). |
| No org repos appear | Add the **`read:org`** scope to the token. |
| `running scripts is disabled` (PowerShell) | Use `powershell -ExecutionPolicy Bypass -File ...`. |
| `'jq' not found` (bash) | Install jq (see [Requirements](#requirements)). |
| Some repos show **FAILED** | Re-run the script — it retries only what's missing/outdated. Check the log in `_logs\`. |
| LFS skipped | Install **git-lfs** (https://git-lfs.com), then re-run with `-Lfs` / `--lfs`. |

---

## Security notes

- The token is **never written to the backup drive** — it's passed to each git command in
  memory only. The stored repo configs contain plain `https://github.com/...` URLs.
- Anyone with your token can read your private repos. Don't commit it, don't share logs that
  might contain it, and revoke it at https://github.com/settings/tokens if exposed.
- Set a sensible **expiry** on the token and regenerate when it lapses.
