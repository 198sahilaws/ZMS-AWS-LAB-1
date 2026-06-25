# Ansible Control-Repo — ZMS AWS Lab

Push-based Ansible configuration for the AWS estate built by the Terraform stack in
`../` (Document 1). This is a **self-contained control-repo** intended to live in its
own Git repository — the one the control node pulls via `control_repo_url`. It's kept
here for convenience; push it to its own remote and point `control_repo_url` at it.

It is reconciled to the actual deployment:

- **Region** is not hardcoded — resolved from the control node's region / `AWS_REGION`
  (injected by Terraform).
- **Inventory filter** is `tag:ManagedBy = Terraform` (capital T, set by the naming module).
- **Linux users** are split by `Role`: `role_amazon` → `ec2-user`, `role_ubuntu` → `ubuntu`.
- **Windows** uses WinRM/5986 (ntlm) with `cert_validation: ignore` (self-signed listener).
- **No bastion `ProxyCommand`** — the control node is in the management subnet with direct
  private routing to managed hosts.

## Secrets — build-time injection (option D)

Terraform creates the Secrets Manager containers **before** the control node and injects
their names/ARNs + region into the node's `user-data`. `cloud-init` writes:

- `/etc/ansible/secrets.env` — `AWS_REGION`, `ANSIBLE_SSH_SECRET_NAME`/`_ARN`,
  `ANSIBLE_WINRM_SECRET_NAME`/`_ARN` (shell-sourceable).
- `/etc/ansible/secret_vars.yml` — the same as Ansible vars (`ansible_ssh_secret_name`, …).

Playbooks load `/etc/ansible/secret_vars.yml` via `vars_files`, so there are **no
hardcoded secret IDs and no `ListSecrets`** — the control role keeps its tight
`GetSecretValue`-on-two-ARNs scope. `bootstrap.yml` fetches the SSH private key from
Secrets Manager to `/etc/ansible/keys/ansible.pem`; `group_vars/os_windows.yml` resolves
the WinRM credential at run time with the `amazon.aws.aws_secret` lookup.

## Layout

```
control-repo/
├── ansible.cfg              # inventory, ssh/pipelining, fact cache, privilege escalation
├── requirements.yml         # collections
├── inventory/aws_ec2.yml    # dynamic inventory (groups by OS / Role / Environment)
├── group_vars/
│   ├── all.yml              # secret-id fallbacks, ssh key path, internal repo base
│   ├── os_linux.yml         # ssh connection + become
│   ├── role_amazon.yml      # ansible_user = ec2-user
│   ├── role_ubuntu.yml      # ansible_user = ubuntu
│   └── os_windows.yml       # winrm + WinRM credential lookup
├── host_vars/               # rare per-host overrides
├── roles/                   # your roles
├── bootstrap.yml            # node self-config (fetch key, install collections)
├── local.yml                # ansible-pull entry point -> bootstrap.yml
└── site.yml                 # the estate push playbook (Linux + Windows examples)
```

## First run (on the control node)

```bash
cd /srv/repos/control-repo            # or wherever ansible-pull checked it out
ansible-galaxy collection install -r requirements.yml -p collections

# Self-configure (fetch SSH key, install collections):
ansible-playbook local.yml

# Verify discovery + connectivity:
ansible-inventory --graph             # expect os_linux / os_windows populated
ansible os_linux   -m ping
ansible os_windows -m ansible.windows.win_ping

# Dry run, then converge the estate:
ansible-playbook site.yml --check --diff
ansible-playbook site.yml

# Scope by tag-derived group:
ansible-playbook site.yml --limit 'os_linux:&env_zms'
```

## Pre-flight checklist

- [ ] `ansible-galaxy collection install -r requirements.yml -p collections` succeeds.
- [ ] `/etc/ansible/secret_vars.yml` exists (written by Terraform user-data).
- [ ] WinRM secret value has been set out of band (`aws secretsmanager put-secret-value …`).
- [ ] `ansible-inventory --graph` shows `os_linux` / `os_windows` populated.
- [ ] `ansible os_linux -m ping` returns `pong`; `ansible os_windows -m ansible.windows.win_ping` returns `pong`.
- [ ] `ansible-playbook site.yml --check` is clean before the first enforce run.

## Notes

- `internal_repo_base` defaults to `http://repo.alcor.co.in` (the control node's private
  DNS alias). Adjust in `group_vars/all.yml` if your private zone differs.
- Requires `awscli`/boto3 on the control node for the Secrets Manager lookups; install it
  in `bootstrap.yml` (or the Terraform cloud-init) if not already present.
- For hardened Windows hosts under WDAC/AppLocker (Constrained Language Mode), prefer
  signed `win_package`/`win_chocolatey` installs over large inline PowerShell.
