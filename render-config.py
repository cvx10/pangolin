#!/usr/bin/env python3
"""Render config/config.yml from config/config.yml.tmpl and .env.

Runs on the VPS before `docker compose up` (deploy.yml), or by hand.

- Reads .env without a shell: values may contain spaces (the Gmail app
  password does), which `source .env` would split.
- Every ${VAR} is substituted as a YAML double-quoted scalar, so no value can
  break the YAML. A missing variable is an error, never an empty string.
- Writes config.yml (0600) only when the parsed content changes, and exits 10
  in that case so the caller knows `pangolin` must be restarted to pick it up
  (the file is read at start only).

Usage: render-config.py [--check]   --check: compare only, never write.
"""
import json
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(ROOT, "config", "config.yml.tmpl")
TARGET = os.path.join(ROOT, "config", "config.yml")
ENV = os.path.join(ROOT, ".env")


def read_env(path):
    env = {}
    for raw in open(path):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value
    return env


def render(template, env):
    missing = sorted({m for m in re.findall(r"\$\{([A-Z0-9_]+)\}", template) if m not in env})
    if missing:
        sys.exit("render-config: missing in .env: " + ", ".join(missing))
    # json.dumps produces a valid YAML double-quoted scalar (YAML ⊃ JSON).
    return re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: json.dumps(env[m.group(1)]), template)


def main():
    check_only = "--check" in sys.argv[1:]
    rendered = render(open(TEMPLATE).read(), read_env(ENV))
    new = yaml.safe_load(rendered)
    old = yaml.safe_load(open(TARGET)) if os.path.exists(TARGET) else None
    if new == old:
        print("render-config: config.yml up to date")
        return 0
    changed = sorted(k for k in set(new) | set(old or {}) if (old or {}).get(k) != new.get(k))
    print("render-config: config.yml differs in top-level sections: " + ", ".join(changed))
    if check_only:
        return 1
    tmp = TARGET + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(rendered)
    os.replace(tmp, TARGET)
    print("render-config: config.yml written — restart pangolin to apply")
    return 10


if __name__ == "__main__":
    sys.exit(main())
