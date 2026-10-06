# CLAUDE.md

`README.md` is the source of truth for this repo — read it first. This file holds Claude's working notes: conventions, gotchas, and things to remember while making changes. Don't duplicate README content here.

## Keeping docs current

- When a change alters behavior, usage, inventory groups, or playbooks, update `README.md` in the same change.
- Add notes here only for things that help with editing the repo but don't belong in user-facing docs.

## Working notes

- Validate changes with `--syntax-check` and `ansible-inventory --graph`; there's no lint or test tooling, and playbooks can't be run against real hosts from here (the control key only works from the nelson-nuc container).
- Plays set `become: true` themselves — don't add `ansible_become` to the inventory.
- Don't list `quarks.lan` alongside `quark-vm.lan`; they're the same host.
- Never add nelson-nuc to `[komodo_periphery]`.
- `ansible_python_interpreter` must be a plain path (`/usr/bin/python3`), not `/usr/bin/env python3`: current ansible-core treats the whole value as one executable name.
- Template `src:` paths are relative to the playbook dir (`../templates/...`).
- In `/etc/cron.d` files, quote env values (`VAR="{{ var }}"`). Debian bullseye's cron (3.0pl1-137, still on the Pi) doesn't take `VAR=` with an empty value as an env line. It then tries to parse it as a job, and silently ignores the **whole file**: no log line, no error. Ubuntu 26.04's cron accepts it, so it only breaks on the Pi (`pihole-backup` never ran on 2026-10-06).
