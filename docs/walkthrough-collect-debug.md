# Code Walkthrough — `control-repo/scripts/collect-debug.sh`

**Audience:** new engineer joining the ZMS AWS lab.
**Prerequisite reading:** `control-repo/README.md` (repo layout), `FIXES-SUMMARY.md` (why
several of these probes exist at all).

This script is a **read-only diagnostic collector**. It runs on the Ansible control node,
gathers everything needed to diagnose a failed estate converge, and packages it into a
tarball you can hand to someone else.

Two properties drive nearly every design decision in the file, so internalise them before
reading the code:

1. **It must never make things worse.** It runs while the estate is already broken. It
   therefore never applies configuration, never runs a playbook, and never blocks forever.
2. **It must never leak secrets.** The bundle gets emailed, pasted into tickets, and
   attached to chat threads. It captures *identifiers* (region, account id, secret **name**)
   but never *credentials*.

> **Origin note.** This script was written during a long debugging campaign where each
> failure masked the next one. Several probes exist because a specific bug wasted hours —
> those are called out inline. See `FIXES-SUMMARY.md` for the full incident history.

---

## Table of contents

1. [Header & usage contract](#1-header--usage-contract)
2. [`set -o pipefail`](#2-set--o-pipefail)
3. [Configuration block](#3-configuration-block)
4. [Environment setup](#4-environment-setup)
5. [Helper functions](#5-helper-functions)
6. [Report preamble](#6-report-preamble)
7. [Probe sections 1–13](#7-probe-sections)
8. [Redaction pass](#8-redaction-pass)
9. [Packaging & operator instructions](#9-packaging--operator-instructions)
10. [Glossary](#glossary)
11. [Flagged issues](#flagged-issues)

---

## 1. Header & usage contract

```bash
#!/usr/bin/env bash
#
# collect-debug.sh - Gather Ansible failure diagnostics from the ZMS AWS control node.
# ...
# Usage:
#   ./collect-debug.sh              # collect what the current user can read
#   sudo ./collect-debug.sh         # also capture root-owned logs/keys/journals
#
# SECURITY: the bundle may contain identifiers ... but deliberately avoids secrets ...
```

**What it does.** `#!/usr/bin/env bash` is the shebang: it asks the OS to locate `bash` via
`PATH` rather than hardcoding `/bin/bash`. The rest is a comment block.

**Why it's written this way.** `env bash` is portable across distros where bash may live in
different paths. More importantly, the comment block is a **contract**, not decoration:

- The dual usage modes are documented because the script behaves *differently but validly*
  under each. Without `sudo`, root-owned files (`estate.env`, the SSH key, journals) come
  back as "not readable" — that's a degraded-but-useful bundle, not a failure.
- The SECURITY paragraph tells a reviewer what they're allowed to do with the output. This
  matters because the natural instinct with a debug bundle is to paste it into a ticket.

**Gotcha.** Running without `sudo` produces a bundle that *looks* complete but silently
omits the most diagnostic content (journals, `estate.env`). Several past debugging rounds
were slowed by exactly this — a non-sudo bundle showed `ANSIBLE_SECRET_NAME NOT set`, which
looked like a real bug but was just an unreadable file. **Always ask for `sudo` bundles.**

---

## 2. `set -o pipefail`

```bash
set -o pipefail
```

**What it does.** Changes pipeline exit-status semantics. Normally `a | b` exits with `b`'s
status; with `pipefail` it exits with the **rightmost non-zero** status. So
`tail file | grep x` fails if `tail` fails, not just if `grep` finds nothing.

**Why it's written this way — and what's deliberately absent.** Note what is *not* here:

- **No `set -e`** (exit on error). This is intentional and load-bearing. A diagnostic tool
  must keep going when a probe fails — a missing SSH key *is the finding*, not a reason to
  abort. If you add `set -e`, the script will die on the first failing probe and produce a
  near-empty bundle.
- **No `set -u`** (error on unset variable). The script deliberately reads possibly-unset
  vars like `$ANSIBLE_SECRET_NAME`; `set -u` would abort instead of reporting them absent.

> **Do not "fix" this by adding `set -euo pipefail`.** That idiom is correct for deployment
> scripts (see `reconverge.sh`) and wrong here. Different tool, different contract.

---

## 3. Configuration block

```bash
REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"
ENV_FILE="/etc/ansible/estate.env"
LOG_DIR="/var/log/ansible"
KEY_FILE="/etc/ansible/keys/ansible_rsa"
IMDS="http://169.254.169.254"
TS="$(date -u +%Y%m%d-%H%M%SZ)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUT_DIR="/tmp/ansible-debug-${HOST}-${TS}"
REPORT="${OUT_DIR}/report.txt"
mkdir -p "$OUT_DIR"
```

**What it does.**

- `${CONTROL_REPO_DIR:-/opt/control-repo}` is bash **parameter expansion with a default**:
  use `$CONTROL_REPO_DIR` if set and non-empty, else the literal path.
- `$( ... )` is command substitution — run the command, substitute its stdout.
- `date -u +%Y%m%d-%H%M%SZ` produces e.g. `20260803-093054Z`. `-u` forces UTC.
- `hostname -s 2>/dev/null || hostname` tries the short hostname; if that flag is
  unsupported, `||` falls back to plain `hostname`.
- `mkdir -p` creates the directory and its parents, and does **not** error if it exists.

**Why it's written this way.**

- `CONTROL_REPO_DIR` is overridable because the same variable is set in `estate.env` by
  Terraform. The default keeps the script usable standalone.
- **UTC timestamps** matter because the estate spans regions and the logs you're correlating
  (`journalctl`, `ansible.log`) are UTC. A local-time bundle name makes correlation harder.
- **Hostname in the output path** because bundles from different control nodes get compared
  side by side. During debugging we frequently had bundles from three different rebuilt
  nodes; without the hostname they'd be indistinguishable.
- `/tmp` is used because it's writable by any user — the script must work non-root.

**Dependencies.** `KEY_FILE` must match the path in
`inventory/group_vars/all.yml` → `ansible_ssh_private_key_file`. **These are two independent
literals that must agree.** They already drifted once (`ansible_ed25519` vs `ansible_rsa`)
and produced a false "key missing" report. If you change one, change both.

**Gotcha.** `IMDS` is the **link-local** address `169.254.169.254`. It is not routable and
not DNS-resolvable; it only works from inside an EC2 instance. Running this script on your
laptop makes every IMDS probe time out (bounded by `--max-time 10`, so it degrades rather
than hangs).

---

## 4. Environment setup

```bash
export PATH="/usr/local/bin:/usr/bin:${PATH}"
export ANSIBLE_LOG_PATH="${OUT_DIR}/ansible-collect.log"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE" 2>/dev/null || true; set +a; }
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
```

**What it does, line by line.**

1. **`export PATH=...`** — prepends standard bin directories. `export` marks the variable for
   inheritance by child processes.
2. **`export ANSIBLE_LOG_PATH=...`** — Ansible writes its run log here instead of the
   configured `/var/log/ansible/ansible.log`.
3. **`[ -f "$ENV_FILE" ] && { ... }`** — `[ -f ]` tests file existence. `&&` short-circuits:
   the brace group only runs if the test passed. Inside: `set -a` turns on **auto-export**
   (every subsequent assignment is exported), `.` sources the file, `set +a` turns it back
   off. The `|| true` swallows a sourcing error.
4. **`REGION=...`** — **nested** parameter expansion: try `AWS_REGION`, else
   `AWS_DEFAULT_REGION`, else empty string.

**Why it's written this way.**

- **`ANSIBLE_LOG_PATH` redirection is a correctness fix, not a nicety.** The control node's
  shared `ansible.log` is owned by the service user. A non-root run would either fail to
  write it (emitting `log file is not writeable ... aborting` noise into the very report
  you're reading) or, worse, **append diagnostic output into the log the script is trying to
  collect**, corrupting the evidence. Redirecting to `$OUT_DIR` keeps collection read-only.
- **`set -a` around the source** is how `estate.env` (a plain `KEY=value` file) gets its
  values into the environment of the `curl`/`aws` child processes below.
- **`REGION` fallback chain** exists because the region can arrive via Terraform's
  `estate.env` (`AWS_REGION`) or the operator's shell (`AWS_DEFAULT_REGION`).

**Business rule (plain English):** *If the injected environment file is unreadable, the
script continues with an empty region and reports probes as "unset" rather than failing.*

**⚠️ Gotcha — an inconsistency worth knowing.** This line uses `[ -f ]` (exists):

```bash
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE" 2>/dev/null || true; set +a; }
```

but the sibling script `reconverge.sh` was **changed to `[ -r ]` (readable)** after a
production incident: `estate.env` is `0640 root:root`, so for the non-root service user
`[ -f ]` passed but the `source` then failed *Permission denied*, and under `set -e` that
killed the bootstrap before it wrote the SSH key.

Here the pattern is **safe** only because of the belt-and-braces `2>/dev/null || true` and
the absence of `set -e`. It is nonetheless inconsistent with `reconverge.sh` and a latent
trap if someone later adds `set -e`. **Recommend changing to `[ -r ]` for consistency.**

---

## 5. Helper functions

The whole script is built from three helpers. Understanding them makes the remaining
150 lines trivial to read.

### 5.1 `section`

```bash
section() { printf '\n\n========== %s ==========\n' "$*" >>"$REPORT"; }
```

**What it does.** `$*` joins all arguments into one space-separated string. `printf` writes a
banner; `>>` appends to `$REPORT`.

**Why.** Pure formatting — makes a 500-line report skimmable. Downstream tooling (and the
humans reading it) `grep` for these banners.

### 5.2 `run` — execute a command directly

```bash
run() {   # run <label> <cmd...>
  local label="$1"; shift
  printf '\n$ %s\n' "$label" >>"$REPORT"
  timeout 60 "$@" >>"$REPORT" 2>&1 || printf '[exit %s / not available]\n' "$?" >>"$REPORT"
}
```

**What it does.**

- `local label="$1"` — `local` scopes the variable to the function (without it, you'd mutate
  a global).
- `shift` removes `$1`, so `"$@"` now holds only the command and its arguments.
- `"$@"` expands to the remaining arguments **as separate words**, preserving arguments that
  contain spaces. This is the critical difference from `$*`.
- `timeout 60` kills the command after 60 seconds.
- `>>"$REPORT" 2>&1` appends stdout, then redirects stderr **to the same place stdout now
  points**. Order matters: reversing them would send stderr to the old stdout (the terminal).
- `|| printf '[exit %s ...]' "$?"` — on non-zero exit, record the code instead of failing.

**Why it's written this way.**

- **`timeout` is mandatory, not defensive.** This script runs on a broken machine. Any probe
  can hang forever — DNS with no resolver, `curl` to an unroutable IMDS, `systemctl` on a
  wedged D-Bus. Without `timeout`, one hung probe means no bundle at all.
- **The `||` fallback is the core "never abort" contract.** Every probe is allowed to fail;
  the failure is *recorded as data*. A missing SSH key or an unreachable IMDS is precisely
  what you're trying to learn.

**Gotcha.** `run` does **not** invoke a shell, so it cannot use pipes, globs, redirection, or
`&&`. `run "x" foo | bar` will not do what you expect — the pipe binds to the `run` call
itself, not the inner command. Use `runsh` when you need shell syntax.

### 5.3 `runsh` — execute a shell string

```bash
runsh() { # runsh <label> <shell string>
  local label="$1"; shift
  printf '\n$ %s\n' "$label" >>"$REPORT"
  timeout 120 bash -lc "$*" >>"$REPORT" 2>&1 || printf '[exit %s / not available]\n' "$?" >>"$REPORT"
}
```

**What it does.** Same shape as `run`, but pipes the remaining arguments (joined by `$*`)
into `bash -lc`. `-c` means "run this string"; `-l` makes it a login shell (reads profile
files). Timeout is **120s**, double `run`'s.

**Why.** Most probes need pipes and `||` fallbacks, which requires a real shell. The longer
timeout accommodates network probes (`curl`, `getent`) that are slower than local commands.

**⚠️ Gotcha — quoting is the #1 hazard in this file.** Because the argument is a *string*
that bash will re-parse, `$` must be escaped when you want the **inner** shell to evaluate it,
and left unescaped when you want the **outer** shell to substitute now. Compare:

```bash
runsh "..." "T=\$(curl ...); curl -H \"X-aws-ec2-metadata-token: \$T\" ... '${IMDS}/...'"
#            ^^ escaped: evaluated by inner shell        ^^^^^^^^ unescaped: expanded now
```

`\$T` and `\$(...)` are deferred to the inner shell; `${IMDS}` is substituted by the outer
shell before `bash -lc` ever sees the string. Getting this backwards produces silently wrong
probes — the classic failure is a variable expanding to empty in the outer shell, leaving a
command that runs but tests nothing.

**Related real incident:** the same class of bug (a runtime variable eaten by an outer shell)
broke the Azure lab's cloud-init. See `FIXES-SUMMARY.md`.

### 5.4 `copy` — collect a file

```bash
copy() {  # copy <src> [destname]
  local src="$1"; local dst="${2:-$(basename "$1")}"
  if [ -r "$src" ]; then
    cp -a "$src" "${OUT_DIR}/${dst}" 2>/dev/null \
      && printf '  collected: %s\n' "$src" >>"$REPORT" \
      || printf '  could not copy: %s\n' "$src" >>"$REPORT"
  else
    printf '  not readable (try sudo): %s\n' "$src" >>"$REPORT"
  fi
}
```

**What it does.** `${2:-$(basename "$1")}` defaults the destination name to the source's
basename. `[ -r ]` tests **readability** (not mere existence). `cp -a` is archive mode:
preserves mode, ownership and timestamps, and recurses.

**Why it's written this way.**

- **`[ -r ]` not `[ -f ]`** — this is the correct test here, and note it's the *opposite*
  choice from line 41. A file that exists but is unreadable is the single most common
  situation in a non-sudo run, and the operator needs to be told **"try sudo"** rather than
  seeing a confusing `cp` error.
- **`cp -a` preserves the mode**, which is itself diagnostic — for the SSH key, the
  permissions *are* the thing you're investigating.
- The three-way outcome (`collected` / `could not copy` / `not readable`) means the report
  always states what happened. Silence would be ambiguous.

**Gotcha.** `A && B || C` is **not** if/else. If `B` (the success `printf`) ever failed, `C`
would also run. Here `printf`-to-a-file effectively never fails, so it's safe — but don't
copy this idiom into code where `B` can fail.

---

## 6. Report preamble

```bash
{
  echo "ZMS AWS control-node Ansible debug bundle"
  echo "generated : $(date -u) (UTC)"
  echo "user      : $(id -un) (uid $(id -u))"
  echo "host      : $(hostname -f 2>/dev/null || hostname)"
  echo "repo_dir  : ${REPO_DIR}"
  echo "region    : ${REGION:-<unset>}"
} >"$REPORT"
```

**What it does.** `{ ...; }` is a **command group** — the commands run in the *current* shell
(unlike `( ... )`, a subshell). One `>` redirect applies to the whole group. Note this is `>`
(truncate/create), the only place in the script that isn't `>>`; it establishes the file that
every later helper appends to.

**Why.** Every field is here because its absence caused a misdiagnosis at some point:

- **`user` / `uid`** — immediately tells the reader whether this is a sudo bundle. This is
  the field that resolves "is `ANSIBLE_SECRET_NAME NOT set` a real bug or a permissions
  artifact?" It answered exactly that question during debugging.
- **`region`** with an explicit `<unset>` marker — an empty region silently disables the AWS
  probes, so it must be visible rather than blank.
- **`host`** — bundles from successive rebuilt control nodes are otherwise indistinguishable.

**Ordering dependency.** This block **must** run before any helper, since helpers use `>>`
and would be truncated by this `>`. Don't move it.

---

## 7. Probe sections

All thirteen sections follow the same shape, so this covers the reasoning rather than
repeating mechanics. Each is introduced by `section "..."` and built from `run`/`runsh`/`copy`.

### §1–2 Host / OS and cloud-init

```bash
section "CLOUD-INIT"
run "cloud-init status --long" cloud-init status --long
copy /var/log/cloud-init-output.log cloud-init-output.log
```

**Why.** The control node is built entirely by cloud-init (installs Ansible, clones the repo,
installs the systemd timers). If cloud-init partially failed, *everything* downstream is
suspect. This has real precedent: a run once showed
`Failed to install the following packages: {'python3-pip'}` — which correctly told us the
bootstrap was degraded but, in that instance, harmless.

### §3 Ansible / Python environment

```bash
printf '\n$ python import check (boto3 / winrm)\n' >>"$REPORT"
timeout 30 python3 - >>"$REPORT" 2>&1 <<'PY' || printf '[python not available]\n' >>"$REPORT"
mods = ['boto3', 'botocore', 'winrm']
for m in mods:
    try:
        __import__(m)
        print('ok  ', m)
    except Exception as e:
        print('FAIL', m, '->', repr(e))
PY
```

**What it does.** `python3 -` reads the program from **stdin**. `<<'PY' ... PY` is a
heredoc; quoting the delimiter (`'PY'`) **disables shell expansion inside**, so `$` and
backticks in the Python source are passed through literally. `__import__(m)` imports by
name at runtime, inside `try/except`.

**Why this specific probe exists.** These are the two dependencies whose absence produces
*misleading* errors:

- **`boto3`/`botocore`** — `amazon.aws` needs them. Without them the dynamic inventory
  returns **zero hosts**, which looks like a tagging or region problem, not a missing library.
- **`winrm` (pywinrm)** — the Windows path needs it. Its absence surfaces as
  `No module named 'winrm'` mid-play, after everything else looked healthy.

**Business rule:** *Report each dependency as present or absent with the actual exception,
rather than letting a missing library masquerade as a configuration error.*

### §4–5 Configuration and inventory

```bash
runsh "ansible-inventory --graph" "cd '${REPO_DIR}' && ansible-inventory --graph 2>&1"
```

**🔒 Security-critical decision — do not change this to `--list`.**

`--graph` prints group/host **structure only**. `--list` (and `--vars`) **resolve host
variables**, and this repo's `group_vars/os_windows.yml` defines `ansible_password` via an
inline `amazon.aws.aws_secret` lookup. Running `--list` would therefore **fetch the
consolidated secret from AWS Secrets Manager and print WinRM credentials into the bundle.**

This is stated in the file header and repeated in the section comment because it is the
single most dangerous edit someone could make to this script.

**The `cd` is also required, not cosmetic.** Ansible only auto-loads `ansible.cfg` from the
**current working directory**. Running from elsewhere silently falls back to
`/etc/ansible/ansible.cfg`, which has no `aws_ec2` inventory configured — producing
`provided hosts list is empty, only localhost is available`. This exact mistake once produced
a misleading "no Windows hosts" result during live debugging.

### §6 IAM role via IMDSv2

```bash
runsh "IMDSv2 token (status)" "curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X PUT '${IMDS}/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' --max-time 10 || echo 'IMDS unreachable'"
runsh "attached IAM role name" "T=\$(curl ... ); curl -s -H \"X-aws-ec2-metadata-token: \$T\" ... '${IMDS}/latest/meta-data/iam/security-credentials/' ..."
runsh "role creds endpoint (status only, NOT the creds)" "... curl -s -o /dev/null -w 'HTTP %{http_code}\n' ..."
```

**What it does.** IMDSv2 is session-based: you `PUT` to `/latest/api/token` to get a token,
then send it in `X-aws-ec2-metadata-token` on every subsequent request.

- `-s` silent, `-o /dev/null` discard the body, `-w 'HTTP %{http_code}'` print **only** the
  status code, `--max-time 10` bound the request.

**Why — the security design is the point.** Note the deliberate asymmetry:

| Probe | Captures | Rationale |
|---|---|---|
| Token request | status code only | proves IMDSv2 is reachable |
| Role listing | the role **name** | identifies which IAM role is attached |
| Credentials endpoint | **status code only** | proves creds are obtainable **without capturing them** |

`-o /dev/null` on the third probe is doing the security work. Fetching that URL normally
returns a live `AccessKeyId` / `SecretAccessKey` / `SessionToken`. Deleting `-o /dev/null`
would put **live AWS credentials into a file people paste into tickets.** Treat that flag as
load-bearing.

### §7 Secrets Manager — metadata only

```bash
runsh "describe-secret (no value)" "command -v aws >/dev/null 2>&1 && [ -n \"\${ANSIBLE_SECRET_NAME:-}\" ] && aws secretsmanager describe-secret --secret-id \"\$ANSIBLE_SECRET_NAME\" ${REGION:+--region $REGION} 2>&1 | head -n 40 || ..."
```

**What it does.** `command -v aws` tests whether the CLI exists. `${REGION:+--region $REGION}`
is **alternate-value expansion**: emits `--region <value>` only if `REGION` is non-empty, and
emits *nothing* otherwise — avoiding a malformed `--region ` with a dangling flag.

**Why.** `describe-secret` returns metadata (ARN, rotation config, timestamps) and **never
the secret value** — that requires `get-secret-value`, which this script never calls. The
purpose is to answer "can this node see the secret, and is it the one Terraform created?"
without ever materialising credentials.

**Business rule:** *Prove the secret is reachable and correctly named; never read it.*

**Gotcha.** `command -v aws` degrading to "aws CLI not installed" is a **real** state — the
control node installs Ansible and boto3 but not necessarily the AWS CLI. Two probes no-op
because of this. That's accepted, not a bug.

### §8 DNS and egress

**Why.** Distinguishes *name resolution* failure from *connectivity* failure — two very
different root causes that produce the same "it doesn't work" symptom. The
`secretsmanager.<region>.amazonaws.com` probe specifically validates the path the secret
lookup depends on.

### §9 SSH key — metadata only

```bash
runsh "key file perms/owner" "ls -l '${KEY_FILE}' 2>&1 || echo 'key file missing (bootstrap.yml not run?)'"
runsh "key fingerprint" "ssh-keygen -lf '${KEY_FILE}' 2>&1 || echo 'cannot read fingerprint'"
```

**Why — both probes earned their place through incidents.**

- **`ls -l`** shows **owner and mode**, which was the actual root cause of a real outage: the
  key was written `root:root 0600` while the systemd timers run as `ubuntu`, so the SSH
  client couldn't read it. Every Linux host reported `UNREACHABLE`. Mode/owner *is* the bug.
- **The fallback message names the likely cause** ("bootstrap.yml not run?"), because a
  missing key means the bootstrap play didn't complete — which was itself caused by an
  unrelated failure in `reconverge.sh`.
- **`ssh-keygen -lf`** prints a fingerprint, never the key material.

**Business rule:** *Capture the key's existence, ownership, mode and fingerprint. Never its
contents.*

### §10–11 Logs, systemd units and journals

```bash
for u in ansible-bootstrap ansible-estate; do
  run "status ${u}.service" systemctl status "${u}.service" --no-pager -l
  runsh "journal ${u} (last 200)" "journalctl -u ${u}.service -n 200 --no-pager 2>&1 || ..."
done
```

**What it does.** A `for` loop over the two unit names. `--no-pager` prevents `less` from
launching and hanging a non-interactive run. `-n 200` bounds the journal output.

**Why.** The two timers are the entire automation:

- `ansible-bootstrap` — self-configures the control node (writes the SSH key from the secret)
- `ansible-estate` — converges the managed estate

`converge-status.log` is the fastest signal in the whole bundle: one line per run,
`result=success exit=0` or otherwise. Read it first.

**Gotcha.** `--no-pager` is essential. Without it these commands can block forever waiting on
a pager that has no terminal — and `timeout` would then be the only thing saving the run.

### §12 Repo state and syntax checks

```bash
runsh "git log/status" "cd '${REPO_DIR}' && git -c safe.directory='${REPO_DIR}' log --oneline -n 5 2>&1; ..."
```

**What it does.** `-c safe.directory=...` sets config for this invocation only.

**Why.** Modern git refuses to operate on a repo owned by a different user ("dubious
ownership") — which is exactly the case when root runs this against a repo owned by `ubuntu`.
Without this flag the probe returns an error instead of the commit log.

**This probe is disproportionately valuable.** The commit list answers "does the node
actually have the fix I pushed?" — a question that came up in nearly every debugging round,
and which repeatedly explained "the fix didn't work" (it hadn't been pulled). `git status -s`
additionally reveals local edits that would block `git pull --ff-only`.

### §13 Live connectivity probes

```bash
runsh "ping Linux (SSH)" "cd '${REPO_DIR}' && timeout 90 ansible os_linux -m ansible.builtin.ping -o 2>&1 | tail -n 50 || echo 'skipped/failed'"
runsh "ping Windows (WinRM)" "cd '${REPO_DIR}' && timeout 120 ansible os_windows -m ansible.windows.win_ping -o 2>&1 | tail -n 50 || echo 'skipped/failed'"
```

**What it does.** Ad-hoc module runs. `ping` is an SSH+Python round-trip (not ICMP);
`win_ping` is its WinRM equivalent. `-o` requests one-line-per-host output. Note the
**nested** timeouts: `timeout 90` inside `runsh`'s own `timeout 120`.

**Why.** These are the only probes that touch the managed estate, and they're placed **last**
deliberately — everything before is local and cheap. Splitting Linux from Windows separates
two independent failure domains: SSH/key issues vs. WinRM/credential issues.

**⚠️ Gotcha — deprecation.** `-o` emits
`The '-o' argument is deprecated ... will be removed from ansible-core 2.23`. Harmless now;
will break on a future core. **Flagged for follow-up.**

**Gotcha — verbosity.** Comment says "credentials are NOT printed" — true at *default*
verbosity. If you add `-vvv` here, Ansible dumps module args including the WinRM password
into the bundle. Don't.

---

## 8. Redaction pass

```bash
find "$OUT_DIR" -type f -print0 2>/dev/null | xargs -0 -r sed -i -E \
  -e 's/(access_token"?[[:space:]]*[:=][[:space:]]*"?)[A-Za-z0-9._-]+/\1<REDACTED>/g' \
  -e 's/(Bearer )[A-Za-z0-9._+/=-]+/\1<REDACTED>/g' \
  -e 's/([Pp]assword"?[[:space:]]*[:=][[:space:]]*"?)[^",[:space:]]+/\1<REDACTED>/g' \
  -e 's/("?SecretAccessKey"?[[:space:]]*[:=][[:space:]]*"?)[A-Za-z0-9/+=]+/\1<REDACTED>/g' \
  -e 's/("?SessionToken"?[[:space:]]*[:=][[:space:]]*"?)[A-Za-z0-9/+=._-]+/\1<REDACTED>/g' \
  -e 's/(aws_secret_access_key[[:space:]]*=[[:space:]]*)[A-Za-z0-9/+=]+/\1<REDACTED>/g' \
  2>/dev/null || true
```

**What it does.**

- `find ... -print0` emits NUL-separated paths; `xargs -0` reads them. This pair handles
  filenames containing spaces or newlines safely.
- `xargs -r` (GNU) does not run the command at all if input is empty — prevents `sed` from
  hanging on stdin.
- `sed -i -E` edits in place with extended regex. Multiple `-e` scripts apply in sequence.
- `\1` back-references capture group 1 — i.e. **keep the key name, replace the value**, so
  the reader can still see *that* a password field existed.

**Why.** This is **defence in depth**, not the primary control. The primary controls are the
design decisions above (`--graph` not `--list`, `-o /dev/null`, `describe-secret` not
`get-secret-value`). This pass is the backstop for secrets that leak in via a path nobody
anticipated — e.g. an AWS CLI error message echoing a credential.

**Business rule:** *Anything resembling a token, password, or AWS key is replaced with
`<REDACTED>` before packaging, while preserving the surrounding field name for context.*

**⚠️ Gotchas.**

- **Regex redaction is inherently incomplete.** It matches *known shapes*. A secret in an
  unanticipated format passes through. Hence the header's instruction to review the bundle.
- **The `[Pp]assword` pattern is greedy in a useful way but can over-redact** — it will
  scrub the word after any `password:`-like token, including in prose or an unrelated config
  key. Acceptable trade-off: over-redaction is safe, under-redaction is not.
- **`|| true` at the end** — if `sed` fails on some file, the script must still produce a
  tarball. Losing the bundle over a redaction hiccup would defeat the purpose.

---

## 9. Packaging & operator instructions

```bash
TARBALL="/tmp/ansible-debug-${HOST}-${TS}.tar"
tar -cf "$TARBALL" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")" 2>/dev/null
```

**What it does.** `-c` create, `-f` to file. `-C <dir>` changes directory **before**
archiving, and archiving `$(basename ...)` means the tarball contains a clean relative path
(`ansible-debug-host-ts/...`) rather than absolute `/tmp/...` paths.

**Why.** Absolute paths in a tarball are a well-known extraction hazard. The `-C` + basename
idiom is the standard fix.

**📌 Note — this was changed from `.tar.gz` to `.tar`.** The commit message reads
*"stopped using gzip compression"*. Reason not documented in the code —
**needs confirmation from the original author**; the plausible motivation is that an
uncompressed tar is easier to inspect or was required by an upload path, but that is
inference, not fact. Both `TARBALL` and the `tar` flags were updated consistently, so this is
a deliberate change, not a bug.

```bash
echo "Copy it off the node, e.g. from your workstation:"
echo "  scp -i <key>.pem -o ProxyJump=ubuntu@<bastion-ip> ubuntu@$(hostname -s):$TARBALL ."
echo "  # or via SSM:  aws ssm start-session --target <control-instance-id>"
echo "Review before sharing (contains account id / region / secret-name identifiers)."
echo "Re-run with sudo to include root-owned logs, keys, and journals."
```

**Why.** The control node is in a **private subnet with no public IP**, so retrieving the file
is non-obvious. Both documented routes (bastion `ProxyJump`, SSM Session Manager) reflect the
lab's actual topology. The final two lines restate the security caveat and the sudo hint at
the moment the operator is deciding what to do next — which is when they'll actually read it.

---

## Glossary

| Term | Meaning |
|---|---|
| **Control node** | The EC2 instance running Ansible; pushes config to the estate. Private subnet, no public IP. |
| **Estate** | The collection of managed hosts (Ubuntu, Amazon Linux, Windows) — everything *except* the control node and bastions. |
| **Converge** | One full application of desired state. `converge-status.log` records one line per run. |
| **Bootstrap** | The control node configuring *itself* (`bootstrap.yml`): install collections, write the SSH key from Secrets Manager. |
| **`estate.env`** | `/etc/ansible/estate.env` — Terraform-injected `KEY=value` file holding `AWS_REGION`, `ANSIBLE_SECRET_NAME`, `CONTROL_REPO_DIR`. **Names only, never secrets.** Mode `0640 root:root`. |
| **Consolidated secret** | One AWS Secrets Manager secret per deployment holding a JSON document with all credentials (SSH key, WinRM creds, DSRM, domain-join, MySQL, Samba). Referenced by *name*; the value is fetched at run time. |
| **IMDS / IMDSv2** | EC2 Instance Metadata Service at `169.254.169.254`. v2 is session-based (PUT for a token, then send it as a header). |
| **Dynamic inventory** | `inventory/aws_ec2.yml` — queries EC2 at run time; no static host list. |
| **`os_linux` / `os_windows`** | Inventory groups derived from the `OS` EC2 tag. |
| **`distro_*`** | Groups from the `Distro` tag (`distro_ubuntu`, `distro_amazon`); determines the SSH login user. |
| **`role_*`** | Groups from the `Role` tag (`role_web`, `role_db`, `role_dc`, `role_rodc`, …). **Spans both OSes** — always intersect with an OS/distro group when targeting. |
| **Field-scoped lookup** | The convention of resolving *one* key from the consolidated secret inline at point of use, under `no_log`, rather than binding the whole secret to a variable. |
| **DSRM** | Directory Services Restore Mode — the AD "safe mode" password. |
| **RODC** | Read-Only Domain Controller. |

### Naming conventions

- `SCREAMING_CASE` — script-level config constants (`REPO_DIR`, `OUT_DIR`).
- `lower_case()` — helper functions.
- Numbered `# N)` comments — probe section ordering; cheap/local probes first, network and
  estate-touching probes last.
- Probe labels passed to `run`/`runsh` are the strings you `grep` for in `report.txt`; treat
  them as a stable interface.

---

## Flagged issues

Called out explicitly rather than rationalised:

1. **`[ -f "$ENV_FILE" ]` on line 41 is inconsistent with `reconverge.sh`**, which was
   deliberately changed to `[ -r ]` after an incident where an unreadable-but-present file
   killed the bootstrap. Safe *here* only because there's no `set -e` and errors are
   suppressed. **Recommend `[ -r ]` for consistency and future-proofing.**

2. **Duplicated path literal.** `KEY_FILE` hardcodes `/etc/ansible/keys/ansible_rsa`, which
   must match `ansible_ssh_private_key_file` in `inventory/group_vars/all.yml`. These have
   already drifted once. No mechanism enforces agreement.

3. **`-o` is deprecated** in the two connectivity probes (removal targeted for
   ansible-core 2.23). Currently emits a warning; will eventually fail.

4. **`.tar` vs `.tar.gz` change** — deliberate per commit message, rationale undocumented.
   **Needs confirmation from the original author.**

5. **Two probes silently no-op if the AWS CLI is absent** (`sts get-caller-identity`,
   `describe-secret`). The control node does not install the CLI by default. Not a bug — the
   fallback message is explicit — but a newcomer may expect those sections to be populated.

6. **`xargs -r` and `sed -i` are GNU-specific.** Fine on Ubuntu (the control node's OS);
   would need adjusting on BusyBox or macOS.
