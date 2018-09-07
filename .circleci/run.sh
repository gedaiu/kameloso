#!/bin/bash

set -uexo pipefail

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

debug() {
    gdb --batch --ex "run" --args dub test --compiler="$1" --build-mode=singleFile \
        -c colours+web
    gdb --batch --ex "run" --args dub test --nodeps --compiler="$1" --build-mode=singleFile \
        -c vanilla
    gdb --batch --ex "run" --args dub build --nodeps --compiler="$1" --build-mode=singleFile \
        -b debug -c colours+web
    gdb --batch --ex "run" --args dub build --nodeps --compiler="$1" --build-mode=singleFile \
        -b debug -c vanilla
    gdb --batch --ex "run" --args dub build --nodeps --compiler="$1" --build-mode=singleFile \
        -b plain -c colours+web
    gdb --batch --ex "run" --args dub build --nodeps --compiler="$1" --build-mode=singleFile \
        -b plain -c vanilla
}

build() {
    mkdir -p artifacts

    dub test --compiler="$1" --build-mode=singleFile -c vanilla
    dub test --nodeps --compiler="$1" --build-mode=singleFile -c colours+web

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b debug -c colours+web || true
    mv kameloso artifacts/kameloso || true

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b debug -c vanilla || true
    mv kameloso artifacts/kameloso-vanilla || true

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b plain -c colours+web || true
    test -e kameloso && mv kameloso artifacts/kameloso-plain || true

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b plain -c vanilla || true
    test -e kameloso && mv kameloso artifacts/kameloso-plain-vanilla || true
}

# execution start

case "$1" in
    install-deps)
        install_deps;
        ;;
    build)
        #build dmd;
        #build ldc2;  # doesn't support single build mode
        debug dmd;
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
