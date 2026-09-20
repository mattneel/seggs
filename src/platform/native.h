#ifndef SEGGS_NATIVE_H
#define SEGGS_NATIVE_H
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <stdio.h>
#ifndef _WIN32
// For realpath, which resolves symlinks before a save replaces the target, and
// for the POSIX calls the save-gate tests need to build their own fixtures.
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#endif
