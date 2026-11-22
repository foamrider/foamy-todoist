#!/bin/sh
# A stand-in for `secret-tool` that answers as libsecret 0.21 with
# gnome-keyring does (foamy-zendesk checked the same answers against a real
# one). Its state is files next to it: `item` is the stored secret and
# `locked` locks its keyring, every unlock prompt dismissed. `search-fails`
# makes `search` fail and `lookup-dies` kills `lookup`. `readonly-after-store`
# names a directory that a successful `store` makes read-only (a cache that
# breaks between the token being stored and the cache being written). Each
# run's whole argv is appended to `log`, so tests can check the secret never
# is in it.
d=$(dirname "$0")
echo "$*" >>"$d/log"
# Every call names exactly this item.
verb=$1
shift
case "$*" in
  "service foamy-todoist account personal-token" | "--label=Foamy Todoist API token service foamy-todoist account personal-token") ;;
  *)
    echo "fake secret-tool: unexpected attributes: $*" >&2
    exit 2
    ;;
esac
readable() { [ -f "$d/item" ] && [ ! -e "$d/locked" ]; }
case $verb in
  lookup)
    [ -e "$d/lookup-dies" ] && kill -9 $$
    # Not found and a dismissed unlock prompt look the same: exit 1, silent.
    if readable; then
      cat "$d/item"
      exit 0
    fi
    exit 1
    ;;
  clear)
    # Only unlocked items are removed, without a prompt.
    if readable; then
      rm "$d/item"
      exit 0
    fi
    exit 1
    ;;
  search)
    if [ -e "$d/search-fails" ]; then
      echo "secret-tool: The name is not activatable" >&2
      exit 1
    fi
    [ -f "$d/item" ] || exit 0
    echo "[/1]"
    echo "label = Foamy Todoist API token"
    if [ -e "$d/locked" ]; then
      echo "secret-tool: Cannot get secret of a locked object" >&2
    else
      printf 'secret = '
      cat "$d/item"
      echo
    fi
    echo "attribute.service = foamy-todoist" >&2
    exit 0
    ;;
  store)
    if [ -e "$d/locked" ]; then
      echo "secret-tool: Cannot create an item in a locked collection" >&2
      exit 1
    fi
    cat >"$d/item"
    if [ -s "$d/readonly-after-store" ]; then chmod 500 "$(cat "$d/readonly-after-store")"; fi
    exit 0
    ;;
esac
exit 2
