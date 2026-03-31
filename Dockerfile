FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential nasm yasm cmake meson ninja-build pkg-config \
    autoconf automake libtool git curl xz-utils python3 \
    mingw-w64 mingw-w64-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ffmpeg
