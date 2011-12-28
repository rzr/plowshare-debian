#!/bin/bash -e
#
# Download files from file sharing servers
# Copyright (c) 2010-2011 Plowshare team
#
# Output filenames are printed on standard output (one per line).
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.


VERSION="GIT-snapshot"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowdown version
VERBOSE,v:,verbose:,LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
CHECK_LINK,c,check-link,,Check if a link exists and return
MARK_DOWN,m,mark-downloaded,,Mark downloaded links in (regular) FILE arguments
NOOVERWRITE,x,no-overwrite,,Do not overwrite existing files
OUTPUT_DIR,o:,output-directory:,DIRECTORY,Directory where files will be saved
TEMP_DIR,,temp-directory:,DIRECTORY,Directory where files are temporarily downloaded
LIMIT_RATE,l:,limit-rate:,SPEED,Limit speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
INTERFACE,i:,interface:,IFACE,Force IFACE interface
TIMEOUT,t:,timeout:,SECS,Timeout after SECS seconds of waits
MAXRETRIES,r:,max-retries:,N,Set maximum retries for captcha solving. 0 means no retry. Default is infinite.
CAPTCHA_METHOD,,captchamethod:,METH, Force specific captcha solving method. Available: prompt, none.
CAPTCHA_TRADER,,captchatrader:,USER:PASSWORD,CaptchaTrader account
NOEXTRAWAIT,,no-extra-wait,,Do not wait on uncommon events (unavailable file, unallowed parallel downloads, ...)
GLOBAL_COOKIES,,cookies:,FILE,Force using specified cookies file
GET_MODULE,,get-module,,Get module(s) for URL(s) and exit
DOWNLOAD_APP,,run-download:,COMMAND,run down command (interpolations: %url, %filename, %cookies) for each link
DOWNLOAD_INFO,,download-info-only:,STRING,Echo string (interpolations: %url, %filename, %cookies) for each link
NO_MODULE_FALLBACK,,fallback,,If no module is found for link, simply download it (HTTP GET)
NO_CURLRC,,no-curlrc,,Do not use curlrc config file
"


# - Results are similar to "readlink -f" (available on GNU but not BSD)
# - If '-P' flags (of cd) are removed directory symlinks won't be
#   translated (but results are correct too)
# - Assume that $1 is correct (don't check for infinite loop)
absolute_path() {
    local SAVED_PWD="$PWD"
    TARGET="$1"

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR="$PWD"
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR="$TARGET"
    fi

    cd -P "$DIR"
    TARGET="$PWD"
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Guess if item is a generic URL (a simple link string) or a text file with links.
# $1: single URL or file (containing links)
process_item() {
    local ITEM="$1"

    if match_remote_url "$ITEM"; then
        echo "url|$(echo "$ITEM" | strip | uri_encode)"
    elif [ -f "$ITEM" ]; then
        case "${ITEM##*.}" in
          zip|rar|tar|gz|7z|bz2|mp3|avi)
              log_error "Skip: '$ITEM' seems to be a binary file, not a list of links"
              ;;
          *)
              # Discard empty lines and comments
              sed -ne "s,^[[:space:]]*\([^ #].*\)[[:space:]]*$,file|\1,p" "$ITEM" | \
                  strip | uri_encode
              ;;
        esac
    else
        log_error "Skip: cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage
usage() {
    echo "Usage: plowdown [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]"
    echo
    echo "  Download files from file sharing servers."
    echo "  Available modules:" $(echo "$MODULES" | tr '\n' ' ')
    echo
    echo "Global options:"
    echo
    print_options "$OPTIONS" '  '
    print_module_options "$MODULES" 'DOWNLOAD'
}

# Mark status of link (inside file or to stdout). See --mark-downloaded switch.
mark_queue() {
    local TYPE=$1
    local MARK_DOWN=$2
    local FILELIST=$3
    local URL=$4
    local TEXT=$5
    local TAIL=$6

    test -z "$MARK_DOWN" && return 0

    if test "$TYPE" = "file"; then
        if test -w "$FILELIST"; then
            local URL_DECODED=$(echo "$URL" | uri_decode)

            TAIL=${TAIL//,/\\,}
            URL=${URL_DECODED//,/\\,}

            sed -i -e "s,^[[:space:]]*\($URL\)[[:space:]]*$,#$TEXT \1$TAIL," "$FILELIST" &&
                log_notice "link marked in file: $FILELIST (#$TEXT)" ||
                log_error "failed marking link in file: $FILELIST (#$TEXT)"
        else
            log_notice "error: can't mark link, no write permission ($FILELIST)"
        fi
    else
        echo "#${TEXT} $URL"
    fi
}

# Create an alternative filename
# Pattern is filename.1
#
# $1: filename (with or without path)
# stdout: non existing filename
create_alt_filename() {
    local FILENAME="$1"
    local COUNT=1

    while [ "$COUNT" -le 99 ]; do
        if [ ! -f "${FILENAME}.$COUNT" ]; then
            FILENAME="${FILENAME}.$COUNT"
            break
        fi
        (( ++COUNT ))
    done
    echo "$FILENAME"
}

# Example: "MODULE_FILESONIC_DOWNLOAD_RESUME=no"
module_config_resume() {
    MODULE=$1
    VAR="MODULE_$(echo $MODULE | uppercase)_DOWNLOAD_RESUME"
    test "${!VAR}" = "yes"
}

# Example: "MODULE_FILESONIC_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no"
module_config_need_cookie() {
    MODULE=$1
    VAR="MODULE_$(echo $MODULE | uppercase)_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE"
    test "${!VAR}" = "yes"
}

# Fake download module function. See --fallback switch.
# $1: cookie file (unused here)
# $2: unknown url
# stdout: $2
module_null_download() {
    echo "$2"
}

download() {
    local MODULE=$1
    local DURL=$2
    local DOWNLOAD_APP=$3
    local TYPE=$4
    local MARK_DOWN=$5
    local TEMP_DIR=$6
    local OUTPUT_DIR=$7
    local CHECK_LINK=$8
    local TIMEOUT=$9
    local MAXRETRIES=${10}
    local NOEXTRAWAIT=${11}
    local DOWNLOAD_INFO=${12}
    shift 12

    FUNCTION=${MODULE}_download
    log_notice "Starting download ($MODULE): $DURL"
    timeout_init $TIMEOUT

    while true; do
        local DRETVAL=0
        local COOKIES=$(create_tempfile)

        # Use provided cookie
        if [ -s "$GLOBAL_COOKIES" ]; then
            cat "$GLOBAL_COOKIES" > "$COOKIES"
        fi

        if test -z "$CHECK_LINK"; then
            local DRESULT=$(create_tempfile)
            local TRY=0

            while true; do
                $FUNCTION "$@" "$COOKIES" "$DURL" >$DRESULT || DRETVAL=$?

                if [ $DRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                    read AWAIT <$DRESULT

                    # --no-extra-wait option specified
                    test -n "$NOEXTRAWAIT" && break

                    if [ -z "$AWAIT" ]; then
                        log_debug "arbitrary wait"
                    fi
                    wait ${AWAIT:-60} seconds || {
                        DRETVAL=$?;
                        break;
                    }

                elif [ $DRETVAL -ne $ERR_CAPTCHA ]; then
                    break
                # [ $DRETVAL -eq $ERR_CAPTCHA ]
                elif [ "$CAPTCHA_METHOD" = 'none' ]; then
                    log_debug "captcha method set to none, abort"
                    break
                fi

                (( ++TRY ))
                if [ -n "$MAXRETRIES" ]; then
                    if [[ "$MAXRETRIES" -eq 0 ]]; then
                        log_debug "no retry explicitly requested"
                        break
                    elif [ "$MAXRETRIES" -lt "$TRY" ]; then
                        DRETVAL=$ERR_MAX_TRIES_REACHED
                        break
                    fi
                    log_notice "Starting download ($MODULE): retry ${TRY}/$MAXRETRIES"
                else
                    log_notice "Starting download ($MODULE): retry $TRY"
                fi
                DRETVAL=0
            done

            { read FILE_URL; read FILENAME; } <$DRESULT || true
            rm -f "$DRESULT"
        else
            $FUNCTION "$@" "$COOKIES" "$DURL" >/dev/null || DRETVAL=$?

            if [ $DRETVAL -eq 0 -o \
                    $DRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE -o \
                    $DRETVAL -eq $ERR_LINK_NEED_PERMISSIONS -o \
                    $DRETVAL -eq $ERR_LINK_PASSWORD_REQUIRED ]; then
                log_notice "Link active: $DURL"
                echo "$DURL"
                rm -f "$COOKIES"
                break
            fi
        fi

        case "$DRETVAL" in
            0)
                ;;
            $ERR_LOGIN_FAILED)
                log_notice "Login process failed. Bad username/password or unexpected content"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_LINK_TEMP_UNAVAILABLE)
                log_notice "Warning: file link is alive but not currently available, try later"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_LINK_PASSWORD_REQUIRED)
                log_notice "You must provide a password"
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$DURL" "PASSWORD"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_LINK_NEED_PERMISSIONS)
                log_notice "Insufficient permissions (premium link?)"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_LINK_DEAD)
                log_notice "Link is not alive: file not found"
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$DURL" "NOTFOUND"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_MAX_WAIT_REACHED)
                log_notice "Delay limit reached (${FUNCTION})"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_MAX_TRIES_REACHED)
                log_notice "Retry limit reached (${FUNCTION})"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_CAPTCHA)
                log_notice "Error: decoding captcha (${FUNCTION})"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            $ERR_SYSTEM)
                log_notice "System failure (${FUNCTION})"
                rm -f "$COOKIES"
                return $DRETVAL
                ;;
            *)
                log_error "failed inside ${FUNCTION}() [$DRETVAL]"
                rm -f "$COOKIES"
                return $ERR_FATAL
                ;;
        esac

        # Sanity check
        if test -z "$FILE_URL"; then
            log_error "Output URL expected"
            rm -f "$COOKIES"
            return $ERR_FATAL
        fi

        log_notice "File URL: $FILE_URL"

        if test -z "$FILENAME"; then
            FILENAME=$(basename_file "${FILE_URL%%\?*}" | tr -d '\r\n' | \
                html_to_utf8 | uri_decode)
        fi

        # On most filesystems, maximum filename length is 255
        # http://en.wikipedia.org/wiki/Comparison_of_file_systems
        if [ "${#FILENAME}" -ge 255 ]; then
            FILENAME="${FILENAME:0:254}"
            log_debug "filename is too long, truncating it"
        fi
        log_notice "Filename: $FILENAME"

        DRETVAL=0

        # External download or curl regular download
        if test "$DOWNLOAD_APP"; then
            test "$OUTPUT_DIR" && FILENAME="$OUTPUT_DIR/$FILENAME"
            COMMAND=$(echo "$DOWNLOAD_APP" |
                replace "%url" "$FILE_URL" |
                replace "%filename" "$FILENAME" |
                replace "%cookies" "$COOKIES")
            log_notice "Running command: $COMMAND"
            eval $COMMAND || DRETVAL=$?
            test "$COOKIES" && rm -f "$COOKIES"
            log_notice "Command exited with retcode: $DRETVAL"
            test $DRETVAL -eq 0 || break

        elif test "$DOWNLOAD_INFO"; then
            local OUTPUT_COOKIES=""
            if match '%cookies' "$DOWNLOAD_INFO"; then
                # Keep temporary cookie
                OUTPUT_COOKIES="$(dirname "$COOKIES")/$(basename_file $0).cookies.$$.txt"
                cp "$COOKIES" "$OUTPUT_COOKIES"
            fi
            echo "$DOWNLOAD_INFO" |
                replace "%url" "$FILE_URL" |
                replace "%filename" "$FILENAME" |
                replace "%cookies" "$OUTPUT_COOKIES"

        else
            local FILENAME_TMP FILENAME_OUT

            # Temporary download path
            if test "$TEMP_DIR"; then
                FILENAME_TMP="$TEMP_DIR/$FILENAME"
            elif test "$OUTPUT_DIR"; then
                FILENAME_TMP="$OUTPUT_DIR/$FILENAME"
            else
                FILENAME_TMP="$FILENAME"
            fi

            # Final path
            if test "$OUTPUT_DIR"; then
                FILENAME_OUT="$OUTPUT_DIR/$FILENAME"
            else
                FILENAME_OUT="$FILENAME"
            fi

            CURL_ARGS=()
            FILE_URL=$(echo "$FILE_URL" | uri_encode)

            [ -z "$NOOVERWRITE" ] && \
                module_config_resume "$MODULE" && CURL_ARGS=("${CURL_ARGS[@]}" "-C -")
            module_config_need_cookie "$MODULE" && CURL_ARGS=("${CURL_ARGS[@]}" "-b $COOKIES")

            if [ -n "$NOOVERWRITE" -a -f "$FILENAME_OUT" ]; then
                if [ "$FILENAME_OUT" = "$FILENAME_TMP" ]; then
                    FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                    FILENAME_TMP="$FILENAME_OUT"
                else
                    FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                fi
            fi

            CODE=$(curl_with_log ${CURL_ARGS[@]} -w '%{http_code}' --fail --globoff \
                    -o "$FILENAME_TMP" "$FILE_URL") || DRETVAL=$?

            rm -f "$COOKIES"

            if [ "$DRETVAL" -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                # Obtained HTTP return status are 200 and 206
                if module_config_resume "$MODULE"; then
                    log_notice "Partial content downloaded, recall download function"
                    continue
                fi
                DRETVAL=$ERR_NETWORK

            elif [ "$DRETVAL" -eq $ERR_NETWORK ]; then
                if [ "$CODE" = 503 ]; then
                    log_error "Unexpected HTTP code ${CODE}, retry after a safety wait"
                    wait 120 seconds || return
                    continue
                fi

            elif [ "$DRETVAL" -ne 0 ]; then
                return $DRETVAL
            fi

            if [ "$CODE" = 416 ]; then
                # If module can resume transfer, we assume here that this error
                # means that file have already been downloaded earlier.
                # We should do a HTTP HEAD request to check file length but
                # a lot of hosters do not allow it.
                if module_config_resume "$MODULE"; then
                    log_error "Resume error (bad range), skip download"
                else
                    log_error "Resume error (bad range), restart download"
                    rm -f "$FILENAME_TMP"
                    continue
                fi
            elif [ "${CODE:0:2}" != 20 ]; then
                log_error "Unexpected HTTP code ${CODE}, restart download"
                continue
            fi

            if test "$FILENAME_TMP" != "$FILENAME_OUT"; then
                log_notice "Moving file to output directory: ${OUTPUT_DIR:-.}"
                mv -f "$FILENAME_TMP" "$FILENAME_OUT"
            fi

            # Echo downloaded file (local) path
            echo "$FILENAME_OUT"

        fi
        mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$DURL" "" "|$FILENAME_OUT"
        break
    done
    return 0
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'download') || exit $?
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Get configuration file options
process_configfile_options 'Plowdown' "$OPTIONS"

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options 'plowdown' "$OPTIONS$MODULE_OPTIONS" "$@")"

# Verify verbose level
if [ -n "$QUIET" ]; then
    VERBOSE=0
elif [ -n "$VERBOSE" ]; then
    [ "$VERBOSE" -gt "4" ] && VERBOSE=4
else
    VERBOSE=2
fi

test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }
test $# -lt 1 && { usage; exit $ERR_FATAL; }

log_report_info
log_report "plowdown version $VERSION"

if [ -n "$TEMP_DIR" ]; then
    TEMP_DIR=$(echo "$TEMP_DIR" | sed -e "s/\/$//")
    log_notice "Temporary directory: $TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    if [ ! -w "$TEMP_DIR" ]; then
        log_error "error: no write permission"
        exit $ERR_FATAL
    fi
fi

if [ -n "$OUTPUT_DIR" ]; then
    OUTPUT_DIR=$(echo "$OUTPUT_DIR" | sed -e "s/\/$//")
    log_notice "Output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    if [ ! -w "$OUTPUT_DIR" ]; then
        log_error "error: no write permission"
        exit $ERR_FATAL
    fi
fi

if [ -n "$GLOBAL_COOKIES" ]; then
    if [ ! -f "$GLOBAL_COOKIES" ]; then
        log_error "error: can't find cookies file"
        exit $ERR_FATAL
    fi
    log_notice "plowdown: using provided cookies file"
fi

if [ -n "$CAPTCHA_METHOD" ]; then
    if ! captcha_method_translate "$CAPTCHA_METHOD"; then
        log_error "error: unknown captcha method: $CAPTCHA_METHOD"
        exit $ERR_FATAL
    fi
    log_notice "plowdown: force captcha method ($CAPTCHA_METHOD)"
fi

# Print chosen options
[ -n "$NOOVERWRITE" ] && log_debug "plowdown: --no-overwrite selected"
[ -n "$NOEXTRAWAIT" ] && log_debug "plowdown: --no-extra-wait selected"
[ -n "$CAPTCHA_TRADER" ] && log_debug "plowdown: --captchatrader selected"

set_exit_trap

RETVALS=()
for ITEM in "$@"; do
    for INFO in $(process_item "$ITEM"); do
        IFS="|" read TYPE URL <<< "$INFO"

        MODULE=$(get_module "$URL" "$MODULES")
        if [ -z "$MODULE" ]; then
            if match_remote_url "$URL"; then
                # Test for simple HTTP 30X redirection
                # (disable User-Agent because some proxy can fake it)
                log_debug "No module found, try simple redirection"

                URL_TEMP=$(curl --user-agent '' -i "$URL" | grep_http_header_location) || true

                if [ -n "$URL_TEMP" ]; then
                    URL="$URL_TEMP"
                    MODULE=$(get_module "$URL" "$MODULES")
                elif test "$NO_MODULE_FALLBACK"; then
                    log_notice "No module found, do a simple HTTP GET as requested"
                    MODULE='module_null'
                fi
            fi
        fi

        if [ -z "$MODULE" ]; then
            log_error "Skip: no module for URL ($URL)"
            RETVALS=(${RETVALS[@]} $ERR_NOMODULE)
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" "NOMODULE"
            continue
        elif test "$GET_MODULE"; then
            echo "$MODULE"
            continue
        fi

        # Get configuration file module options
        process_configfile_module_options 'Plowdown' "$MODULE" 'DOWNLOAD'

        download "$MODULE" "$URL" "$DOWNLOAD_APP" "$TYPE" "$MARK_DOWN" \
            "$TEMP_DIR" "$OUTPUT_DIR" "$CHECK_LINK" "$TIMEOUT" "$MAXRETRIES" \
            "$NOEXTRAWAIT" "$DOWNLOAD_INFO" "${UNUSED_OPTIONS[@]}" || \
                RETVALS=(${RETVALS[@]} "$?")
    done
done

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
