#!/bin/bash
#
# 5 RANGER Arma 3 yolk entrypoint — a fork of upstream's, with two defects fixed.
#
# Upstream:   parkervcp/yolks, games/arma3/entrypoint.sh (AGPL-3.0-or-later, Red-Thirten)
# Downstream: ghcr.io/gibsx/5ranger-arma3:latest, run by Wings for Pterodactyl egg 68
# Uses:       curl and awk (mawk), both already in debian:bookworm-slim; no added packages
#
# Everything below this header is upstream's file plus the changes in upstream.patch.
# Keep that patch in step with any edit here, because it is what gets sent upstream.
#

# Arma 3 Yolk Entrypoint - entrypoint.sh
# Date: 2025/10/15
# Copyright (C) 2025  David Wolfe (Red-Thirten) and contributors
# Contributors: Aussie Server Hosts (https://aussieserverhosts.com/), Stephen White (SilK)
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

## === CONSTANTS ===
STEAMCMD_DIR="./steamcmd"                       # SteamCMD's directory containing steamcmd.sh
WORKSHOP_DIR="./Steam/steamapps/workshop"       # SteamCMD's directory containing workshop downloads
STEAMCMD_LOG="${STEAMCMD_DIR}/steamcmd.log"     # Log file for SteamCMD
GAME_ID=107410                                  # SteamCMD ID for the Arma 3 GAME (not server). Only used for Workshop mod downloads.
MODS_PER_SESSION=30                             # Workshop downloads per SteamCMD login. Steam rate limits logins, not downloads.
SERVER_PARAM_FILE="startup_params_server.txt"   # File name for the auto-generated server par file to be used during startup
HC_PARAM_FILE="startup_params_hc.txt"           # File name for the auto-generated Headless Client par file to be used during startup
EGG_URL='https://github.com/pelican-eggs/games-steamcmd/tree/main/arma/arma3'   # URL for Egg & README (only used as info to legacy users)

# Color Codes
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

## === ENVIRONMENT VARS ===
# HOME, STARTUP, STEAM_USER, STEAM_PASS, SERVER_BINARY, MOD_FILE, MODIFICATIONS, SERVERMODS, OPTIONALMODS, UPDATE_SERVER, VALIDATE_SERVER,
# MODS_LOWERCASE, STEAMCMD_APPID, STEAMCMD_BETAID, HC_NUM, SERVER_PASSWORD, HC_HIDE, STEAMCMD_ATTEMPTS, BASIC_CFG_URL,
# PARAM_NOLOGS, PARAM_AUTOINIT, PARAM_FILEPATCHING, PARAM_LOADMISSIONTOMEMORY, PARAM_LIMITFPS

## === GLOBAL VARS ===
# modifiedStartup, allMods, clientMods, modResult, modUpdated, modTitle

## === DEFINE FUNCTIONS ===

# Runs one SteamCMD session and classifies what it logged.
# Returns 0 on success, 1 when the caller should retry, and exits for anything fatal.
function SteamCMDSession { #[Input: int server=0 mod=1 optional_mod=2; str appid | mod ids]
    local kind=$1 target=$2 downloads="" id

    if [[ -f "${STEAMCMD_LOG}" ]]; then
        rm -f "${STEAMCMD_LOG:?}"
    fi

    if [[ ${kind} == 0 ]]; then # Server
        ${STEAMCMD_DIR}/steamcmd.sh +force_install_dir ${HOME} "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +app_update ${target} $( [[ -n ${STEAMCMD_BETAID} ]] && printf %s "-beta ${STEAMCMD_BETAID}" ) $( [[ ${VALIDATE_SERVER} == 1 ]] && printf %s "validate" ) +quit | tee -a "${STEAMCMD_LOG}"
    else # Mods - every id in this session, behind a single login
        for id in ${target}; do
            downloads+=" +workshop_download_item ${GAME_ID} ${id}"
        done
        ${STEAMCMD_DIR}/steamcmd.sh "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" ${downloads} +quit | tee -a "${STEAMCMD_LOG}"
    fi

    local steamcmdExitCode=${PIPESTATUS[0]}
    local loggedErrors
    loggedErrors=$(grep -i "error\|failed" "${STEAMCMD_LOG}" | grep -iv "setlocal\|SDL\|steamservice\|thread priority\|libcurl")

    if [[ -n ${loggedErrors} ]]; then
        # Soft errors - worth another attempt
        if [[ -n $(grep -i "Rate Limit Exceeded" "${STEAMCMD_LOG}") ]]; then # Steam refused the login
            echo -e "\n${YELLOW}[UPDATE_WARN]: ${NC}Steam is rate limiting logins from this address."
            echo -e "\t(Too many SteamCMD sign-ins in a short time. Backing off and trying again.)"
            return 1
        elif [[ -n $(grep -i "Timeout downloading item" "${STEAMCMD_LOG}") ]]; then # Mod download timeout
            echo -e "\n${YELLOW}[UPDATE]: ${NC}Timeout downloading a Steam Workshop mod."
            echo -e "\t(This is expected for particularly large mods)"
            return 1
        elif [[ -n $(grep -i "0x402\|0x6\|0x602" "${STEAMCMD_LOG}") ]]; then # Connection issue with Steam
            echo -e "\n${YELLOW}[UPDATE]: ${NC}Connection issue with Steam servers."
            echo -e "\t(Steam servers may currently be down, or a connection cannot be made reliably)"
            return 1
        # Hard errors
        elif [[ -n $(grep -i "Password check for AppId" "${STEAMCMD_LOG}") ]]; then # Incorrect beta branch password
            echo -e "\n${RED}[UPDATE]: ${YELLOW}Incorrect password given for beta branch \"${STEAMCMD_BETAID}\". ${CYAN}Skipping download...${NC}"
            echo -e "\t(Please contact the maintainer of this image; an update may be required)"
            return 2
        # Fatal errors
        elif [[ -n $(grep -i "Invalid Password\|two-factor\|No subscription" "${STEAMCMD_LOG}") ]]; then # Wrong username/password, Steam Guard is turned on, or host is using anonymous account
            echo -e "\n${RED}[UPDATE]: Cannot login to Steam - Improperly configured account and/or credentials${NC}"
            echo -e "\t${YELLOW}Please contact your administrator/host and give them the following message:${NC}"
            echo -e "\t${CYAN}Your Egg, or your client's server, is not configured with valid Steam credentials.${NC}"
            echo -e "\t${CYAN}Either the username/password is wrong, or Steam Guard is not fully disabled${NC}"
            echo -e "\t${CYAN}in accordance to this Egg's documentation/README.${NC}\n"
            exit 1
        elif [[ -n $(grep -i "0x202\|0x212" "${STEAMCMD_LOG}") ]]; then # Not enough disk space
            echo -e "\n${RED}[UPDATE]: Unable to complete download - Not enough storage${NC}"
            echo -e "\t${YELLOW}You have run out of your allotted disk space.${NC}"
            echo -e "\t${YELLOW}Please contact your administrator/host for potential storage upgrades.${NC}\n"
            exit 1
        elif [[ -n $(grep -i "0x606" "${STEAMCMD_LOG}") ]]; then # Disk write failure
            echo -e "\n${RED}[UPDATE]: Unable to complete download - Disk write failure${NC}"
            echo -e "\t${YELLOW}This is normally caused by directory permissions issues,${NC}"
            echo -e "\t${YELLOW}but could be a more serious hardware issue.${NC}"
            echo -e "\t${YELLOW}(Please contact your administrator/host if this issue persists)${NC}\n"
            exit 1
        elif [[ -n $(grep -i "Download item" "${STEAMCMD_LOG}") ]]; then # A mod SteamCMD would not serve
            echo -e "\n${YELLOW}[UPDATE_WARN]: ${NC}SteamCMD refused to download one or more mods in this session."
            echo -e "\t${YELLOW}The account may not own the base game, may lack access to a private item,${NC}"
            echo -e "\t${YELLOW}or the item may no longer exist.${NC}"
            return 1
        else # Unknown caught error
            echo -e "\n${YELLOW}[UPDATE_WARN]: ${NC}An unrecognised SteamCMD error occurred."
            echo -e "SteamCMD Errors:\n${loggedErrors}"
            return 1
        fi
    elif [[ ${steamcmdExitCode} != 0 ]]; then # Unknown fatal error
        echo -e "\n${RED}[UPDATE]: SteamCMD has crashed for an unknown reason!${NC} (Exit code: ${CYAN}${steamcmdExitCode}${NC})"
        echo -e "\t${YELLOW}(Please contact your administrator/host for support)${NC}\n"
        cp -r /tmp/dumps ./dumps
        exit ${steamcmdExitCode}
    fi
    return 0
}

# Copies a downloaded mod's keys into keys/ and (re)builds its @<id> folder.
function InstallWorkshopMod { #[Input: int mod=1 optional_mod=2; int id]
    local kind=$1 id=$2 src="${WORKSHOP_DIR}/content/${GAME_ID}/$2" file filename

    # Refuse to rebuild from an empty or absent source. SteamCMD reports success when it believes
    # an item is current, which it can do while the item's files are gone - and the rebuild below
    # starts with "rm -rf", so an empty source would destroy the only copy left of a mod that may
    # not be downloadable again.
    if [[ ! -d "${src}" ]] || [[ -z "$(ls -A "${src}" 2>/dev/null)" ]]; then
        echo -e "\n${YELLOW}[UPDATE_WARN]: ${NC}No downloaded files present for ${CYAN}${id}${NC}."
        echo -e "\t${YELLOW}Keeping the copy already in place and leaving it untouched.${NC}"
        echo -e "\t(If SteamCMD's records say this mod is installed while its files are missing,"
        echo -e "\t delete its entry from ${CYAN}${WORKSHOP_DIR}/appworkshop_${GAME_ID}.acf${NC} to force a full download.)"
        return 1
    fi

    echo -e "\n\tMoving ${CYAN}${id}${NC}'s ${CYAN}.bikey${NC} files to the ${CYAN}keys/${NC} folder..."
    if [[ ${kind} == 1 ]]; then # Regular mod
        find "${src}" -name "*.bikey" -type f -exec cp -t "keys" {} +
        # Make a fresh hard link copy of the downloaded mod to the current directory
        echo -e "\tMaking ${CYAN}hard link${NC} copy of mod to: ${CYAN}$(pwd)/@${id}${NC}"
        rm -rf @${id}
        mkdir @${id}
        cp -al ${src}/* @${id}/
        # Make the hard link copy's contents all lowercase
        # (This complies with Arma's mod-folder rules while not disturbing the mod's SteamCMD source files)
        ModsLowercase @${id}
    else # Optional mod
        # Give optional mod keys a custom name during move which can be checked later for deleting un-configured mods
        for file in $(find "${src}" -name "*.bikey" -type f); do
            filename=$(basename ${file})
            cp $file keys/optional_${id}_${filename}
        done;
        # Deleting the files leaves the item recorded in appworkshop_<GAME_ID>.acf as installed
        # while its files are gone, so SteamCMD is later asked to update content it no longer has.
        if [[ ${OPTIONALMODS_KEEP_FILES:-1} == "1" ]]; then
            echo -e "\tMod is an ${CYAN}optional mod${NC}. Keeping mod files (${CYAN}OPTIONALMODS_KEEP_FILES${NC} is enabled)."
        else
            echo -e "\tMod is an ${CYAN}optional mod${NC}. Deleting mod files to save space..."
            rm -r ${src}
        fi
        # Create a directory so time-based detection of auto updates works correctly
        mkdir -p "@${id}_optional" && touch "@${id}_optional"
        touch "@${id}_optional/DON'T DELETE THIS DIRECTORY - USED FOR AUTO UPDATES"
    fi
    echo -e "${GREEN}[UPDATE]: ${CYAN}${id}${GREEN} download/update successful!${NC}"
    return 0
}

# Updates the game server, or downloads a set of Workshop mods and installs each one.
#
# Mods are fetched MODS_PER_SESSION at a time behind a single SteamCMD login, because Steam rate
# limits *logins* rather than downloads: one login per mod fails partway through any sizeable
# batch, and every mod after the limit is reached logs
# "Logging in user ... ERROR (Rate Limit Exceeded)" and is skipped. Measured on a 131-mod server,
# 44 mods downloaded and the remaining 12 all failed that way.
function RunSteamCMD { #[Input: int server=0 mod=1 optional_mod=2; str appid | mod ids]
    local kind=$1
    local pending=($2)
    local attempt=0 i rc id batch failed

    if [[ ${kind} == 0 ]]; then # Server
        while (( attempt < STEAMCMD_ATTEMPTS )); do
            attempt=$((attempt+1))
            if (( attempt > 1 )); then
                echo -e "\t${YELLOW}Re-attempting game server update in 10 seconds...${NC} (Attempt ${CYAN}${attempt}${NC} of ${CYAN}${STEAMCMD_ATTEMPTS}${NC})\n"
                sleep 10
            fi
            SteamCMDSession 0 "$2" && { echo -e "\n${GREEN}[UPDATE]: Game server is up to date!${NC}"; return 0; }
            (( $? == 2 )) && break
        done
        echo -e "\t${RED}Unable to complete game server update. ${CYAN}Skipping...${NC}"
        echo -e "\t(Please try again at a later time)"
        sleep 3
        return 1
    fi

    # Download, in as few logins as possible, retrying whatever did not arrive
    while (( ${#pending[@]} > 0 && attempt < STEAMCMD_ATTEMPTS )); do
        attempt=$((attempt+1))
        if (( attempt > 1 )); then
            echo -e "\n\t${YELLOW}Re-attempting ${CYAN}${#pending[@]}${YELLOW} mod download(s) in 60 seconds...${NC} (Attempt ${CYAN}${attempt}${NC} of ${CYAN}${STEAMCMD_ATTEMPTS}${NC})"
            echo -e "\t(A pause here also lets any Steam login rate limit expire)\n"
            sleep 60
        fi
        i=0
        while (( i < ${#pending[@]} )); do
            batch=("${pending[@]:i:MODS_PER_SESSION}")
            i=$((i+MODS_PER_SESSION))
            echo -e "\n${GREEN}[UPDATE]:${NC} Downloading ${CYAN}${#batch[@]}${NC} mod(s) in one SteamCMD session...\n"
            SteamCMDSession "${kind}" "${batch[*]}"
            rc=$?
            (( rc == 2 )) && break 2
        done
        # Keep only the mods whose files did not arrive
        failed=()
        for id in "${pending[@]}"; do
            [[ -d "${WORKSHOP_DIR}/content/${GAME_ID}/${id}" ]] || failed+=("${id}")
        done
        pending=("${failed[@]}")
    done

    if (( ${#pending[@]} > 0 )); then
        echo -e "\n\t${RED}Unable to download ${CYAN}${#pending[@]}${RED} mod(s): ${CYAN}${pending[*]}${NC}"
        echo -e "\t(You may try again later, or upload them to your server via SFTP)"
        sleep 3
    fi

    # Install everything that did arrive
    for id in $2; do
        if [[ -d "${WORKSHOP_DIR}/content/${GAME_ID}/${id}" ]]; then
            InstallWorkshopMod "${kind}" "${id}"
        fi
    done
}

# Takes a directory (string) as input, and recursively makes all files & folders lowercase.
function ModsLowercase {
    echo -e "\tMaking mod ${CYAN}$1${NC} files/folders ${CYAN}lowercase${NC}..."
    while IFS= read -r -d '' SRC; do
        DST="$(dirname "${SRC}")/$(basename "${SRC}" | tr '[:upper:]' '[:lower:]')"
        if [ "${SRC}" != "${DST}" ] && [ ! -e "${DST}" ]; then
            mv -T "${SRC}" "${DST}"
        fi
    done < <(find "./$1" -depth -print0)
}

# Removes duplicate items from a semicolon delimited string
function RemoveDuplicates { #[Input: str - Output: printf of new str]
    if [[ -n $1 ]]; then # If nothing to compare, skip to prevent extra semicolon being returned
        echo $1 | sed -e 's/;/\n/g' | sort -u | xargs printf '%s;'
    fi
}

# Asks the Steam Web API about every given Workshop ID, filling the modResult/modUpdated/modTitle
# maps, 100 IDs per request. Returns non-zero if any request could not be parsed. An item the
# API will not describe (private, unlisted or removed) comes back with result != 1 and no
# timestamp; the caller hands those to SteamCMD rather than assuming they are gone.
#
# This replaces scraping one Workshop changelog web page per mod. Those pages are rate limited:
# a server with ~130 mods trips the limit part way through its own start-up, every later page
# returns HTTP 429, the scrape then parses as an empty string, and the comparison below silently
# treats the mod as current. The failure is invisible - no error is printed - and because each
# start re-trips the limit, mods can stay frozen indefinitely. The Web API answers the same
# question for every mod at once, needs no API key, and is not rate limited at this volume.
# The reply is read with awk, which this image already has, so no new dependency is introduced.
function FetchWorkshopDetails { #[Input: str ids (space delimited)]
    local ids=($1)
    local total=${#ids[@]}
    local i=0 n chunk body got
    while (( i < total )); do
        chunk=""; n=0
        while (( n < 100 && i < total )); do
            chunk+="&publishedfileids[${n}]=${ids[$i]}"
            n=$((n+1)); i=$((i+1))
        done
        body=$(curl -sS --max-time 30 --retry 2 --retry-delay 3 \
            -X POST "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
            -d "itemcount=${n}${chunk}" 2>/dev/null)

        # Each item in the response begins with its own "publishedfileid" key, so that string makes
        # a record separator; only the three scalars this script needs are read out of each record.
        got=0
        while IFS=$'\t' read -r id result updated title; do
            modResult[$id]=$result
            modUpdated[$id]=$updated
            modTitle[$id]=$title
            got=$((got+1))
        done < <(printf '%s' "${body}" | awk '
            BEGIN { RS = "\"publishedfileid\":\"" }
            NR > 1 {
                id = substr($0, 1, index($0, "\"") - 1)
                if (id !~ /^[0-9]+$/) next
                res = "0"; upd = "0"; ttl = ""
                if (match($0, /"result":[0-9]+/))       res = substr($0, RSTART + 9,  RLENGTH - 9)
                if (match($0, /"time_updated":[0-9]+/)) upd = substr($0, RSTART + 15, RLENGTH - 15)
                if (match($0, /"title":"([^"\\]|\\.)*"/)) {
                    ttl = substr($0, RSTART + 9, RLENGTH - 10)
                    gsub(/\\"/, "\"", ttl); gsub(/\\\\/, "\\", ttl); gsub(/\t/, " ", ttl)
                }
                if (ttl == "") ttl = "[NAME UNAVAILABLE]"
                printf "%s\t%s\t%s\t%s\n", id, res, upd, ttl
            }')

        # An empty, truncated or non-JSON reply (a rate-limit or error page) yields no records
        if (( got == 0 )); then
            return 1
        fi
    done
    return 0
}

## === ENTRYPOINT START ===

# Wait for the container to fully initialize
sleep 1

# Switch to the container's working directory
cd ${HOME} || exit 1

# Check for old Eggs
if [[ -z ${PARAM_NOLOGS+x} ]]; then # PARAM_NOLOGS was not in the previous version
    echo -e "\n${RED}[STARTUP_ERR]: Please contact your administrator/host for support, and give them the following message:${NC}\n"
    echo -e "\t${CYAN}Your Arma 3 Egg is outdated and no longer supported.${NC}"
    echo -e "\t${CYAN}Please download the latest version at the following link, and install it in your panel:${NC}"
    echo -e "\t${CYAN}${EGG_URL}${NC}\n"
    exit 1
fi

# Collect and parse all specified mods
if [[ -n ${MODIFICATIONS} ]] && [[ ${MODIFICATIONS} != *\; ]]; then # Add manually specified mods to the client-side mods list, while checking for trailing semicolon
    clientMods="${MODIFICATIONS};"
else
    clientMods=${MODIFICATIONS}
fi
if [[ -f ${MOD_FILE} ]] && [[ -n "$(cat ${MOD_FILE} | grep 'Created by Arma 3 Launcher')" ]]; then # If the mod list file exists and is valid, parse and add mods to the client-side mods list
    clientMods+=$(cat ${MOD_FILE} | grep 'id=' | cut -d'=' -f3 | cut -d'"' -f1 | xargs printf '@%s;')
elif [[ -n "${MOD_FILE}" ]]; then # If MOD_FILE is not null, warn user file is missing or invalid
    echo -e "\n${YELLOW}[STARTUP_WARN]: Arma 3 Modlist file \"${CYAN}${MOD_FILE}${YELLOW}\" could not be found, or is invalid!${NC}"
    echo -e "\tEnsure your uploaded modlist's file name matches your Startup Parameter."
    echo -e "\tOnly files exported from an Arma 3 Launcher are permitted."
    if [[ -n "${clientMods}" ]]; then
        echo -e "\t${CYAN}Reverting to the manual mod list...${NC}"
    fi
fi
if [[ -n ${SERVERMODS} ]] && [[ ${SERVERMODS} != *\; ]]; then # Add server mods to the master mods list, while checking for trailing semicolon
    allMods="${SERVERMODS};"
else
    allMods=${SERVERMODS}
fi
if [[ -n ${OPTIONALMODS} ]] && [[ ${OPTIONALMODS} != *\; ]]; then # Add specified optional mods to the mods list, while checking for trailing semicolon
    allMods+="${OPTIONALMODS};"
else
    allMods+=${OPTIONALMODS}
fi
allMods+=$clientMods # Add all client-side mods to the master mod list
clientMods=$(RemoveDuplicates ${clientMods}) # Remove duplicate mods from clientMods, if present
allMods=$(RemoveDuplicates ${allMods}) # Remove duplicate mods from allMods, if present
allMods=$(echo $allMods | sed -e 's/;/ /g') # Convert from string to array

# Update everything (server and mods), if specified
if [[ ${UPDATE_SERVER} == 1 ]]; then
    echo -e "\n${GREEN}[STARTUP]: ${CYAN}Starting checks for all updates...${NC}"
    echo -e "(It is okay to ignore any \"SDL\", \"steamservice\", and \"thread priority\" errors during this process)\n"

    ## Update game server
    echo -e "${GREEN}[UPDATE]:${NC} Checking for ${CYAN}game server${NC} updates with App ID: ${CYAN}${STEAMCMD_APPID}${NC}..."
    if [[ ${VALIDATE_SERVER} == 1 ]]; then
        echo -e "\t${CYAN}File validation enabled.${NC} (This may take extra time to complete)"
    fi
    if [[ -n ${STEAMCMD_BETAID} ]]; then
        echo -e "\tDownload/Update of ${CYAN}\"${STEAMCMD_BETAID}\" branch enabled.${NC}"
    fi
    echo -e ""

    RunSteamCMD 0 ${STEAMCMD_APPID}

    ## Update mods
    if [[ -n $allMods ]]; then
        echo -e "\n${GREEN}[UPDATE]:${NC} Checking all ${CYAN}Steam Workshop mods${NC} for updates..."

        declare -A modResult modUpdated modTitle
        fetchMods="" ; fetchOptional=""
        modIDs=$(echo $allMods | sed -e 's/@//g' | tr ' ' '\n' | grep -E '^[0-9]+$' | tr '\n' ' ')

        # One lookup for every mod, rather than a web page per mod
        apiOK=1
        if [[ -n ${modIDs} ]] && ! FetchWorkshopDetails "${modIDs}"; then
            apiOK=0
            echo -e "\n${YELLOW}[UPDATE_WARN]: ${NC}Could not reach the Steam Web API to check for mod updates."
            echo -e "\t${YELLOW}Mods already downloaded will be left as they are; missing mods will still be fetched.${NC}"
            echo -e "\t${YELLOW}(Check this container's outbound access to api.steampowered.com)${NC}"
        fi

        for modID in ${modIDs}; do
            # If a mod is defined in OPTIONALMODS, and is not defined in clientMods or SERVERMODS, then treat as an optional mod
            # Optional mods are given a different directory which is checked to see if a new update is available. This is to ensure
            # if an optional mod is switched to be a standard client-side mod, this script will redownload the mod
            if [[ "${OPTIONALMODS}" == *"@${modID};"* ]] && [[ "${clientMods}" != *"@${modID};"* ]] && [[ "${SERVERMODS}" != *"@${modID};"* ]]; then
                modType=2
                modDir=@${modID}_optional
            else
                modType=1
                modDir=@${modID}
            fi

            modName=${modTitle[$modID]:-"[NAME UNAVAILABLE]"}

            # The public API cannot see a private or unlisted item, and reports it exactly as it
            # reports a deleted one. Rather than skip it - which would strip a server of its own
            # unpublished mods - let SteamCMD decide, since it is logged in and we are not.
            modUnknown=0
            if (( apiOK == 1 )) && [[ -n ${modResult[$modID]} ]] && (( ${modResult[$modID]} != 1 )); then
                modUnknown=1
                echo -e "\n${YELLOW}[UPDATE_WARN]: ${NC}Mod ${CYAN}${modID}${NC} could not be looked up on the Steam Workshop."
                echo -e "\t(It is private, unlisted, or removed. Asking SteamCMD, which is signed in, instead.)"
            fi

            latestUpdate=${modUpdated[$modID]:-0}

            if [[ ! -d $modDir ]]; then
                echo -e "\n${GREEN}[UPDATE]:${NC} Downloading new Mod: \"${CYAN}${modName}${NC}\" (${CYAN}${modID}${NC})"
            elif (( modUnknown == 1 )); then
                echo -e "\t${CYAN}Checking it with SteamCMD...${NC}"
            elif (( apiOK == 1 && latestUpdate > 0 )) && (( latestUpdate > $(stat -c %Y "$modDir") )); then
                echo -e "\n${GREEN}[UPDATE]:${NC} Mod update found for: \"${CYAN}${modName}${NC}\" (${CYAN}${modID}${NC})"
                echo -e "\tMod was last updated: ${CYAN}$(date -d @${latestUpdate})${NC}"
            else
                continue
            fi

            # Collected rather than fetched one at a time, so every mod shares a login
            if (( modType == 2 )); then
                fetchOptional+=" ${modID}"
            else
                fetchMods+=" ${modID}"
            fi
        done

        if [[ -n ${fetchMods}${fetchOptional} ]]; then
            [[ -n ${fetchMods} ]] && RunSteamCMD 1 "${fetchMods}"
            [[ -n ${fetchOptional} ]] && RunSteamCMD 2 "${fetchOptional}"
        else
            echo -e "\n${GREEN}[UPDATE]:${NC} All mods are already up to date."
        fi

        # Check over key files for un-configured optional mods' .bikey files
        for keyFile in $(find "keys" -name "*.bikey" -type f); do
            keyFileName=$(basename ${keyFile})

            # If the key file is using the optional mod file name
            if [[ "${keyFileName}" == "optional_"* ]]; then
                modID=$(echo "${keyFileName}" | cut -d _ -f 2)

                # If mod is not in optional mods, delete it
                # If a mod is configured in clientMods or SERVERMODS, we should still delete this file
                # as a new file will have been copied that does not follow the naming scheme
                if [[ "${OPTIONALMODS}" != *"@${modID};"* ]]; then

                    # We only need to let the user know the key file is being deleted if this mod is no longer configured at all.
                    # If clientMods contains the mod ID, we'd just confuse the user by telling them we are deleting the optional .bikey file
                    if [[ "${clientMods}" != *"@${modID};"* ]]; then
                        echo -e "\tKey file and directory for un-configured optional mod ${CYAN}${modID}${NC} is being deleted..."
                    fi

                    # Delete the optional mod .bikey file and directory
                    rm ${keyFile}
                    rm -r @${modID}_optional
                fi
            fi
        done;

        echo -e "${GREEN}[UPDATE]:${NC} Steam Workshop mod update check ${GREEN}complete${NC}!"
    fi
fi

# Check if specified server binary exists.
if [[ ! -f ${SERVER_BINARY} ]]; then
    echo -e "\n${RED}[STARTUP_ERR]: Specified Arma 3 server binary could not be found in `$(pwd)`!${NC}"
    echo -e "${YELLOW}Please do the following to resolve this issue:${NC}"
    echo -e "\t${CYAN}- Double check your \"Server Binary\" Startup Variable is correct.${NC}"
    echo -e "\t${CYAN}- Ensure your server has properly installed/updated without errors (reinstalling/updating again may help).${NC}"
    echo -e "\t${CYAN}- Use the File Manager to check that your specified server binary file is not missing from `$(pwd)`.${NC}\n"
    exit 1
fi

# Make mods lowercase, if specified
if [[ ${MODS_LOWERCASE} == "1" ]]; then
    for modDir in $allMods; do
        ModsLowercase $modDir
    done
fi

# Define the log file path with a timestamp
logFile="${HOME}/.local/share/Arma 3/rpt/arma3server_$(date '+%m_%d_%Y_%H%M%S').rpt"
# Ensure the logs directory exists
mkdir -p "${HOME}/.local/share/Arma 3/rpt"

# Check if basic.cfg exists, and download if not (Arma really doesn't like it missing for some reason)
if [[ ! -f basic.cfg ]]; then
    echo -e "\n${YELLOW}[STARTUP_WARN]: Basic Network Configuration file \"${CYAN}basic.cfg${YELLOW}\" is missing!${NC}"
    echo -e "\t${YELLOW}Downloading default file for use instead...${NC}"
    curl -sSL ${BASIC_CFG_URL} -o ./basic.cfg
fi

# Setup NSS Wrapper for use ($NSS_WRAPPER_PASSWD and $NSS_WRAPPER_GROUP have been set by the Dockerfile)
export USER_ID=$(id -u)
export GROUP_ID=$(id -g)
envsubst < /passwd.template > ${NSS_WRAPPER_PASSWD}

if [[ ${SERVER_BINARY} == *"x64"* ]]; then # Check which libnss-wrapper architecture to run, based off the server binary name
    export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libnss_wrapper.so
else
    export LD_PRELOAD=/usr/lib/i386-linux-gnu/libnss_wrapper.so
fi

# Create server startup parameters config file
cat > ${SERVER_PARAM_FILE} << EOF
// ********************************************************************
// *                                                                  *
// *    Server Startup Parameters Config File                         *
// *                                                                  *
// *    This file is automatically generated by the panel.            *
// *    Do not edit this file. Any changes made will be discarded!    *
// *                                                                  *
// ********************************************************************
-name=server
-ip=0.0.0.0
-port=${SERVER_PORT}
-cfg=basic.cfg
-config=server.cfg
-mod=${clientMods}
-serverMod=${SERVERMODS}
$( [[ "$PARAM_LOADMISSIONTOMEMORY" == "1" ]] && echo "-loadMissionToMemory" )
$( [[ "$PARAM_AUTOINIT" == "1" ]] && echo "-autoInit" )
$( [[ "$PARAM_FILEPATCHING" == "1" ]] && echo "-filePatching" )
-limitFPS=${PARAM_LIMITFPS}
$( [[ "$PARAM_NOLOGS" == "1" ]] && echo "-noLogs" )
EOF

# Create HC startup parameters config file
cat > ${HC_PARAM_FILE} << EOF
// ********************************************************************
// *                                                                  *
// *    Headless Client Startup Parameters Config File                *
// *                                                                  *
// *    This file is automatically generated by the panel.            *
// *    Do not edit this file. Any changes made will be discarded!    *
// *                                                                  *
// ********************************************************************
-client
-ip=127.0.0.1
-port=${SERVER_PORT}
-password=${SERVER_PASSWORD}
-mod=${clientMods}
$( [[ "$PARAM_FILEPATCHING" == "1" ]] && echo "-filePatching" )
-limitFPS=${PARAM_LIMITFPS}
EOF

# Start Headless Clients if applicable
if [[ ${HC_NUM} > 0 ]]; then
    echo -e "\n${GREEN}[STARTUP]:${NC} Starting ${CYAN}${HC_NUM}${NC} Headless Client(s)."
    for i in $(seq ${HC_NUM}); do
        if [[ ${HC_HIDE} == "1" ]]; then
            ./${SERVER_BINARY} -par=${HC_PARAM_FILE} > /dev/null 2>&1 &
        else
            ./${SERVER_BINARY} -par=${HC_PARAM_FILE} &
        fi
        echo -e "${GREEN}[STARTUP]:${CYAN} Headless Client $i${NC} launched."
    done
fi

# Replace Startup Command variables
modifiedStartup=`eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')`
# Convert PAR file to single-line string
serverParams=$(sed '/^\/\//d' ${SERVER_PARAM_FILE} | tr '\n' ' ' | tr -s ' ')

# Start the Server
echo -e "\n${GREEN}[STARTUP]:${NC} Starting server with the following startup parameters:"
echo -e "${CYAN}${modifiedStartup/-par=${SERVER_PARAM_FILE}/$serverParams}${NC}\n"
if [[ "$PARAM_NOLOGS" == "1" ]]; then
    ${modifiedStartup}
else
    ${modifiedStartup} 2>&1 | tee -a "$logFile"
fi

# Check server exit code for errors
exitCode=$?
if [[ $exitCode -ne 0 && $exitCode -ne 130 ]]; then # Exit code 130 is SIGTERM
    echo -e "\n${RED}[SERVER_ERR]: The server exited unexpectedly with code ${exitCode}!${NC}\n"
    exit 1
fi
