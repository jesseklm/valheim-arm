#!/bin/bash

SERVER=/root/valheim-server
PERSISTENT="/root/.config/unity3d/IronGate/Valheim"
SETTINGS="${PERSISTENT}/settings"

# Quick function to generate a timestamp
timestamp () {
  date +"%Y-%m-%d %H:%M:%S,%3N"
}

valheim_pid=""
shutdown_requested=0
wait_interrupted=0
shutdown () {
    shutdown_requested=1
    wait_interrupted=1
    if [[ -n "$valheim_pid" ]]; then
        echo "$(timestamp) INFO: Requesting graceful Valheim shutdown"
        kill -INT "$valheim_pid" 2>/dev/null || true
    else
        echo "$(timestamp) INFO: Shutdown requested during initialization"
    fi
}
trap shutdown TERM INT

echo "Load extra Box64 and Fex-emu settings from emulators.rc"
source /load_emulators_env.sh
echo " "

/print_app_versions.sh

echo "Update"
export SteamAppId=892970
# SteamCMD (Oct 2026) is flaky under emulation: internal restart requests
# (exit 42), random "Missing configuration" depot failures that can still
# exit 0, and stalls mid-download. Downloads resume, so retry until the
# server files exist.
: "${STEAMCMD_ATTEMPTS:=12}"
: "${STEAMCMD_TIMEOUT:=600}"
STEAMCMD_FLAGS=(+@sSteamCmdForcePlatformBitness 64 +force_install_dir "${SERVER}" +login anonymous +app_update 896660 +quit)
for attempt in $(seq 1 "${STEAMCMD_ATTEMPTS}"); do
    echo "SteamCMD attempt ${attempt}/${STEAMCMD_ATTEMPTS}"
    pkill -9 -f "/root/steamcmd/linux32/steamcmd" 2>/dev/null
    timeout -k 5 "${STEAMCMD_TIMEOUT}" steamcmd.sh "${STEAMCMD_FLAGS[@]}" || true
    # Only valheim_server.x86_64 comes from the depot; the BepInEx files are
    # copied after this loop, so they must not be checked here.
    [ -f "${SERVER}/valheim_server.x86_64" ] && break
    sleep 5
done

if [ ! -f "${SERVER}/valheim_server.x86_64" ]; then
    echo "$(timestamp) ERROR: valheim_server.x86_64 was not installed by steamcmd, aborting (check the Update log above)"
    exit 1
fi

echo "Checking if BepInEx files need to be copied"
mkdir -p "${SERVER}"
if [ ! -d "${SERVER}/BepInEx" ]; then
    echo "Copy BepInEx files"
	cp -r defaults/server/. "${SERVER}/"
else
    echo "The folder ${SERVER}/BepInEx already exists, copying is not needed."
fi
echo " "

echo "Load vars for valheim_server.x86_64"
####
export DOORSTOP_ENABLED=1
export DOORSTOP_TARGET_ASSEMBLY=./BepInEx/core/BepInEx.Preloader.dll

# Apply guest library paths only to the server launch.
guest_library_path="${SERVER}/linux64:${SERVER}/doorstop_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
guest_env="${FEX_ENV:-}"
####

echo "Starting server PRESS CTRL-C to exit"
echo " "
cd ${SERVER}

if [[ ! -f ${SERVER}/linux64/libpulse-mainloop-glib.so.0 ]]; then
    echo "Installing libpulse-mainloop-glib.so.0:x86_64"
    mkdir -p "${SERVER}/linux64/"
    pushd "$(mktemp -d)"
    wget http://mirrors.edge.kernel.org/ubuntu/pool/main/p/pulseaudio/libpulse-mainloop-glib0_17.0%2Bdfsg1-2ubuntu3_amd64.deb
    dpkg -x libpulse-mainloop-glib0_17.0+dfsg1-2ubuntu3_amd64.deb ./
    cp usr/lib/x86_64-linux-gnu/libpulse-mainloop-glib.so.0 "${SERVER}/linux64/"
    echo "Installing libpulse-mainloop-glib.so.0:x86_64 - Done"
    popd
fi

sed -i "s/^enabled *=.*/enabled = ${ENABLE_PLUGINS}/" "${SERVER}/doorstop_config.ini"
if [ "$ENABLE_PLUGINS" = "true" ]; then
    echo "Plugins support is ENABLED"
    doorstop_lib="${SERVER}/doorstop_libs/libdoorstop_x64.so"
    if [[ ! -f "$doorstop_lib" ]]; then
        echo "$(timestamp) ERROR: Doorstop library missing: $doorstop_lib"
        exit 1
    fi
    # FEX_ENV injects the preload into the x86 guest, not native ARM64 tools.
    if [[ -n "$guest_env" && "$guest_env" != "LD_PRELOAD=$doorstop_lib" ]]; then
        echo "$(timestamp) ERROR: Custom FEX_ENV conflicts with Doorstop injection"
        exit 1
    fi
    guest_env="LD_PRELOAD=$doorstop_lib"
else
    echo "Plugins support is DISABLED"
fi

if [ "$ENABLE_CROSSPLAY" = "true" ]; then
    echo "Crossplay is ENABLED"
    CROSSPLAY_FLAG="-crossplay"
else
    echo "Crossplay is DISABLED"
    CROSSPLAY_FLAG=""
fi

mkdir -p "${PERSISTENT}/logs"
LOG_FILE="${PERSISTENT}/logs/valheim_$(date '+%d-%m-%Y').log"

if (( shutdown_requested )); then
    exit 0
fi
# With job control, the asynchronous child does not inherit ignored SIGINT.
set -m
exec {log_fd}> >(tee -a "$LOG_FILE")
log_pid=$!
FEX_ENV="$guest_env" LD_LIBRARY_PATH="$guest_library_path" \
    "${runx64:-FEX}" ./valheim_server.x86_64 \
    -name "$SERVER_NAME" \
    -port 2456 \
    -world "$SERVER_WORLD" \
    -password "$SERVER_PASSWORD" \
    -public $SERVER_VISIBILITY \
    -saveinterval $SERVER_SAVE_INTERVAL \
    -backups $SERVER_BACKUPS \
    -backupshort $SERVER_BACKUP_SHORT \
    -backuplong $SERVER_BACKUP_LONG \
    -savedir ${PERSISTENT} \
    ${CROSSPLAY_FLAG:+"$CROSSPLAY_FLAG"} \
    -nographics  \
    -batchmode \
    >&"$log_fd" 2>&1 &
valheim_pid=$!
exec {log_fd}>&-
echo "$(timestamp) INFO: Valheim launched (PID ${valheim_pid})"
if (( shutdown_requested )); then
    shutdown
fi
while :; do
    wait_interrupted=0
    wait -f "$valheim_pid"
    status=$?
    if (( ! wait_interrupted )); then
        break
    fi
done
wait "$log_pid" 2>/dev/null || true
if (( status == 0 )); then
    echo "$(timestamp) INFO: Shutdown complete."
else
    echo "$(timestamp) ERROR: Valheim exited with status ${status}"
fi
exit "$status"
