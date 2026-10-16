#!/usr/bin/env bash
# Runs only in the disposable upgrade build, never in the published image.
set -euo pipefail
source /etc/os-release
case "${ID}:${VERSION_CODENAME}" in
  debian:bookworm|debian:trixie) ;;
  *) echo 'Full upgrades support Debian Bookworm and Trixie images only.' >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive
# Bring Bookworm up to date before changing suites. Retain third-party sources;
# incompatible repositories fail the build without changing the active image.
apt-get update
apt-get -y upgrade
apt-mark showmanual > /opt/agent-sandbox-upgrade/manual-packages
if [[ $VERSION_CODENAME == bookworm ]]; then
  # Replace only official Debian sources, including older sources.list layouts.
  python3 - <<'PY'
from pathlib import Path
import re
paths = [Path('/etc/apt/sources.list'), *Path('/etc/apt/sources.list.d').glob('*.list'),
         *Path('/etc/apt/sources.list.d').glob('*.sources')]
for path in paths:
    if not path.exists():
        continue
    text = path.read_text()
    if path.suffix == '.sources':
        blocks = re.split(r'\n\s*\n', text)
        blocks = [b for b in blocks if not re.search(r'https?://(?:deb|security)\.debian\.org/', b)]
        path.write_text('\n\n'.join(blocks) + '\n')
    else:
        path.write_text(''.join(line for line in text.splitlines(keepends=True)
                                if not re.search(r'https?://(?:deb|security)\.debian\.org/', line)))
PY
fi
# The signed target image supplies archive keys for the new Debian suite.
cp /opt/agent-sandbox-upgrade/keyrings/* /usr/share/keyrings/
cp /opt/agent-sandbox-upgrade/debian.sources /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold upgrade --without-new-pkgs
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
apt-get install -y --no-install-recommends bash ca-certificates curl git openssh-client \
  ripgrep procps python3 python3-venv build-essential
while IFS= read -r package; do
  [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) == installed ]] || {
    printf 'Upgrade removed manually installed package %s; keeping the old image.\n' "$package" >&2
    exit 1
  }
done < /opt/agent-sandbox-upgrade/manual-packages
# Replace complete runtime directories so obsolete files cannot survive a merge.
rm -rf /usr/local/go /usr/local/lib/node_modules/npm
mv /opt/agent-sandbox-upgrade/go /usr/local/go
mv /opt/agent-sandbox-upgrade/npm /usr/local/lib/node_modules/npm
ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm
ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
export HOME=/root NPM_CONFIG_PREFIX=/usr/local
allowed_scripts=$(npm config get allow-scripts)
case "$allowed_scripts" in null|undefined) allowed_scripts= ;; esac
allowed_scripts="${allowed_scripts:+$allowed_scripts,}@anthropic-ai/claude-code"
npm update --global --allow-scripts="$allowed_scripts"
npm install --global --allow-scripts="$allowed_scripts" @openai/codex@latest @anthropic-ai/claude-code@latest
# Rebuild native npm dependencies for the new Node ABI.
npm rebuild --global --strict-allow-scripts --allow-scripts="$allowed_scripts"
{ codex --version; claude --version; } > /opt/agent-versions.txt
npm cache clean --force
rm -rf /var/lib/apt/lists/* /opt/agent-sandbox-upgrade
