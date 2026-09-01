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
# connects to, and a hard byte ceiling on every download.
#
# Usage: fetch_site_icon.sh <domain> <dest.png>
# Exits non-zero when no usable image could be fetched.

set -u

domain="${1:-}"
dest="${2:-}"
[[ -n $domain && -n $dest ]] || exit 1

# Accept only a plain dotted hostname: no ports, no userinfo, no IP
# literals (a bare IPv4 address has no letters; IPv6 needs colons).
[[ $domain =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62})?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62})?)+$ ]] || exit 1
[[ $domain == *[A-Za-z]* ]] || exit 1

max_bytes=2097152 # 2 MiB ceiling per download
site_url="https://$domain/"
tmp="$dest.tmp.$$"
page_tmp="$dest.page.$$"
trap 'rm -f "$tmp" "$page_tmp"' EXIT

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
# private answers (a rebinding staple) is rejected outright.
public_addrs() {
  local addrs ip
  addrs=$(getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u)
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

download_icon() {
  safe_download "$1" "$tmp" &&
    [[ -s $tmp && $(file -b --mime-type "$tmp") == image/* ]]
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

mkdir -p "$(dirname "$dest")"
if fetch_site_icon; then
  mv -f "$tmp" "$dest"
  rm -f "$page_tmp"
  trap - EXIT
  exit 0
fi
exit 1
