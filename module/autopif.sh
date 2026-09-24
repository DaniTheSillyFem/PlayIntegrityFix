#!/bin/sh

PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/data/data/com.termux/files/usr/bin:$PATH
MODDIR=/data/adb/modules/playintegrityfix
version=$(grep "^version=" $MODDIR/module.prop | sed 's/version=//g')

. $MODDIR/common_func.sh

# lets try to use tmpfs for processing
TEMPDIR="$MODDIR/temp" #fallback
[ -w /sbin ] && TEMPDIR="/sbin/playintegrityfix"
[ -w /debug_ramdisk ] && TEMPDIR="/debug_ramdisk/playintegrityfix"
[ -w /dev ] && TEMPDIR="/dev/playintegrityfix"
mkdir -p "$TEMPDIR"
cd "$TEMPDIR"

echo "[+] PlayIntegrityFix $version"
echo "[+] $(basename "$0")"
printf "\n\n"

set_random_pixel() {
	if [ "$(echo "$MODEL_LIST" | wc -l)" -ne "$(echo "$PRODUCT_LIST" | wc -l)" ]; then
		echo "Warning: MODEL_LIST and PRODUCT_LIST have different lengths, using Pixel 6 fallback"
		MODEL="Pixel 6"
		PRODUCT="oriole"
	else
		count=$(echo "$MODEL_LIST" | wc -l)
		rand_index=$(( $$ % count ))
		MODEL=$(echo "$MODEL_LIST" | sed -n "$((rand_index + 1))p")
		PRODUCT=$(echo "$PRODUCT_LIST" | sed -n "$((rand_index + 1))p")
	fi
}

get_model_product_list() {
	printf "{\"model\":["
	count=0
	total=$(echo "$MODEL_LIST" | wc -l)
	echo "$MODEL_LIST" | while read -r model; do
		count=$((count + 1))
		printf "\"%s\"" "$model"
		[ $count -lt $total ] && printf ","
	done
	printf "],\"product\":["
	count=0
	total=$(echo "$PRODUCT_LIST" | wc -l)
	echo "$PRODUCT_LIST" | while read -r product; do
		count=$((count + 1))
		printf "\"%s\"" "$product"
		[ $count -lt $total ] && printf ","
	done
	printf "]}"

	rm -rf "$TEMPDIR"
	exit 0
}

# Get latest Pixel Canary information
download https://developer.android.com/about/versions PIXEL_VERSIONS_HTML
LATEST_BETA=$(grep -B4 -A2 'data-icon="preview' PIXEL_VERSIONS_HTML | grep -o 'href="/about/versions/.*[0-9]"' | cut -d\" -f2)
[ "$LATEST_BETA" ] || LATEST_BETA=$(grep -oE 'href="/about/versions/[0-9]{2}"' PIXEL_VERSIONS_HTML | cut -d\" -f2 | sort -ru | head -n1)
download "https://developer.android.com$LATEST_BETA" PIXEL_LATEST_HTML

# Get FI and OTA information and use the longer device list
FI_URL="https://developer.android.com$(grep -o 'href=".*download.*"' PIXEL_LATEST_HTML | cut -d\" -f2 | sort -ru | head -n1)"
download "$FI_URL" PIXEL_FI_HTML
OTA_URL="https://developer.android.com$(grep -o 'href=".*download-ota.*"' PIXEL_LATEST_HTML | cut -d\" -f2 | sort -ru | head -n1)"
download "$OTA_URL" PIXEL_OTA_HTML
SRC=FI; [ "$(grep 'tr id=' PIXEL_FI_HTML | sed 's;.*<tr id="\(.*\)">.*;\1;' | wc -w)" -lt "$(grep 'tr id=' PIXEL_OTA_HTML | sed 's;.*<tr id="\(.*\)">.*;\1;' | wc -w)" ] && SRC=OTA

# Extract device information
MODEL_LIST="$(grep -A1 'tr id=' PIXEL_${SRC}_HTML | grep 'td' | sed 's;.*<td>\(.*\)</td>.*;\1;')";
PRODUCT_LIST="$(grep 'tr id=' PIXEL_${SRC}_HTML | sed 's;.*<tr id="\(.*\)">.*;\1;')";

# List available devices
if [ "$1" = "--list" ] || [ "$1" = "-l" ]; then
	get_model_product_list
fi

# Select and configure device
echo "- Selecting Pixel device ..."
PRODUCT="${PRODUCT%_beta}"
if [ -z "$PRODUCT" ] || ! echo "$PRODUCT_LIST" | grep -q "$PRODUCT"; then
	set_random_pixel
fi
echo "$MODEL ($PRODUCT)"

# Get device fingerprint and security patch from Flash Tool and bulletins
DEVICE="$PRODUCT"
download https://flash.android.com PIXEL_FLASH_HTML
FLASH_KEY=$(grep -o '<body data-client-config=.*' PIXEL_FLASH_HTML | cut -d\; -f2 | cut -d\& -f1)
if command -v curl > /dev/null 2>&1; then
	curl --connect-timeout 10 -H "Referer: https://flash.android.com" -s "https://content-flashstation-pa.googleapis.com/v1/builds?product=$PRODUCT&key=$FLASH_KEY" > PIXEL_STATION_JSON || download_fail "https://flash.android.com"
else
	busybox wget -T 10 --header "Referer: https://flash.android.com" -qO - "https://content-flashstation-pa.googleapis.com/v1/builds?product=$PRODUCT&key=$FLASH_KEY" > PIXEL_STATION_JSON || download_fail "https://flash.android.com"
fi
ID=""
INCREMENTAL=""

BUILD_ID=""
BUILD_RC=""
BUILD_NOTES=""
BUILD_LATEST=""

while IFS= read -r line; do
	case "$line" in
		*'"buildId": "'*)
			BUILD_ID=$(echo "$line" | cut -d'"' -f4)
			;;
		*'"releaseCandidateName": "'*)
			BUILD_RC=$(echo "$line" | cut -d'"' -f4)
			;;
		*'"version": "'*)
			BUILD_VERSION=$(echo "$line" | cut -d'"' -f4)
			;;
		*'"notes": "'*)
			BUILD_NOTES=$(echo "$line" | cut -d'"' -f4)
			;;
		*'"latest": true'*)
			if [ "$BUILD_NOTES" = "" ] && [ -n "$BUILD_ID" ] && [ -n "$BUILD_RC" ]; then
				INCREMENTAL="$BUILD_ID"
				ID="$BUILD_RC"
				ANDROID_VERSION="${BUILD_VERSION%%.*}"
			fi

			BUILD_ID=""
			BUILD_RC=""
			BUILD_VERSION=""
			BUILD_NOTES=""
			;;
	esac
done < PIXEL_STATION_JSON
FINGERPRINT="google/$PRODUCT/$DEVICE:$ANDROID_VERSION/$ID/$INCREMENTAL:user/release-keys"
download https://source.android.com/docs/security/bulletin/pixel PIXEL_SECBULL_HTML
BUILD_DATE="$(echo "$ID" | sed -n 's/^[A-Z0-9]*\.\([0-9]\{6\}\)\..*/\1/p')"

if [ -z "$BUILD_DATE" ]; then
	echo "! Failed to determine build date"
	exit 1
fi

BULLETIN_YEAR="20$(echo "$BUILD_DATE" | cut -c1-2)"
BULLETIN_MONTH="$(echo "$BUILD_DATE" | cut -c3-4)"
BULLETIN_ID="${BULLETIN_YEAR}-${BULLETIN_MONTH}"

SECURITY_PATCH="$(grep -A1 "<td>$BULLETIN_ID" PIXEL_SECBULL_HTML | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1)"

# Validate required field to prevent empty pif.prop
if [ -z "$ID" ] || [ -z "$INCREMENTAL" ]; then
	echo "! Failed to get latest stable build"
	exit 1
fi

if [ -z "$SECURITY_PATCH" ]; then
	echo "! Failed to determine exact security patch level"
	echo "- Assuming probable security patch level from Canary build info"
	SECURITY_PATCH="${BULLETIN_ID}-05"
fi

# Preserve previous setting
pifProp="$MODDIR/pif.prop"
[ -f "/data/adb/pif.prop" ] && pifProp="/data/adb/pif.prop"
spoofConfig="spoofBuild spoofProps spoofProvider spoofSignature spoofVendingBuild spoofVendingSdk DEBUG"
for config in $spoofConfig; do
	if grep -q "$config=true" "$pifProp"; then
		eval "$config=true"
	else
		eval "$config=false"
	fi
done

echo "- Dumping values to pif.prop ..."
echo ""
cat <<EOF | tee pif.prop
FINGERPRINT=$FINGERPRINT
MANUFACTURER=Google
MODEL=$MODEL
SECURITY_PATCH=$SECURITY_PATCH
spoofBuild=$spoofBuild
spoofProps=$spoofProps
spoofProvider=$spoofProvider
spoofSignature=$spoofSignature
spoofVendingBuild=$spoofVendingBuild
spoofVendingSdk=$spoofVendingSdk
DEBUG=$DEBUG
EOF

cat "$TEMPDIR/pif.prop" > /data/adb/pif.prop
echo ""
echo "- new pif.prop saved to /data/adb/pif.prop"

if [ -e "/data/adb/tricky_store/pif_auto_security_patch" ]; then
	sh "$MODDIR/security_patch.sh"
else
	rm -f $MODDIR/system.prop
fi

echo "- Cleaning up ..."
rm -rf "$TEMPDIR"

for i in $(busybox pidof com.google.android.gms.unstable com.android.vending); do
	echo "- Killing pid $i"
	kill -9 "$i"
done

echo "- Done!"
sleep_pause
