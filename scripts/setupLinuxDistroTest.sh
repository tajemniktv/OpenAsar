#!/usr/bin/env bash
set -euo pipefail

channel="${1:?usage: setupLinuxDistroTest.sh <channel> <client-dir>}"
client_dir="${2:?usage: setupLinuxDistroTest.sh <channel> <client-dir>}"
manifest_file="discord-${channel}-manifest.json"
host_archive="discord-${channel}.tar.br"

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends brotli

manifest_url="https://updates.discord.com/distributions/app/manifests/latest?channel=${channel}&platform=linux&arch=x64"
curl -fsSL "$manifest_url" -o "$manifest_file"

host_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["full"]["url"])' "$manifest_file")"
host_sha256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["full"]["package_sha256"])' "$manifest_file")"

curl -fL "$host_url" -o "$host_archive"
printf '%s  %s\n' "$host_sha256" "$host_archive" | sha256sum -c -

mkdir -p "$client_dir"
brotli -cd "$host_archive" | tar xf - -C "$client_dir" --strip-components 1

python3 - "$manifest_file" <<'PY' > discord-modules.tsv
import json
import re
import sys

with open(sys.argv[1], encoding='utf-8') as manifest_file:
    manifest = json.load(manifest_file)

modules = manifest.get('modules')
if not isinstance(modules, dict) or not modules:
    raise RuntimeError('manifest does not contain any modules')

safe_module_name = re.compile(r'^[A-Za-z0-9_.-]+$')
for name, module in sorted(modules.items()):
    if not safe_module_name.fullmatch(name):
        raise RuntimeError(f'unsafe module name in manifest: {name!r}')

    full = module.get('full')
    if not full:
        raise RuntimeError(f'module {name} is missing a full package')

    print(name, full['url'], full['package_sha256'], sep='\t')
PY

modules_root="$(realpath -m "$client_dir/modules")"
mkdir -p "$modules_root"
while IFS=$'\t' read -r module module_url module_sha256; do
    module_archive="discord-${channel}-${module}.tar.br"
    module_dir="$(realpath -m "$modules_root/$module")"

    case "$module_dir" in
        "$modules_root"/*) ;;
        *)
            echo "Refusing unsafe module path: $module_dir" >&2
            exit 1
            ;;
    esac

    curl -fL "$module_url" -o "$module_archive"
    printf '%s  %s\n' "$module_sha256" "$module_archive" | sha256sum -c -

    mkdir -p "$module_dir"
    brotli -cd "$module_archive" | tar xf - -C "$module_dir" --strip-components 1
    rm -f "$module_archive"
done < discord-modules.tsv

local_modules_root="$(realpath "$modules_root")"
python3 - "$client_dir/resources/build_info.json" "$local_modules_root" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as build_info_file:
    build_info = json.load(build_info_file)

build_info['newUpdater'] = False
build_info['localModulesRoot'] = sys.argv[2]

with open(path, 'w', encoding='utf-8') as build_info_file:
    json.dump(build_info, build_info_file)
PY

rm -f "$manifest_file" "$host_archive" discord-modules.tsv
