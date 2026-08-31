#!/bin/bash

# Fetch a site's icon for the Omachron panel the same way
# omarchy-webapp-install fetches web-app icons: prefer the page's own
# apple-touch-icon link (typically 180px+), then the well-known
# /apple-touch-icon.png path, then Google's favicon service as a last
# resort. The download must be a real image; the write is atomic so the
# panel never reads a half-written file.
#
# Usage: fetch_site_icon.sh <domain> <dest.png>
# Exits non-zero when no usable image could be fetched.

set -u

domain="${1:-}"
dest="${2:-}"
[[ -n $domain && -n $dest ]] || exit 1

site_url="https://$domain/"
tmp="$dest.tmp.$$"
trap 'rm -f "$tmp"' EXIT

download_icon() {
  curl -fsSL --max-time 10 -o "$tmp" "$1" 2>/dev/null &&
    [[ -s $tmp && $(file -b --mime-type "$tmp") == image/* ]]
}

fetch_site_icon() {
  local origin="https://$domain"
  local page icon_url
  page=$(curl -fsSL --max-time 5 "$site_url" 2>/dev/null | head -c 100000 | tr '\n' ' ')
  icon_url=$(grep -oiE "<link[^>]*rel=[\"'][^\"']*apple-touch-icon[^\"']*[\"'][^>]*>" <<<"$page" |
    grep -oiE "href=[\"'][^\"']+" | head -1 | sed -E "s/^href=[\"']//")

  case $icon_url in
  http://* | https://*) ;;
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
  trap - EXIT
  exit 0
fi
exit 1
