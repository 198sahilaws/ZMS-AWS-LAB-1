# Code Walkthrough — Ansible Core & the Execution Model

**Audience:** new engineer joining the ZMS AWS lab.
**Files covered (7):**

```
control-repo/ansible.cfg
control-repo/requirements.yml
control-repo/bootstrap.yml
control-repo/site.yml
control-repo/orchestrate.yml
control-repo/local.yml
control-repo/scripts/converge.sh
```

**Prerequisite reading:** `docs/walkthrough-inventory-and-groupvars.md` (groups & connection
settings), `FIXES-SUMMARY.md`.

---

## Mental model: what runs what

Nobody logs in and types `ansible-playbook`. Two systemd timers drive everything:

```
   ansible-bootstrap.timer  (every ~30 min)
        └─> reconverge.sh
              ├─ git pull --ff-only          (fetch latest control-repo)
              ├─ ansible-galaxy install      (refresh collections)
              └─ ansible-playbook bootstrap.yml   ← control node configures ITSELF
                     └─ writes /etc/ansible/keys/ansible_rsa from Secrets Manager

   ansible-estate.timer     (every ~60 min)
        └─> converge.sh                       ← THE RUNNER
              ├─ ansible-playbook site.yml                  (baseline)
              ├─ ansible-playbook playbooks/ubuntu-apache2.yml
              ├─ ... 12 more, each its OWN process ...
              └─ CONVERGE SUMMARY (passed / failed) → exit 0 or 1
```

**The dependency that matters:** `bootstrap` must succeed before `estate` can do anything,
because bootstrap writes the SSH key that estate needs. When bootstrap silently failed once,
every Linux host reported `UNREACHABLE` and the cause was three layers away.

**Two entry points, one ordering.** `orchestrate.yml` and `converge.sh` both encode the same
playbook sequence. The timer runs **`converge.sh`**; `orchestrate.yml` is the manual,
fail-fast equivalent. See [Flagged issue #1](#flagged-issues) — this duplication is a real
maintenance hazard.

---

## 1. `ansible.cfg` — global configuration

### 1.1 `[defaults]` — paths and discovery

```ini
[defaults]
inventory            = inventory/aws_ec2.yml
roles_path           = roles
collections_path     = collections
```

**What it does.** Sets the default inventory source, where to find roles, and where
collections are installed/loaded from. All three are **relative paths**.

**🔴 The most common operational mistake in this repo.** Ansible only auto-loads `ansible.cfg`
from the **current working directory** (or `ANSIBLE_CONFIG`, `~/.ansible.cfg`,
`/etc/ansible/ansible.cfg` — in that precedence order). Run from anywhere other than the repo
root and:

- this file is not read,
- Ansible falls back to `/etc/ansible/ansible.cfg`, which has **no `aws_ec2` inventory**,
- you get `provided hosts list is empty, only localhost is available`.

This happened live during debugging — a `win_ping` run from `/opt/control-repo/scripts`
returned "no hosts", which looked like an inventory failure but was purely a `cd` problem.

**Business rule (plain English):** *Every Ansible invocation must run from the control-repo
root.* This is why `converge.sh`, `reconverge.sh` and `collect-debug.sh` all `cd` first, and
why every documented command starts with `cd /opt/control-repo`.

**Dependency.** `collections_path = collections` means collections install into
`/opt/control-repo/collections/`, which is **gitignored** (it shows as `?? collections/` in
`git status` — expected, not dirt).

### 1.2 `[defaults]` — connection behaviour

```ini
# Ephemeral cloud hosts churn keys.
host_key_checking    = False
retry_files_enabled  = False
# Ample for a few-dozen-host estate.
forks                = 20
interpreter_python   = auto_silent
```

**What each does.**

- **`host_key_checking = False`** — skip SSH host-key verification.
- **`retry_files_enabled = False`** — don't litter `.retry` files after failures.
- **`forks = 20`** — up to 20 hosts in parallel.
- **`interpreter_python = auto_silent`** — auto-discover the remote Python and **suppress the
  discovery warning**.

**Why.**

- Host-key checking is disabled because instances are **rebuilt constantly** — every
  `terraform apply -replace` gives a new host key at a recycled private IP. With checking on,
  every rebuild would produce `HOST IDENTIFICATION HAS CHANGED` and block the converge.
  **This is a deliberate security trade-off**, acceptable because all traffic stays inside a
  private VPC subnet. It would not be acceptable over the internet.
- `auto_silent` matters because the estate is genuinely mixed (Ubuntu 24.04 → `python3.12`,
  Amazon Linux 2023 → a different path). Without `_silent` every task logs a discovery
  warning, drowning real output.

### 1.3 `[defaults]` — output formatting

```ini
stdout_callback      = ansible.builtin.default
result_format        = yaml
callbacks_enabled    = ansible.posix.profile_tasks
```

**What it does.** Selects the output plugin, renders task results as YAML rather than JSON,
and enables per-task timing.

**Why — this is a bug fix.** It previously read `stdout_callback = yaml`, referring to
`community.general.yaml`. That callback was **removed** from recent `community.general`, and
its absence is a **fatal** error — every playbook run died at startup. The modern equivalent
is the built-in callback plus `result_format = yaml`.

**Dependency.** `callbacks_enabled = ansible.posix.profile_tasks` requires the `ansible.posix`
collection, which is why it appears in `requirements.yml`. If that collection is missing the
callback silently doesn't load — you lose timings but the run proceeds.

**Why timings are worth having.** `profile_tasks` produces the TASKS RECAP that revealed
`Ensure baseline packages are present (Debian family) — 226.27s`, which is how the missing
HTTP-egress rule was diagnosed. A slow task is a symptom you can't see without this.

### 1.4 `[defaults]` — fact caching and logging

```ini
fact_caching         = jsonfile
fact_caching_connection = /var/tmp/ansible_facts
fact_caching_timeout = 3600
log_path                = /var/log/ansible/ansible.log
```

**What it does.** Caches gathered facts as JSON files for 1 hour, and appends every run's
output to a persistent log.

**Why.** `converge.sh` runs **14 separate `ansible-playbook` processes**. Without caching,
each would re-gather facts from every host — 14× the SSH round-trips. The cache makes the
split-process design affordable.

**⚠️ Gotchas.**

- **`log_path`'s directory must exist and be writable by the run user.** It doesn't create it.
  When `/var/log/ansible` was missing, every run printed
  `log file at '/var/log/ansible/ansible.log' is not writeable and we cannot create it,
  aborting`. `bootstrap.yml` now creates it (§3.3).
- **`collect-debug.sh` deliberately overrides this** via `ANSIBLE_LOG_PATH` so diagnostics
  don't append to — and corrupt — the very log being collected.
- **Stale cache can mislead.** A host whose facts changed within the hour may be evaluated
  against cached values. If you see impossible behaviour, clear `/var/tmp/ansible_facts`.

### 1.5 `[inventory]`

```ini
[inventory]
enable_plugins = aws_ec2
```

**What it does.** Whitelists inventory plugins. Only listed plugins are consulted.

**Why it's load-bearing.** Without this line, `inventory/aws_ec2.yml` is **silently ignored**
— not an error, just an empty inventory.

**Historical bug worth knowing.** This line once read:

```ini
enable_plugins = aws_ec2 ; nothing else needed for AWS
```

INI parsers here do **not** strip inline `;` comments, so the value became the literal string
`aws_ec2 ; nothing else needed for AWS` — no such plugin, inventory empty. The same bug hit
`forks = 20 ; ...`, making forks a non-integer. **Never put inline comments on the same line
as a value in this file**; put them on their own line, as the current file does.

### 1.6 `[connection]` — pipelining

```ini
[connection]
# NOTE: pipelining must live under [connection] (or [defaults]); ansible-core
# 2.16+ no longer reads it from [ssh_connection].
pipelining    = True
```

**What it does.** Executes modules over the existing SSH session without writing a temporary
file to the remote host — roughly halving SSH operations per task.

**Why the section placement is called out.** It historically lived under `[ssh_connection]`.
On ansible-core 2.16+ that location is ignored — **silently**. The setting appears configured
but does nothing, and you only notice as unexplained slowness. Verify with:

```bash
ansible-config dump --only-changed | grep -i pipelining
```

**Requirement.** Pipelining needs `requiretty` **off** in the managed hosts' sudoers. That's
the default on cloud images; on a hardened image it would break `become`.

### 1.7 `[ssh_connection]` — multiplexing

```ini
[ssh_connection]
ssh_args      = -o ControlMaster=auto -o ControlPersist=60s
control_path  = /tmp/ansible-%%r@%%h:%%p
```

**What it does.** Enables SSH connection multiplexing: one TCP+auth handshake is reused for
60 s of subsequent tasks.

**⚠️ The doubled `%%` is not a typo.** `ansible.cfg` is parsed by Python's `configparser`,
where `%` is the interpolation character. A literal `%` must be escaped as `%%`. SSH itself
receives `/tmp/ansible-%r@%h:%p` (remote-user@host:port). Writing single `%` raises an
interpolation error at startup.

You can see these sockets in the wild — `collect-debug.sh`'s `systemctl status` output shows
entries like `ssh: /tmp/ansible-ec2-user@10.188.10.168:22 [mux]`, which is a useful signal
that connections are being reused.

### 1.8 `[privilege_escalation]`

```ini
[privilege_escalation]
become        = True
become_method = sudo
become_user   = root
```

**What it does.** Globally enables `sudo`-to-root for every task on every host.

**🔴 This global is what broke Windows.** WinRM has no `sudo`; the Windows exec wrapper
rejects it outright:

```
Become plugin sudo is not supported by the Windows exec wrapper.
Make sure to set the become method to runas.
```

Every Windows play failed at fact-gathering. The fix is **`ansible_become: false` in
`inventory/group_vars/os_windows.yml`** — a group-level override of this global.

**Business rule:** *`become` is on globally for Linux and explicitly disabled for the Windows
group. Windows tasks run as the connected administrator.*

**Second-order effect.** This global also applies to `localhost` plays. `bootstrap.yml` needs
root (writing to `/etc/ansible`), but two of its tasks explicitly set `become: false` — see
§3.4.

---

## 2. `requirements.yml` — collection pinning

```yaml
collections:
  - name: amazon.aws            # aws_ec2 inventory + aws_secret lookup
    version: ">=6.0.0,<11.0.0"
  - name: ansible.windows       # win_* core modules
    version: ">=2.0.0,<4.0.0"
  - name: microsoft.ad          # AD DS forest/domain promotion (windows-adds)
    version: ">=1.0.0,<2.0.0"
  ...
  - name: ansible.posix        # profile_tasks callback (task timing in output)
    version: ">=1.5.0,<3.0.0"
```

**What it does.** Declares required collections with **version ranges** capped below the next
major.

**Why ranges rather than exact pins.** Stated in the header: allow patch/minor updates, block
surprise majors. The comment also documents how to fully freeze (`ansible-galaxy collection
list` → replace ranges with exact versions).

**Why each collection is here:**

| Collection | Needed for |
|---|---|
| `amazon.aws` | `aws_ec2` inventory plugin **and** `aws_secret` lookup — the two load-bearing integrations |
| `ansible.windows` | `win_*` modules; also `win_timezone` (migrated here from `community.windows`) |
| `microsoft.ad` | forest promotion, domain join, RODC |
| `community.windows` | extended Windows modules |
| `chocolatey.chocolatey` | Windows packages |
| `community.general` | `timezone` module in the baseline role |
| `community.mysql` | `mysql_user` in the DB playbooks |
| `ansible.posix` | the `profile_tasks` callback referenced by `ansible.cfg` |

**⚠️ Gotcha — version ranges vs. ansible-core is a known trap.** The Azure sibling project hit
a subtle failure: `azure.azcollection 3.1.0` pinned against a much newer ansible-core. Core
2.19+ introduced a "trusted templates" model, and the older collection's inventory template
wasn't trusted, so `default_host_filters` failed to evaluate and **the entire inventory
returned zero hosts** — with an error that pointed nowhere near the real cause.

**Lesson:** pin the collection set to the ansible-core version you actually install. This node
runs core 2.21 from apt; if you upgrade core, re-validate these ranges.

**Related fix.** `ansible-galaxy collection install` leaves an already-installed version in
place, so changing a pin here had **no effect**. Both `reconverge.sh` and `bootstrap.yml` now
pass **`--upgrade`**.

---

## 3. `bootstrap.yml` — the control node configures itself

```yaml
- name: Bootstrap the Ansible control node
  hosts: localhost
  connection: local
  gather_facts: true
  become: true
  vars:
    ansible_key_dir: /etc/ansible/keys
    ansible_service_user: ubuntu
```

**What it does.** A single play against `localhost` using the `local` connection plugin (no
SSH — direct subprocess execution). `become: true` for the play; `ansible_service_user`
records which account the systemd timers run as.

**Why `ansible_service_user` exists as a variable.** It's referenced by three tasks below.
The ownership it sets is **not cosmetic** — see §3.5.

### 3.1 Fail fast on missing configuration

```yaml
    - name: Assert the consolidated secret name was provided
      ansible.builtin.assert:
        that:
          - ansible_secret_name | length > 0
        fail_msg: >-
          ANSIBLE_SECRET_NAME is not set. The control node's cloud-init
          (Terraform module.secrets) must inject the consolidated secret name.
```

**What it does.** Aborts the play immediately unless `ansible_secret_name` (from
`group_vars/all.yml`, sourced from the environment) is non-empty.

**Why.** Without the secret name, the SSH-key task below would fail with an opaque AWS error
(`Invalid length for parameter SecretId, value: 0`). The assert converts that into a message
that **names the responsible component** (Terraform's cloud-init).

**Gotcha — this assert fires legitimately.** Running `bootstrap.yml` by hand without sourcing
`/etc/ansible/estate.env` trips it, because that file is `0640 root:root`. That is the
expected behaviour, not a bug. Always `set -a; . /etc/ansible/estate.env; set +a` first.

### 3.2–3.3 Directory creation

```yaml
    - name: Ensure the Ansible key directory exists
      ansible.builtin.file:
        path: "{{ ansible_key_dir }}"
        state: directory
        owner: "{{ ansible_service_user }}"
        group: "{{ ansible_service_user }}"
        mode: "0700"

    - name: Ensure the Ansible log directory exists (service user can write it)
      ansible.builtin.file:
        path: /var/log/ansible
        state: directory
        owner: "{{ ansible_service_user }}"
        group: "{{ ansible_service_user }}"
        mode: "0755"
```

**What it does.** Creates both directories owned by the **service user**, not root.

**Why ownership is the whole point.**

- **Key dir `0700` owned by `ubuntu`** — the SSH client runs as `ubuntu` (systemd `User=`).
  Root-owned `0700` means `ubuntu` cannot even traverse the directory, let alone read the key.
- **Log dir owned by `ubuntu`** — `ansible.cfg`'s `log_path` points inside it and Ansible does
  not create it. Its absence produced the `not writeable ... aborting` warning on every run,
  and `notify-result.sh` failed writing `converge-status.log`.

**Business rule:** *Every path the systemd timers write to must be owned by the service user
(`ubuntu`), even though bootstrap itself runs as root.*

### 3.4 Collection installation — a chicken-and-egg fix

```yaml
    - name: Install required collections
      # Use the ansible-galaxy CLI directly so this does not depend on
      # community.general already being installed — that is one of the very
      # collections this task installs (chicken-and-egg on a bare ansible-core node).
      ansible.builtin.command:
        cmd: ansible-galaxy collection install --upgrade -r requirements.yml
        chdir: "{{ playbook_dir }}"
      register: galaxy_install
      changed_when: "'Installing' in galaxy_install.stdout or 'Downloading' in galaxy_install.stdout"
      become: false
```

**What it does.** Shells out to the `ansible-galaxy` CLI. `chdir: "{{ playbook_dir }}"` runs
it from the repo root (so `requirements.yml` resolves). `changed_when` inspects stdout to
report *changed* only when something was actually installed.

**Why not the purpose-built module?** It previously used
`community.general.ansible_galaxy_install` — but **`community.general` is one of the
collections this task installs.** On a freshly built node with bare ansible-core, the module
didn't exist, so the task that would have installed it couldn't run. Using the CLI removes the
circular dependency.

**Why `become: false`** (overriding the play's `become: true`): collections must be installed
**as the service user**, into `/opt/control-repo/collections` per `collections_path`. Running
as root would create root-owned collection files that the timers (running as `ubuntu`) may
not be able to read or refresh.

**Why `--upgrade`:** without it, `ansible-galaxy` leaves an existing version in place, so
edits to `requirements.yml` silently had no effect.

**Why the custom `changed_when`:** `command` always reports *changed*. Parsing stdout keeps
the run idempotent-looking, so a steady-state converge reports `changed=0`.

**⚠️ Gotcha.** `changed_when` matches English substrings in `ansible-galaxy` output. A future
CLI wording change silently breaks the idempotency reporting (not the install). Cosmetic, but
surprising.

### 3.5 Writing the SSH key

```yaml
    - name: Write the Ansible SSH private key from the consolidated secret
      ansible.builtin.copy:
        content: "{{ (lookup('amazon.aws.aws_secret', ansible_secret_name, region=aws_region) | from_json).ssh_private_key }}"
        dest: "{{ ansible_ssh_private_key_file }}"
        owner: "{{ ansible_service_user }}"
        group: "{{ ansible_service_user }}"
        mode: "0600"
      no_log: true
```

**This is the single most important task in the repo.** Everything on the Linux estate depends
on it.

**What it does.** Fetches the consolidated secret, parses JSON, extracts **only**
`ssh_private_key`, and writes it with owner/mode.

**Why each element:**

- **Field-scoped lookup** — consistent with the `group_vars/all.yml` policy: never bind the
  whole secret to a variable (see the inventory walkthrough §2.4).
- **`dest: "{{ ansible_ssh_private_key_file }}"`** — the **variable**, not a literal. This is
  the fix for a real outage: the write path was hardcoded `ansible_ed25519` while the read
  path in `group_vars` said `ansible_rsa`. Using the variable makes drift impossible.
- **`owner`/`group` = service user** — the fix for the second outage: root-owned key,
  `ubuntu` client, `UNREACHABLE` everywhere.
- **`mode: "0600"`** — SSH refuses group/world-readable keys.
- **`no_log: true`** — without it, `copy`'s `content` parameter (the entire private key) is
  echoed into the log on failure.

**Business rule:** *The SSH private key lives only in Secrets Manager. The control node
materialises it at bootstrap into a service-user-owned `0600` file, and never logs it.*

### 3.6 Inventory verification

```yaml
    - name: Confirm the dynamic inventory resolves
      ansible.builtin.command: ansible-inventory -i inventory/aws_ec2.yml --graph
      args:
        chdir: "{{ playbook_dir }}"
      changed_when: false
      become: false
```

**What it does.** Runs the inventory plugin and prints the group graph. `changed_when: false`
marks it read-only.

**Why.** A smoke test at the end of bootstrap: if boto3 is missing, the region is wrong, or
the IAM role lacks `ec2:Describe*`, this surfaces it **here** — during self-configuration —
rather than an hour later inside an estate converge.

**🔒 `--graph`, never `--list`.** Same rule as `collect-debug.sh`: `--list` resolves host
variables, which would execute the `aws_secret` lookups in `os_windows.yml` and print WinRM
credentials into the log.

---

## 4. `site.yml` — the baseline push

### 4.1 Pre-flight play

```yaml
- name: Pre-flight checks (control node)
  hosts: localhost
  connection: local
  gather_facts: false
  tags: [always]
  tasks:
    - name: Assert region and the consolidated secret name are configured
      ...
    - name: Assert the dynamic inventory discovered managed hosts
      ansible.builtin.assert:
        that:
          - (groups['os_linux'] | default([]) | length) + (groups['os_windows'] | default([]) | length) > 0
```

**What it does.** Two asserts before touching any managed host. `groups` is the magic dict of
inventory groups; `| default([])` guards against a group not existing at all (otherwise
referencing a missing key raises an undefined-variable error).

**Why `tags: [always]`.** Without it, `ansible-playbook site.yml --tags packages` would
**skip the safety checks**. `always` guarantees pre-flight runs under any tag selection.

**Why `gather_facts: false`.** Nothing here needs facts; skipping saves a pointless local
fact-gathering pass.

**Why these two specific asserts.** They encode the two failure modes that wasted the most
time, and their `fail_msg` strings are genuinely diagnostic — the second one names the exact
tag and its capitalisation:

> *"...the `tag:ManagedBy` value in inventory/aws_ec2.yml matches the instances (Terraform
> tags them ManagedBy=Terraform, capital T)."*

**Business rule:** *Never attempt a converge without a region, a secret name, and at least one
discovered host. Fail loudly on the control node instead of quietly doing nothing.*

**Gotcha.** The success path prints `Discovered N managed host(s)` — this is the number to
sanity-check first in any log. If it says 7 and you expect 9, the inventory filter is wrong,
not the playbooks.

### 4.2 Linux estate play

```yaml
- name: Linux estate
  hosts: os_linux
  gather_facts: true
  serial: "{{ rolling_batch | default('100%') }}"
  max_fail_percentage: "{{ max_fail_pct | default(0) }}"
  roles:
    - role: baseline
      tags: [baseline]
  tasks:
    - name: Install baseline package
      ansible.builtin.package:
        name: "{{ linux_baseline_package | default('htop') }}"
        state: present
      tags: [packages]
```

**What it does.** Applies the `baseline` role, then installs one package. `serial` controls
batch size; `max_fail_percentage` sets the abort threshold. Both are **variable-driven with
defaults**, so `converge.sh` can inject `-e rolling_batch=25%`.

**Why `serial` + `max_fail_percentage`.** Blast-radius control: with `serial: 25%`, a change
rolls out to a quarter of the fleet at a time. `max_fail_percentage: 20` aborts if more than
20% of a batch fails, rather than breaking the whole estate.

**⚠️ Gotcha — `serial` splits the play into multiple PLAY sections.** In the logs you'll see
`PLAY [Linux estate]` **repeated** — once per batch. That's expected, not a loop bug. It also
means `max_fail_percentage` is evaluated **per batch**, not across the whole play.

**Why `ansible.builtin.package`** (generic) rather than `apt`/`dnf`: this single task is
OS-agnostic, so it works on both distros. The `baseline` role, which needs distro-specific
behaviour (`allowerasing` on dnf), splits them explicitly.

### 4.3 Windows estate play

```yaml
- name: Windows estate
  hosts: os_windows
  gather_facts: true
  # A Windows host that can't be reached ... must NOT abort the converge
  ignore_unreachable: true
  serial: ...
  max_fail_percentage: ...
```

**What it does.** Same structure, plus `ignore_unreachable: true`.

**Why.** When the Windows hosts rejected WinRM (the `LocalAccountTokenFilterPolicy` saga), an
unreachable Windows host **aborted the entire run** with `NO MORE HOSTS LEFT` — taking down
the Linux role services that follow. `ignore_unreachable` contains the damage.

**🔴 Gotcha — `ignore_unreachable` keeps the host IN the play.** It does not remove it. The
host stays, and subsequent tasks still execute against it — but it has **no facts**, because
gathering failed. Any task referencing `ansible_facts` or a registered variable then throws a
*hard failure* (not an unreachable), which `ignore_unreachable` does **not** catch:

```
'ansible_os_family' is undefined
object of type 'dict' has no attribute 'stat'
```

This is why the `baseline` role guards with `ansible_facts['os_family'] is defined`, and why
the Windows playbooks open with either a `meta: end_host` facts guard or a `win_ping` probe.
**If you add a Windows playbook, it needs one of those guards.**

---

## 5. `orchestrate.yml` — the ordering contract

```yaml
# DESIGN RULES (keep these when adding playbooks):
#  1. CONVERGENCE ONLY. ...
#  2. LINUX BEFORE WINDOWS. ...
#  3. EVERY PLAY TARGETS A ROLE ∩ OS/DISTRO INTERSECTION. ...
#  4. Playbooks whose target group is empty are harmless no-ops

- import_playbook: site.yml
- import_playbook: playbooks/ubuntu-apache2.yml      # role_web  & distro_ubuntu
...
```

**What it does.** `import_playbook` is a **static** include evaluated at parse time; all
imported plays run in **one `ansible-playbook` process**.

The four design rules are the real content. Each encodes a fix:

**Rule 1 — convergence only.** `ubuntu-setup.yml` / `amazonlinux-setup.yml` do
`apt upgrade dist` / `dnf "*" latest` **plus a conditional reboot**. They used to sit at
positions 2–3, *ahead of* Apache/MySQL. They are slow, they reboot hosts unattended, and any
failure aborted everything downstream — which is why "web and database never got built."
Now excluded and run manually in a maintenance window.

> **Business rule:** *The hourly converge must be fast, idempotent, and must never reboot a
> host. Full OS upgrades are maintenance, not convergence.*

**Rule 2 — Linux before Windows.** The Linux chain has no AD dependency, so a WinRM problem
must not block it. This ordering is why the Linux estate kept converging throughout the
Windows credential saga.

**Rule 3 — role ∩ OS intersections.** Covered in the inventory walkthrough. The inline
comments (`# role_web & distro_ubuntu`) document each target so a reviewer can spot a bare
role group.

**Rule 4 — empty groups are no-ops.** `skipping: no hosts matched` in the log is expected for
roles not present in a given estate, not an error.

**⚠️ Status — read this carefully.** The systemd timer **no longer runs this file**; it runs
`converge.sh`. `orchestrate.yml` remains valid for a manual, fail-fast run. But the two files
duplicate the same ordering. See [Flagged issue #1](#flagged-issues).

---

## 6. `local.yml` — an `ansible-pull` shim

```yaml
# local.yml exists only so an accidental `ansible-pull` does not fail with
# "Could not find or access 'local.yml'"; it just self-converges the control node.
- import_playbook: bootstrap.yml
```

**What it does.** One line delegating to `bootstrap.yml`.

**Why it exists.** `ansible-pull` looks for `local.yml` by default. This repo is **push**-based
— `ansible-pull` could only ever self-configure the control node, never reach the estate. The
file makes an accidental `ansible-pull` do something harmless and comprehensible instead of
erroring.

**Status: defensive dead code.** Nothing in this repo invokes `ansible-pull`. It is retained
deliberately, and the comment explains why. **Do not treat its existence as evidence that
pull mode is supported — it isn't.**

---

## 7. `scripts/converge.sh` — the runner

### 7.1 Why it exists

```bash
# WHY THIS EXISTS (instead of pointing systemd straight at orchestrate.yml):
# orchestrate.yml chains playbooks with import_playbook, so they share ONE
# ansible-playbook process. If any play ends with all its hosts failed, Ansible
# prints "NO MORE HOSTS LEFT" and aborts the whole run — every later playbook is
# skipped.
```

**The problem.** `import_playbook` produces a single process. Ansible's failure semantics
then abort the *entire run* when a play loses all its hosts. One broken role — or unreachable
Windows — silently skipped everything after it.

**Practical consequence during debugging:** each run surfaced exactly **one** problem. Fix it,
re-run, discover the next. `converge.sh` ended that cycle by revealing all failures per run.

**Business rule:** *A failure in one playbook must not prevent the others from converging. The
run still reports failure, but only after every playbook has had its chance.*

### 7.2 Environment loading

```bash
ENV_FILE="${ANSIBLE_ESTATE_ENV:-/etc/ansible/estate.env}"
if [ -r "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi
```

**What it does.** Sources the Terraform-injected env file **if readable**.

**⚠️ `[ -r ]` (readable), not `[ -f ]` (exists) — this is a scar.** `estate.env` is
`0640 root:root`; the service user is `ubuntu`. With `[ -f ]`, the test **passed** and the
`source` then failed *Permission denied* — and under `set -e` that killed the script **before
it ran bootstrap**, so the SSH key was never written and every Linux host went `UNREACHABLE`.

Under systemd this file is redundant anyway (the unit's `EnvironmentFile=` injects the same
variables as root); the source is for **manual** runs. Testing readability makes both paths
work.

> Note `collect-debug.sh` still uses `[ -f ]` for the same file — safe there only because it
> has no `set -e`, but inconsistent. Flagged in that walkthrough.

### 7.3 Working directory and blast-radius defaults

```bash
REPO_DIR="${CONTROL_REPO_DIR:-/opt/control-repo}"
cd "$REPO_DIR" || { echo "FATAL: cannot cd to $REPO_DIR"; exit 1; }

ROLLING_BATCH="${ROLLING_BATCH:-25%}"
MAX_FAIL_PCT="${MAX_FAIL_PCT:-20}"
```

**What it does.** Changes to the repo root (**mandatory** — §1.1) and sets overridable
defaults. The `cd` failure is one of the few genuinely fatal conditions.

**Dependency.** The systemd unit also sets these via `Environment=ROLLING_BATCH=25%`, so the
values are declared in two places — unit and script default. Harmless, but be aware.

### 7.4 Playbook lists and selection

```bash
LINUX_PLAYS=( site.yml playbooks/ubuntu-apache2.yml ... )
WINDOWS_PLAYS=( playbooks/windows-adds.yml ... )

case "${1:-}" in
  --linux)   PLAYS=("${LINUX_PLAYS[@]}") ;;
  --windows) PLAYS=("${WINDOWS_PLAYS[@]}") ;;
  *)         PLAYS=("${LINUX_PLAYS[@]}" "${WINDOWS_PLAYS[@]}") ;;
esac
```

**What it does.** Bash arrays. `"${ARR[@]}"` expands to elements **as separate words** (quoted
correctly for paths with spaces). `${1:-}` safely reads `$1` even when unset.

**Why the split.** `--linux` / `--windows` let an operator converge one estate half — valuable
when Windows is broken and you only want to verify Linux.

**🔴 This list duplicates `orchestrate.yml`.** Same ordering, two files, no enforcement.
See [Flagged issue #1](#flagged-issues).

### 7.5 The execution loop

```bash
for play in "${PLAYS[@]}"; do
  [ -f "$play" ] || { echo "SKIP (missing): $play"; continue; }
  ...
  if ansible-playbook "$play" -e "rolling_batch=${ROLLING_BATCH}" -e "max_fail_pct=${MAX_FAIL_PCT}"; then
    PASSED+=("$play")
  else
    rc=$?
    echo "!!! FAILED (exit ${rc}): $play — continuing with the remaining playbooks"
    FAILED+=("$play")
  fi
done
```

**What it does.** Each playbook is its **own process**. `if cmd; then ... else ... fi` branches
on exit status. `ARR+=(x)` appends. The missing-file guard makes a partially-updated repo
degrade rather than crash.

**Why this is the whole point.** A failure is *recorded and reported*, then the loop
continues. Process isolation means Ansible's "abort the run" semantics can't propagate past
one playbook.

**⚠️ Gotcha — `rc=$?` placement.** It must be the **first** statement in the `else` branch;
any command before it overwrites `$?`. Currently correct.

**Gotcha — cost.** 14 processes means 14 inventory parses (14 EC2 API calls) and 14 fact
passes. Fact caching (§1.4) is what makes this acceptable. Runtime is ~1.5 min CPU for the
full estate.

### 7.6 Summary and exit status

```bash
echo "================= CONVERGE SUMMARY ================="
printf 'passed : %s\n' "${#PASSED[@]}"
for p in "${PASSED[@]}"; do printf '   ok   %s\n' "$p"; done
printf 'failed : %s\n' "${#FAILED[@]}"
for p in "${FAILED[@]}"; do printf '   FAIL %s\n' "$p"; done
echo "==================================================="

[ "${#FAILED[@]}" -eq 0 ] || exit 1
exit 0
```

**What it does.** `${#ARR[@]}` is array length. Exit 1 if anything failed, else 0.

**Why the exit status still matters.** systemd marks the unit failed, and `notify-result.sh`
(the unit's `ExecStopPost`) writes `converge-status.log` / `converge-failures.log` and can
raise an SNS alert. **Resilience must not mean silent success.**

**This block is the highest-signal output in the system.** `grep -A26 'CONVERGE SUMMARY'` on
the journal tells you the state of the entire estate in one screen — e.g.
`passed : 14 / failed : 1 → FAIL playbooks/windows-rodc.yml`.

---

## Operational quick reference

```bash
cd /opt/control-repo                      # ALWAYS — ansible.cfg is cwd-relative
set -a; . /etc/ansible/estate.env; set +a # ALWAYS for manual runs

ansible-playbook site.yml --check --diff  # dry run, whole estate
bash scripts/converge.sh --linux          # Linux half only
bash scripts/converge.sh                  # full converge (what the timer runs)
ansible-playbook orchestrate.yml          # manual, fail-fast equivalent

sudo journalctl -u ansible-estate.service -n 40 --no-pager | sed -n '/CONVERGE SUMMARY/,$p'
tail -5 /var/log/ansible/converge-status.log
```

---

## Glossary additions

| Term | Meaning |
|---|---|
| **`import_playbook`** | Static, parse-time include. All plays share **one** process — hence the cascade-abort problem. |
| **`serial`** | Batch size per play. Splits one play into repeated PLAY sections in the log. |
| **`max_fail_percentage`** | Abort threshold, evaluated **per batch**, not per play. |
| **`ignore_unreachable`** | Unreachable host doesn't abort the play — but **stays in it, factless**. |
| **`tags: [always]`** | Tasks that run regardless of `--tags` selection. Used for pre-flight. |
| **`changed_when`** | Overrides a task's changed status; needed for `command`, which always reports changed. |
| **Pre-flight** | The `localhost` play at the top of `site.yml` asserting config and inventory health. |
| **Runner** | `converge.sh` — one process per playbook, contained failures, summary report. |
| **Blast radius** | How much of the estate a single bad change can affect; controlled by `serial` + `max_fail_percentage`. |

---

## Flagged issues

1. **🔴 `orchestrate.yml` and `converge.sh` duplicate the same playbook ordering** with no
   mechanism keeping them in sync. Add a playbook to one and forget the other, and the manual
   and automated paths silently diverge — the automated path is the one that matters.
   **Recommend** either generating the shell list from `orchestrate.yml`, or reducing
   `orchestrate.yml` to a documentation-only file that explicitly states `converge.sh` is
   authoritative. As it stands, `orchestrate.yml`'s excellent DESIGN RULES comment block is
   the more valuable half of the file.

2. **`local.yml` is dead code**, deliberately retained as an `ansible-pull` guard. Nothing
   invokes it. Correctly documented in-file; noted here so nobody assumes pull mode works.

3. **Stale comment reference.** `bootstrap.yml`'s header cites *"the systemd timer from
   Document 1"* — a design document not present in this repo. New hires can't follow it.
   (Same issue as `aws_ec2.yml` / `os_windows.yml`.)

4. **`changed_when` string-matching** in the galaxy task depends on `ansible-galaxy`'s English
   output (`'Installing'` / `'Downloading'`). A CLI wording change silently breaks the changed
   reporting. Cosmetic, but confusing.

5. **`host_key_checking = False`** is a deliberate security trade-off for constantly-rebuilt
   instances inside a private VPC. Correct here; **would not be acceptable** if the estate
   were ever reachable over the internet. Re-evaluate if the topology changes.

6. **`ROLLING_BATCH` / `MAX_FAIL_PCT` are declared twice** — as `Environment=` in
   `ansible-estate.service` and as defaults in `converge.sh`. Harmless (unit wins), but two
   places to look when tuning.

7. **Fact-cache staleness** (1 h TTL) can produce confusing results right after an OS change
   on a managed host. If behaviour looks impossible, clear `/var/tmp/ansible_facts`.
