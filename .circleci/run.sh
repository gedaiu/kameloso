#!/bin/bash

set -ux #eo pipefail

install_deps() {
    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list \
        -O /etc/apt/sources.list.d/d-apt.list
    sudo apt update

    # fingerprint 0xEBCF975E5BA24D5E
    sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring
    sudo apt update
    sudo apt install dmd-compiler dub gdb

    #sudo apt install ldc
}

separate_dmd_build() {
    dmd -g -c -of=arsd.o arsd/*.d "$@" || return 1
    dmd -g -c -of=base.o kameloso/*.d "$@" || return 1
    dmd -g -c -of=plugins.o kameloso/plugins/*.d "$@" || return 1
}

separate_dmd_link() {
    ( [ ! -e arsd.o ] || [ ! -e base.o ] || [ ! -e plugins.o ] ) && return 1
    gcc -g -o "$1" arsd.o base.o plugins.o -ldruntime -lphobos2 -lpthread
    mv "$1" ../artifacts/
}

separate_dmd() {
    local FAILED

    mkdir -p artifacts
    cd source

    separate_dmd_build -debug -unittest -version=Colours || FAILED=1
    separate_dmd_link "dmd-unittest-colour"
    separate_cleanup
    ../artifacts/dmd-unittest-colour

    separate_dmd_build -debug -unittest || FAILED=1
    separate_dmd_link "dmd-unittest-vanilla"
    separate_cleanup
    ../artifacts/dmd-unittest-vanilla

    separate_dmd_build -debug -version=Colours || FAILED=1
    separate_dmd_link "dmd-debug-colour"
    separate_cleanup

    separate_dmd_build -debug || FAILED=1
    separate_dmd_link "dmd-debug-vanilla"
    separate_cleanup

    #separate_dmd_build -version=Colours || FAILED=1
    #separate_dmd_link "dmd-plain-colour"
    #separate_cleanup

    #separate_dmd_build || FAILED=1
    #separate_dmd_link "dmd-plain-vanilla"
    #separate_cleanup

    #separate_dmd_build -release -inline -version=Colours || FAILED=1
    #separate_dmd_link "dmd-release-colour"
    #separate_cleanup

    #separate_dmd_build -release -inline || FAILED=1
    #separate_dmd_link "dmd-release-vanilla"
    #separate_cleanup

    cd ..

    return ${FAILED:-0}
}


separate_ldc_build() {
    ldc -g -c -of=arsd.o arsd/*.d "$@" || return 1
    ldc -g -c -of=base.o kameloso/*.d "$@" || return 1
    ldc -g -c -of=plugins.o kameloso/plugins/*.d "$@" || return 1
}

separate_ldc_link() {
    ( [ ! -e arsd.o ] || [ ! -e base.o ] || [ ! -e plugins.o ] ) && return 1
    gcc -g -o "$1" arsd.o base.o plugins.o \
        -ldl -lm -lLLVM -lphobos2-ldc-debug -ldruntime-ldc-debug -lpthread
    mv "$1" ../artifacts/
}

separate_ldc() {
    local FAILED

    mkdir -p artifacts
    cd source

    separate_ldc_build -unittest -d-version=Colours || FAILED=1
    separate_ldc_link "ldc-unittest-colour"
    separate_cleanup
    [ -e ../artifacts/ldc-unittest-colour ] && ../artifacts/ldc-unittest-colour

    separate_ldc_build -unittest || FAILED=1
    separate_ldc_link "ldc-unittest-vanilla"
    separate_cleanup
    [ -e ../artifacts/ldc-unittest-vanilla ] && ../artifacts/ldc-unittest-vanilla

    separate_ldc_build -d-debug -d-version=Colours || FAILED=1
    separate_ldc_link "ldc-debug-colour"
    separate_cleanup

    separate_ldc_build -d-debug || FAILED=1
    separate_ldc_link "ldc-debug-vanilla"
    separate_cleanup

    #separate_ldc_build -d-version=Colours || FAILED=1
    #separate_ldc_link "ldc-plain-colour"
    #separate_cleanup

    #separate_ldc_build || FAILED=1
    #separate_ldc_link "ldc-plain-vanilla"
    #separate_cleanup

    #separate_ldc_build -release -d-version=Colours || FAILED=1
    #separate_ldc_link "ldc-release-colour"
    #separate_cleanup

    #separate_ldc_build -release || FAILED=1
    #separate_ldc_link "ldc-release-vanilla"
    #separate_cleanup

    cd ..

    return ${FAILED:-0}
}

separate_cleanup() {
    rm -f arsd.o base.o plugins.o
}


# execution start

case "$1" in
    install-deps)
        install_deps;
        ;;
    build)
        separate_dmd || FAILED=1
        separate_ldc || FAILED=1
        [ ${FAILED:-0} -eq 1 ] && exit 1
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
