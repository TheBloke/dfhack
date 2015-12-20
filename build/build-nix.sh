#!/bin/bash

# This script implements steps 7 and 8 of the OSX compilation procedure described in Compile.rst
# It provides command line arguments to specify the source of GCC, the GCC version, and parallel compilation (-j X)
# By default it will install to $BUILD_DIR, and will create it if it doesn't already exist.

#
# Defaults
#

BUILD_TYPE=Release
BUILD_DIR="../build-osx"
BUILD_DOCS=OFF

GCC_MIN=4.5 GCC_MAX=6 # Will abort if requsted GCC_VER is < MIN or >= MAX.
DEFAULT_GCC_VER=4.5
PARALLEL_PROC=1

# Internal variables
GCC_VER="$DEFAULT_GCC_VER"
gcc_source=0
do_docs=0
do_clean=0
do_confirm=0
do_quiet=0
do_silent=0

colors_terminal=$(tput colors) # color capability of terminal
colors_reset=$(tput sgr0)      # reset code
color_bold=$(tput bold)
color_red=$(tput setaf 1)
color_green=$(tput setaf 2)
color_yellow=$(tput setaf 3)
color_blue=$(tput setaf 4)
color_purple=$(tput setaf 5)

#
# General functions
#

read_confirmation() {
  read -n 1 -r -s
  [[ $REPLY =~ ^[Yy]$ ]] && return 0 || return 1
}

colorise_string() { color="$1" msg="$2"
  (( colors_terminal < 8 )) && { echo -nE "$msg" ; return ; }
  case "$color" in
    bold)   color_code="$color_bold"    ;;
    red)    color_code="$color_red"     ;;
    green)  color_code="$color_green"   ;;
    yellow) color_code="$color_yellow"  ;;
    blue)   color_code="$color_blue"    ;;
    purple) color_code="$color_purple"  ;;
  esac
  echo -nE "${color_code}${msg}${colors_reset}"
}

print_msg() { message="$1" color="$2"
  (( do_silent == 1 )) && return 0 # Print nothing when silenced
  [[ ! -z "$color" ]]  && message="$(colorise_string "$color" "$message")"
  printf "%s\n" "$message"
}

log_msg() { message="$1" color="$2"
  date="$(colorise_string bold "$(date '+%Y-%m-%d %H:%M:%S')")"
  [[ ! -z "$color" ]] && message="$(colorise_string "$color" "$message")"
  print_msg "$(printf "[%s]:\t%b%s\n" "$date" "$message")" none
}

log_build_msg() { message="$1"
  case "$message" in
    *Building*CXX*)          output_color=yellow  ;;
    *warning:*|*error:*)     output_color=red     ;;
    *Scanning*dependencies*) output_color=purple  ;;
    *Up-to-date*)            output_color=none    ;;
    *Installing*)            output_color=yellow  ;;
    *)                       output_color=yellow  ;;
  esac
  log_msg "$message" $output_color
}

usage_print() { cat="$1" arg="$2" message="$3"
  arg=$(colorise_string bold "$arg")
  message=$(colorise_string blue "$message")
  if [[ "$cat" == "arg" ]]; then
    printf "\t%-30s %-60s\n" "$arg" "$message"
  else
    printf "\t%s\n\t\t%s\n" "$arg" "$message"
  fi
}

script_error() { message="$1" action="$2"
  log_msg "ERROR: ${message}" red
  [[ "$action" == "usage" ]] && usage
  exit 1
}

usage() {
  echo
  print_msg "Usage: $0 [-dir build_dir] [-gcc version] [-j #] [-build <type>] [brew|port] [clean] [quiet] [docs] <DF install directory>" green
  usage_print arg "-dir <directory>"   "build in specified directory instead of the default $BUILD_DIR"
  usage_print arg "-gcc <ver>"         "use GCC version <ver> instead of the default $DEFAULT_GCC_VER"
  usage_print arg "-j <#>"             "build with # parallel processes, make -j# (default = $PARALLEL_PROC)"
  usage_print arg "-build <type>"      "Change build type from default of $BUILD_TYPE to one of Release|Debug|RelWithDebInfo"
  usage_print arg "docs"               "build DFHack documentation as well (requires Python Sphinx)"
  usage_print arg "brew"               "use GCC $GCC_VER from Homebrew (brew install ..)"
  usage_print arg "port"               "use GCC $GCC_VER from MacPorts (sudo port install ..)"
  usage_print arg "clean"              "delete $BUILD_DIR before compiling to force a full rebuild, not incremental."
  usage_print arg "confirm"            "ask for confirmation before running build (incompatible with silent mode.)"
  usage_print arg "quiet"              "hide build output, displaying only messages from this script and build success/failure at the end."
  usage_print arg "silent"             "display nothing at all (will fail if confirmation is required or requested with 'confirm')"
  print_msg "Usage Examples:" green
  usage_print ex "$0 brew clean quiet /User/Urist/df_osx"  "Use default GCC $GCC_VER from Homebrew, installing to /User/Urist/df_osx, don't output cmake/make logs"
  usage_print ex "$0 port -gcc 4.9 -par 4 ~/games/df_osx"  "Use GCC 4.9 from MacPorts, build in parallel with -j 4, installing to ~/games/df_osx"
  usage_print ex "$0 -gcc 5 brew clean ~/games/df_osx"     "Use GCC 5 from Brew, clean the install directory first, install to ~/games/df_osx"
  usage_print ex "$0 brew confirm clean ~/games/df_osx"    "Use GCC $GCC_VER from Brew, clean first, ask for confirmation before build, install to ~/games/df_osx"
}

#
# Start of script
#

command_line="$@"  # preserve this for later printing, once we know if we're silenced or not.

# Argument checks
(( $# < 1 ))  && script_error "Not enough arguments." usage
(( $# > 14 )) && script_error "Too many arguments." usage

while (( $# > 0 )); do # Command line arguments loop.
  case "$1" in
    -dir)
      BUILD_DIR="$2"
      shift
      ;;
    -gcc)
      GCC_VER="$2"
      if [[ "$GCC_VER" == *[^0-9.]* ]] || (( $(bc <<< "$GCC_VER < $GCC_MIN") )) || (( $(bc <<< "$GCC_VER >= $GCC_MAX") )); then
        script_error "Invalid GCC version specified: $GCC_VER"
      fi
      shift
      ;;
    -build)
      case "$2" in
        [Rr][Ee][Ll][Ee][Aa][Ss][Ee]) BUILD_TYPE=Release ;;
        [Dd][Ee][Bb][Uu][Gg]) BUILD_TYPE=Debug ;;
        [Rr][Ee][Ll][Ww][Ii][Tt][Hh][Dd][Ee][Bb][Ii][Nn][Ff][Oo]) BUILD_TYPE=RelWithDebInfo ;;
        *) script_error "Unsupported -build type: $2" ;;
      esac
      shift
      ;;
    -j)
      PARALLEL_PROC="$2"
      [[ "$PARALLEL_PROC" == *[^0-9]* ]] || (( PARALLEL_PROC == 0 )) && script_error "Invalid parallel process count specified: $PARALLEL_PROC"
      shift
      ;;
    brew)
      (( gcc_source > 1 )) && script_error "GCC type (brew or port) specified multiple times."
      export CC=/usr/local/bin/gcc-$GCC_VER
      export CXX=/usr/local/bin/g++-$GCC_VER
      gcc_source=1
      ;;
    port)
      (( gcc_source > 1 )) && script_error "GCC type (brew or port) specified multiple times."
      export CC=/opt/local/bin/gcc-mp-$GCC_VER
      export CXX=/opt/local/bin/g++-mp-$GCC_VER
      gcc_source=2
      ;;
    clean)   do_clean=1   ;;
    confirm) do_confirm=1 ;;
    quiet)   do_quiet=1   ;;
    silent)  do_silent=1  ;;
    docs)    do_docs=1  ;;
    *) # if this isn't the last argument, it's an error
      (( $# != 1 )) && script_error "Unrecognised argument: $1. If this is your install dir, it must be the last argument." usage
      target_dir="$1"
      ;;
  esac
  shift
done

# Print the command line we were given.
log_msg "Got command line: $0 $(printf "%s " "$command_line")" blue

[[ -z "$target_dir" ]]    && script_error "No installation directory specified."
[[ ! -d "$target_dir" ]]  && script_error "Specified installation directory $target_dir does not exist or is not a directory."

# Can't specify a GCC version unless brew or port is used.
[[ $gcc_source == "0" && "$GCC_VER" != "$DEFAULT_GCC_VER" ]] && script_error "Non-default GCC requested, but source (brew or port) not specified."

# Check validity of GCC executables
check_gcc() { executable="$1"
  [[ ! -x "$executable" ]] && script_error "Cannot find compiler executable $executable, or it is not executable."
  version_string=( $("$executable" --version) )
  version_name="${version_string[0]}"
  version_number="${version_name/[gcc+]*-/}"
  if [[ ! "$version_name" == gcc-* && ! "$version_name" == g++-* ]]; then
    script_error "Compiler executable $executable does not seem to be gcc or g++ - please check."
  fi
  if [[ "$version_number" != "$GCC_VER" ]]; then
    script_error "Compiler executable $executable has version $version_number, but expected GCC version $GCC_VER; please check."
  fi
}

# Only check that CC/CXX exist if $CC is non-empty, to allow using system/default compiler
if [[ ! -z "$CC" ]]
then
  check_gcc "$CC"
  check_gcc "$CXX"
fi

# Prepare summary status variables.
case "$gcc_source" in
  0) gcc_type="$(colorise_string red system)" ;;
  1) gcc_type="Homebrew" ;;
  2) gcc_type="MacPorts" ;;
esac

(( do_docs  == 1 )) && BUILD_DOCS="ON"
(( do_clean == 1 )) && clean_status="requested, $BUILD_DIR will be deleted." || clean_status="not requested"
(( do_quiet == 1 )) && quiet_status="yes"                                    || quiet_status="no"

# Print summary status before build
log_msg "Summary of build paramaters:" blue
log_msg "\\tBuild type: $BUILD_TYPE" blue
log_msg "\\tBuild docs: $BUILD_DOCS" blue
log_msg "\\tInstalling to: $target_dir" blue
log_msg "\\tGCC Version chosen: $GCC_VER (default is: $DEFAULT_GCC_VER)" blue
log_msg "\\tGCC source: $gcc_type." blue
if (( gcc_source > 0 )); then
  log_msg "\\tCompiler executables to be used:" blue
  log_msg "\\t\\tCC: $CC" blue
  log_msg "\\t\\tCXX: $CXX" blue
fi
log_msg "\\tParallel process count: $PARALLEL_PROC" blue
log_msg "\\tBuild directory: $BUILD_DIR" blue
log_msg "\\tCleaning: $clean_status" blue
log_msg "\\tQuiet build: $quiet_status" blue

# Require confirmation before building with system GCC.
if [[ $gcc_source == 0 ]]
then
  (( do_silent == 1 )) && script_error "Silent requested but GCC system confirmation required, exiting." # Silent builds requiring confirmation will fail immediately.
  log_msg "You did not specify whether you intalled GCC $GCC_VER from brew or ports." red
  log_msg "Therefore, cmake will have to use your default system compiler." red
  log_msg "Are you sure this is OK? [y/N]" red
  if ! read_confirmation
  then
    log_msg "Exiting." red
    exit 0
  else
    log_msg "Continuing." blue
  fi
fi

# Ask for confirmation if the user requested it (but not if using system GCC, as we already just did that.)
if (( do_confirm == 1 && gcc_source > 0 && do_silent == 0 )); then
  log_msg "Confirm requested: Do you want to do the build? [y/N]" red
  if ! read_confirmation; then
    log_msg "Exiting." red
    exit 0
  else
    log_msg "Continuing." blue
  fi
fi

# Create build folder if it doesn't exist; if it does, clean it if requested.
if [[ ! -d "$BUILD_DIR" ]]; then
  mkdir "$BUILD_DIR" || script_error "Could not create build directory $BUILD_DIR - please check path is valid and writable."
elif (( do_clean == 1 )); then
  log_msg "Cleaning: Deleting $BUILD_DIR" yellow
  rm -rf "$BUILD_DIR" && mkdir "$BUILD_DIR"
fi

log_msg "Build starting." blue

# Function that runs the build, handles errors, and times the procedure while preserving stdout/err.
run_build() {
  fail() { msg="$1"
    colorise_string red "${msg}\n"
  }

  cmake_comm=("cmake" ".." "-DCMAKE_BUILD_TYPE:string=$BUILD_TYPE" "-DCMAKE_INSTALL_PREFIX=$target_dir" "-DBUILD_DOCS:bool=$BUILD_DOCS")
  make_comm=("make" "-j$PARALLEL_PROC" "install")
  install_comm=("make" "install")

  run_build_command() { comm="$1" ; shift
    colorise_string yellow "Starting: $comm\n"
    case "$comm" in
      cmake) "${cmake_comm[@]}" ;;
      make) "${make_comm[@]}" ;;
      install) "${install_comm[@]}" ;;
    esac
    returnval="$?"
    if (( returnval != 0 )); then
      fail "Failed: $comm"
    fi
    return "$returnval"
  }

  export TIMEFORMAT="%lR"

  # Bash redirection magic to capture the total time of all commands to a variable, preserving stdout/err.
  { build_time=$(
    {
      time {
        export CMAKE_COLOR_MAKEFILE=ON
        cd "$BUILD_DIR" || script_error "Could not cd into ${BUILD_DIR}! It was there a minute ago..!"
        for command in cmake make; do
          if ! run_build_command "$command"; then
            break
          fi
        done
      } 1>&3- 2>&4- # redirect stdout/err to temp FDs
    } 2>&1 #stdout to stderr
    )
  } 3>&1 4>&2 # restore stdout/err
  buildstatus="$?" # save the return value of the build block
  (( buildstatus != 0 )) && duration_color="red" || duration_color="green"
  printf "%b%s" "$(colorise_string $duration_color "Build duration: $build_time")\n"
  return $buildstatus
}

# Capture the output of the build and log it, color coded.
run_build 2>&1 | while read -r build_output_line
  do # in quiet mode, log only the "Build duration" message, otherwise log all.
    (( do_quiet == 0 )) || [[ "$build_output_line" == *Build*duration:* ]] && log_build_msg "$build_output_line"
  done

buildstatus="${PIPESTATUS[0]}" # exit value of run_build()

if (( buildstatus == 0 )); then
  log_msg "Build succeeded." green
else
  log_msg "Build failed." red
  exit 1
fi

if [[ "$GCC_VER" != "$DEFAULT_GCC_VER" ]]
then
  log_msg "Reminder: you compiled with GCC $GCC_VER, which is not the default ($DEFAULT_GCC_VER)" blue
  log_msg "You will need to copy or symlink your compiler's i386/32bit libstdc++.6.dylib into $target_dir/hack/" blue
fi

exit 0
