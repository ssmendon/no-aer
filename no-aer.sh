#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2024  Sohum Mendon
#
# Credit to GitHub user flisboac who posted this Gist:
# <https://gist.github.com/flisboac/5a0711201311b63d23b292110bb383cd>
#
# Credit to distrobox for inspiration regarding script 
# layout.

# shellcheck enable=all
#
# I don't want to put braces everywhere they aren't required, so:
# shellcheck disable=SC2250

set -o errexit
set -o nounset

# Program metadata
version="0.1.0"

# Defaults
dryrun=0
verbose=0
word_len=4
register=CAP_EXP+0x8.w

printf >&2 "WARN: This script could damage your PCI devices. There is no warranty.\n"

if [ "$(id -ru || true)" -ne 0 ]; then
    printf >&2 "WARN: Not running as root. This script is unlikely to work.\n"
fi

if ! command -v setpci >/dev/null; then
    printf >&2 "Unable to locate: setpci\n"
    exit 1
fi

show_help()
{
    cat << EOF
no-aer version: ${version}

Masks PCI device registers inside of DEVCTL
to silence correctable error generation for
badly behaving devices.

Usage:

    no-aer [<options>] [--] <device>...

General options:
--help             Print this message
--dry              Simulate, but don't write
--verbose          Print additional debugging information

Setting commands:
<device>:          -s SLOT
                   -d DEVICE
                   As defined for setpci, they are
                   passed unmodified and processed
                   one after another.
EOF
}

while :; do
    case $1 in
        --help)
            show_help
            exit 0
            ;;
        --dry)
            dryrun=1
            shift
            ;;
        --verbose)
            verbose=1
            shift
            ;;
        -s | -d) # Start of setpci options.
            break
            ;;
        --) # End of options.
            shift
            break
            ;;
        *) # Unrecognized option.
            printf >&2 "ERROR: Invalid argument '%s'\n\n" "$1"
            show_help
            exit 1
            ;;
    esac
done

# Some simple argument validation:
# we must have more than one device
if [ "$#" -lt 2 ]; then
    printf >&2 "ERROR: Expected a setpci device, got '%s'\n" "$1"
    exit 1
fi

# we must have an even number of remaining arguments
if [ $(( $# & 1 )) -ne 0 ]; then
    printf >&2 "ERROR: Expected '-s' or '-d' pairs, got '%d' remaining args\n" "$#"
    exit 1
fi

while [ "$#" -ge 2 ]; do

    flag=''
    value=''

    case $1 in
        -s | -d)
            flag="$1"
            shift
            ;;
        *) # Not a slot or device filter flag, so abort.
            printf >&2 "ERROR: Unexpected setpci flag '%s'\n" "$1"
            exit 1
            ;;
    esac

    case $1 in
        -*) # Not a slot or device filter, so abort.
            printf >&2 "ERROR: Unexpected setpci flag '%s'\n" "$1"
            exit 1
            ;;
        *)  # May not be right, but setpci should error out below.
            
            if [ -z "$1" ]; then
                printf >&1 "ERROR: Empty pci filter after '%s'\n" "$flag"
                exit 1
            fi

            value="$1"
            shift
            ;;
    esac

    # Read the given flag, value at the DEVCTL register.
    #
    # while reading a word using 'setpci', the output will
    # be a hexadecimal digit formatted like:
    #
    #  002f
    #
    devctl_original="$(setpci -D "$flag" "$value" "$register")"
    [ "${verbose}" -ne 0 ] && printf 2>&1 "VERBOSE: devctl_original=%s\n" "$devctl_original"
    if [ ${#devctl_original} -ne "${word_len}" ]; then
        printf 2>&1 "Unexpected number of hexadecimal digits in word: %s\n" "$devctl_original"
        exit 1
    fi

    # Compute the mask, and skip if there would be no change.
    devctl_masked=$(printf "%0${word_len}x" "$((~0x1 & 0x$devctl_original))")
    [ "${verbose}" -ne 0 ] && printf 2>&1 "VERBOSE: devctl_masked=%s\n" "$devctl_masked"
    if [ "$devctl_masked" = "$devctl_original" ]; then
        printf 2>&1 "New value for DEVCTL is the same as original: %s\n" "$devctl_masked"
        printf 2>&1 "\tSkipping '%s %s'\n" "$flag" "$value"
        continue
    fi

    ### WRITING TO PCI REGISTERS    ###
    if [ "${dryrun}" -ne 0 ]; then
        setpci -D -v "$flag" "$value" "${register}=0x${devctl_masked}"
    else
        [ "${verbose}" -ne 0 ] && printf 2>&1 "VERBOSE: Writing now!\n"
        setpci -v "$flag" "$value" "${register}=0x${devctl_masked}"
    fi
    ### END WRITING TO PCI REGISTERS ###

    # On to the next pair...
done