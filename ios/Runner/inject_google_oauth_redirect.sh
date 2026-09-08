#!/bin/sh

set -eu

ios_client_id=""
ios_reversed_client_id=""
server_client_id=""

old_ifs="$IFS"
IFS=','
for encoded_define in ${DART_DEFINES:-}; do
  decoded_define=$(printf '%s' "$encoded_define" | /usr/bin/base64 --decode 2>/dev/null || true)
  case "$decoded_define" in
    GOOGLE_CLIENT_ID=*) ios_client_id=${decoded_define#GOOGLE_CLIENT_ID=} ;;
    GOOGLE_SERVER_CLIENT_ID=*) server_client_id=${decoded_define#GOOGLE_SERVER_CLIENT_ID=} ;;
    GOOGLE_IOS_REVERSED_CLIENT_ID=*)
      ios_reversed_client_id=${decoded_define#GOOGLE_IOS_REVERSED_CLIENT_ID=}
      ;;
  esac
done
IFS="$old_ifs"

if [ -z "$ios_client_id" ] || [ -z "$ios_reversed_client_id" ]; then
  exit 0
fi

case "$ios_client_id" in
  *[!A-Za-z0-9._-]*) echo "error: GOOGLE_CLIENT_ID contains unsupported characters." >&2; exit 1 ;;
esac
case "$ios_reversed_client_id" in
  *[!A-Za-z0-9._-]*) echo "error: GOOGLE_IOS_REVERSED_CLIENT_ID contains unsupported characters." >&2; exit 1 ;;
esac

built_info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$built_info_plist" ]; then
  echo "error: Built Info.plist was not found for Google OAuth configuration." >&2
  exit 1
fi

plist_buddy=/usr/libexec/PlistBuddy
"$plist_buddy" -c "Delete :GIDClientID" "$built_info_plist" >/dev/null 2>&1 || true
"$plist_buddy" -c "Add :GIDClientID string $ios_client_id" "$built_info_plist"

"$plist_buddy" -c "Delete :GIDServerClientID" "$built_info_plist" >/dev/null 2>&1 || true
if [ -n "$server_client_id" ]; then
  "$plist_buddy" -c "Add :GIDServerClientID string $server_client_id" "$built_info_plist"
fi

"$plist_buddy" -c "Delete :CFBundleURLTypes" "$built_info_plist" >/dev/null 2>&1 || true
"$plist_buddy" -c "Add :CFBundleURLTypes array" "$built_info_plist"
"$plist_buddy" -c "Add :CFBundleURLTypes:0 dict" "$built_info_plist"
"$plist_buddy" -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor" "$built_info_plist"
"$plist_buddy" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$built_info_plist"
"$plist_buddy" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $ios_reversed_client_id" "$built_info_plist"

echo "Configured the iOS Google OAuth return URL scheme."
