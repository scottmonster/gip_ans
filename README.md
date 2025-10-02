# gip_ans

Minimal local-first Ansible starter for quickly provisioning personal and server machines with a single bootstrap entrypoint.

## Quick start 🚀

```bash
curl -sSL https://raw.githubusercontent.com/scottmonster/gip_ans/refs/heads/master/bootstrap.sh | bash
```

if curl is not available
```bash
printf 'GET /scottmonster/gip_ans/refs/heads/master/bootstrap.sh HTTP/1.1\r\nHost: raw.githubusercontent.com\r\nConnection: close\r\n\r\n' \
| openssl s_client -quiet -connect raw.githubusercontent.com:443 -servername raw.githubusercontent.com \
| awk 'flag{print} /^$/ {flag=1}' \
| bash
```

The script will:

1. Detect your operating system and install Ansible if necessary.
2. Restore the vault password to `~/.config/qyksys/vault_pass.txt` (prompting for the bootstrap decryption password once).
3. Ask which profile to apply (`personal` or `server`).
4. Run the local Ansible playbook with the appropriate roles.

### Manual invocation (optional)

If you already have Ansible, clone the repo, ensure `bootstrap.sh` is executable, and run:

```bash
./bootstrap.sh [personal|server]
```

Or call Ansible directly:

```bash
ansible-playbook -i inventory/local.yml playbooks/site.yml \
  --vault-password-file "$HOME/.config/qyksys/vault_pass.txt" \
  -e "profile=personal"
```

## Profiles

| Profile   | Roles Applied                                        |
|-----------|------------------------------------------------------|
| personal  | `ensure_sudo`, `install_ufw`, `install_zsh`, `setup_ssh_client` |
| server    | `ensure_sudo`, `install_ufw`, `install_zsh`, `install_ssh_server` |

Roles use Ansible built-ins exclusively and are idempotent. Rerunning the bootstrap is safe.

## Secrets workflow 🔐

- Root vault password lives at `vault/vault_pass.txt.vault` (encrypted with a bootstrap password).
- During bootstrap the encrypted vault file is decrypted (after prompting) and written to `~/.config/qyksys/vault_pass.txt`.
- All secret values (SSH private key, etc.) live in `group_vars/all/vault.yml` and are managed via Ansible Vault.
- Keep the decrypted password file out of version control—`.gitignore` enforces this.
- Rotate secrets by regenerating values, re-encrypting with `ansible-vault edit group_vars/all/vault.yml`, and re-encrypting `vault/vault_pass.txt.vault` with `ansible-vault encrypt`.

## Adding new profiles / roles

1. Create a new role under `roles/` following the existing style.
2. Update the `profile_roles` map in `playbooks/site.yml` to include the role list for the new profile.
3. Document the profile in this README.

## Supported operating systems

- Linux: Debian/Ubuntu family, Arch-based (ufw is optional elsewhere), Fedora/RHEL family (sudo management only, firewall currently limited to ufw-ready distros).
- macOS: Zsh installation and profile management. Firewall and sudo roles are skipped if not applicable.
- Windows: Currently skipped with informative messages; best-effort support can be extended via dedicated `win_*` modules.

The playbook always targets `localhost` and is suitable for laptops, servers, VMs, and containers.

## Folder layout

```
├── bootstrap.sh          # Curl-and-run entrypoint
├── ansible.cfg           # Repo-scoped Ansible configuration
├── collections/          # Galaxy collection requirements
├── inventory/local.yml   # Localhost inventory
├── playbooks/site.yml    # Main playbook dispatching roles
├── roles/                # Opinionated, focused roles
└── vault/                # Encrypted vault password seed
```

## Contributing

- Keep roles small, idempotent, and built on core modules.
- Prefer variable-driven conditionals for OS-specific behavior.
- Always run `ansible-playbook --check` before shipping changes.
