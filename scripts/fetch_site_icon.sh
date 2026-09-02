#!/bin/bash

# Fetch a site's icon for the Omachron panel the same way
# omarchy-webapp-install fetches web-app icons: prefer the page's own
# apple-touch-icon link (typically 180px+), then the well-known
# /apple-touch-icon.png path, then Google's favicon service as a last
# resort. The download must be a real image; the write is atomic so the
# panel never reads a half-written file.
#
# Both the domain (derived from browser window titles) and any icon URL
# found in the page are attacker-influenced, so every fetch is hardened
# against SSRF and resource exhaustion: HTTPS only, redirects followed
# manually with each hop's hostname resolved and required to be public,
# DNS pinned with --resolve so the checked addresses are the ones curl
# connects to, a hard byte ceiling on every download, and the result
# accepted only as a known bitmap type whose declared dimensions fit a
# decode ceiling. All filesystem state — the cache-directory chain, this
# run's private scratch directory, stale-scratch cleanup, and the final
# atomic publish — is handled by fs_guard.py through held no-follow
# directory descriptors, so no pathname is re-resolved between a check and
# the action it guards.
#
# Usage: fetch_site_icon.sh <domain>
# The icon is published as <domain>.png in the plugin's icons cache.
# Exits non-zero when no usable image could be fetched.

set -u

domain="${1:-}"
[[ -n $domain ]] || exit 1

# Accept only a plain dotted hostname: no ports, no userinfo, no IP
# literals (a bare IPv4 address has no letters; IPv6 needs colons).
# fs_guard.py enforces the same shape again at publish time; a drift test
# pins the two regexes to each other.
[[ $domain =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62})?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62})?)+$ ]] || exit 1
[[ $domain == *[A-Za-z]* ]] || exit 1

max_bytes=2097152 # 2 MiB ceiling per download
max_dim=2048      # decoded-dimension ceiling per side
site_url="https://$domain/"
# The helper is invoked again after cd'ing into the scratch dir (and from
# / in the traps), so its path must be absolute regardless of how this
# script was launched.
script_dir="${BASH_SOURCE[0]%/*}"
[[ $script_dir == "${BASH_SOURCE[0]}" ]] && script_dir=.
[[ $script_dir == /* ]] || script_dir="$PWD/$script_dir"
guard="$script_dir/fs_guard.py"
command -v python3 >/dev/null 2>&1 || exit 1

# Scratch space comes from fs_guard icon-scratch: a fresh 0700 directory
# with an unguessable 96-bit random name, created relative to a verified
# no-follow descriptor chain and recorded in a creation journal. The same
# call sweeps stale scratch dirs — but only names the journal lists, never
# a directory that merely matches a name/uid/mode/age signature, and never
# recursively. We cd into the scratch dir once and write only relative
# paths, so the process cwd holds the inode for the run: a swapped parent
# component cannot redirect where curl writes, and publication re-verifies
# every link of the chain descriptor-relative before the atomic rename.
# The HUP/INT/TERM traps convert fatal signals into a normal exit so the
# EXIT trap actually runs when the caller's deadline delivers SIGTERM;
# only SIGKILL can leak a scratch dir, and the journal sweep reclaims it.
umask 077
tmpdir=$(python3 "$guard" icon-scratch) || exit 1
base=${tmpdir##*/}
trap 'cd /; python3 "$guard" icon-discard "$base"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cd -- "$tmpdir" || exit 1
tmp="./icon"
page_tmp="./page"

ipv4_private() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  ((a == 0 || a == 10 || a == 127)) && return 0
  ((a == 100 && b >= 64 && b <= 127)) && return 0
  ((a == 169 && b == 254)) && return 0
  ((a == 172 && b >= 16 && b <= 31)) && return 0
  ((a == 192 && (b == 0 || b == 168))) && return 0
  ((a == 198 && (b == 18 || b == 19))) && return 0
  ((a >= 224)) && return 0
  return 1
}

ipv6_private() {
  case $1 in
  ::1 | ::) return 0 ;;
  fe[89ab]?:*) return 0 ;; # fe80::/10 link-local
  f[cd]??:*) return 0 ;;   # fc00::/7 unique-local
  ::ffff:*) return 0 ;;    # v4-mapped: never legitimate for a public AAAA
  esac
  return 1
}

# Resolve a hostname and print its addresses comma-joined, failing unless
# every address is public. All-or-nothing so a name that mixes public and
# private answers (a rebinding staple) is rejected outright. getent has no
# deadline of its own — only the resolver's retry schedule — so it gets a
# hard one here; curl's is --max-time.
public_addrs() {
  local addrs ip
  addrs=$(timeout 5 getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  [[ -n $addrs ]] || return 1
  while IFS= read -r ip; do
    if [[ $ip == *:* ]]; then
      ipv6_private "$ip" && return 1
    else
      ipv4_private "$ip" && return 1
    fi
  done <<<"$addrs"
  paste -sd, <<<"$addrs"
}

# Download a URL, following at most 5 redirects by hand so every hop gets
# the same checks as the first: HTTPS on port 443, plain hostname, all
# resolved addresses public. --max-filesize aborts oversized transfers
# (mid-transfer too on curl >= 8.4); the stat re-check covers older curl.
safe_download() {
  local url=$1 out=$2 hop host addrs redirect
  for hop in 1 2 3 4 5; do
    [[ $url == https://* ]] || return 1
    host=${url#https://}
    host=${host%%[/?#]*}
    [[ $host == *[@:]* ]] && return 1
    [[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $host == *[A-Za-z]* ]] || return 1
    addrs=$(public_addrs "$host") || return 1
    redirect=$(curl -fsS --max-time 10 --max-filesize "$max_bytes" \
      --proto '=https' --resolve "$host:443:$addrs" \
      -o "$out" -w '%{redirect_url}' "$url" 2>/dev/null) || return 1
    [[ -z $redirect ]] && break
    url=$redirect
  done
  [[ -z $redirect ]] || return 1 # still redirecting after the hop limit
  [[ $(stat -c%s "$out" 2>/dev/null || echo 0) -le $max_bytes ]]
}

# The byte ceiling alone does not bound decoding: a 2 MiB PNG can declare
# gigapixel dimensions, and image/* also admits SVG, which is a document
# format rather than a bitmap. Accept only common bitmap types, and require
# every dimension pair `file` reports (PNG "180 x 180", JPEG "1024x768",
# each frame of a multi-icon ICO) to fit the ceiling. No reported
# dimensions reads as "cannot verify" and fails closed.
image_ok() {
  local mime dims pair w h
  mime=$(file -b --mime-type "$1")
  case $mime in
  image/png | image/jpeg | image/gif | image/webp | image/x-icon | image/vnd.microsoft.icon) ;;
  *) return 1 ;;
  esac
  dims=$(file -b "$1" | grep -oE '[0-9]+ ?x ?[0-9]+')
  [[ -n $dims ]] || return 1
  while IFS= read -r pair; do
    w=${pair%%x*}
    h=${pair##*x}
    w=${w// /}
    h=${h// /}
    ((w >= 1 && h >= 1 && w <= max_dim && h <= max_dim)) || return 1
  done <<<"$dims"
}

download_icon() {
  safe_download "$1" "$tmp" && [[ -s $tmp ]] && image_ok "$tmp"
}

fetch_site_icon() {
  local origin="https://$domain"
  local page="" icon_url
  if safe_download "$site_url" "$page_tmp"; then
    page=$(head -c 100000 "$page_tmp" | tr '\n' ' ')
  fi
  icon_url=$(grep -oiE "<link[^>]*rel=[\"'][^\"']*apple-touch-icon[^\"']*[\"'][^>]*>" <<<"$page" |
    grep -oiE "href=[\"'][^\"']+" | head -1 | sed -E "s/^href=[\"']//")

  case $icon_url in
  http://* | https://*) ;; # absolute; safe_download re-validates the host
  //*) icon_url="https:$icon_url" ;;
  /*) icon_url="$origin$icon_url" ;;
  ?*) icon_url="$origin/$icon_url" ;;
  esac

  { [[ -n $icon_url ]] && download_icon "$icon_url"; } ||
    download_icon "$origin/apple-touch-icon.png" ||
    download_icon "https://www.google.com/s2/favicons?domain=${domain}&sz=256"
}

if fetch_site_icon; then
  # icon-publish re-opens the scratch directory and the icon through the
  # verified descriptor chain (no-follow at every step, size and type
  # checked on the held fd) and renames the icon into place relative to
  # those descriptors — an atomic same-filesystem publish that nothing
  # path-based can redirect. It also removes the scratch dir and its
  # journal entry; the EXIT trap's icon-discard is then a no-op.
  cd /
  python3 "$guard" icon-publish "$base" "$domain" || exit 1
  exit 0
fi
exit 1
