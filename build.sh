#!/bin/bash

set -e

_SCRIPT=$(readlink -f $0)
_TOPDIR=$(dirname $_SCRIPT)

GECKO_SRC_DIR=$_TOPDIR/gecko-dev
EMBEDLITE_COMPONENTS_SRC_DIR=$_TOPDIR/embedlite-components
QTMOZEMBED_SRC_DIR=$_TOPDIR/qtmozembed
QMLMOZBROWSER_SRC_DIR=$_TOPDIR/qmlmozbrowser
SAILFISH_BROWSER_SRC_DIR=$_TOPDIR/sailfish-browser
QZILLA_SRC_DIR=$_TOPDIR/qzilla

CPUNUM=$(grep -c ^processor /proc/cpuinfo)
ans=$(( CPUNUM * 2 - 1 ))
MAKE_JOBS=$ans

export QT_SELECT=5

function show_help() {
cat << EOF
usage: $1 [options]

Options:
  -c, --config [configuration]  Build gecko for specified configuration
  -d, --debug                   Compile the code in debug mode
      --dmd                     Enable DMD (dark matter detector)
  -f, --force-configure         Force the script to re-run gecko confguration step
  -g, --skip-gecko              Skip gecko build step
  -h, --help                    Show this help message
  -j [number]                   Specify number make build jobs to use (default: $MAKE_JOBS)
  -k, --ccache                  Enable support for ccache
  -l, --list-configs            List available configurations
  -x, --no-gold                 Don't use gold linker.
      --valgrind                Enable support for running gecko under valgrind.
  -v, --verbose                 Build the code in verbose mode
EOF
exit 0
}

function run_make() {
  local make_opts""
  [[ $VERBOSE == false ]] && make_opts="--silent"
  make -j $MAKE_JOBS $make_opts "$@"
}

function add_mozilla_configure_opts() {
  while [[ $# > 0 ]]; do
    echo "ac_add_options $1" >> $MOZCONFIG
    shift
  done
}

function add_mozilla_make_opts() {
  while [[ $# > 0 ]]; do
    echo "mk_add_options $1" >> $MOZCONFIG
    shift
  done
}

function list_configs() {
  printf "Available workspace configurations:\n"
  for cfg in $_TOPDIR/config/mozconfig.*; do
    local file=$(basename $cfg)
    printf "  * ${file#mozconfig.}\n"
  done

  printf "\nAvailable EmbedLite configurations:\n"
  for cfg in $GECKO_SRC_DIR/embedding/embedlite/config/mozconfig.*; do
    local file=$(basename $cfg)
    printf "  * ${file#mozconfig.}\n"
  done
  exit 0
}

function prepare_mozconfig() {
  local config
  if [[ -r $_TOPDIR/config/mozconfig.$CONFIG ]]; then
    config=$_TOPDIR/config/mozconfig.$CONFIG
  elif [[ -r $GECKO_SRC_DIR/embedding/embedlite/config/mozconfig.$CONFIG ]]; then
    config=$GECKO_SRC_DIR/embedding/embedlite/config/mozconfig.$CONFIG
  else
    printf "Could not find mozconfig.$CONFIG\n"
    exit 1
  fi

  cp $config "$BUILD_DIR/$(basename $config)"
  export MOZCONFIG="$BUILD_DIR/$(basename $config)"
}

function build_gecko() {
  pushd $BUILD_DIR > /dev/null
  mkdir -p $BUILD_DIR/gecko

  prepare_mozconfig
  printf "\n# Autogenerated by build.sh\n" >> $MOZCONFIG

  sed -i '/MOZ_OBJDIR/d' $MOZCONFIG
  sed -i '/MOZ_MAKE_FLAGS/d' $MOZCONFIG
  add_mozilla_make_opts \
      "MOZ_OBJDIR=\"$BUILD_DIR/gecko\"" \
      "MOZ_MAKE_FLAGS=\"-j$MAKE_JOBS\"" \
      "AUTOCLOBBER=1"

  if [[ $USE_GOLD == true ]]; then
    echo "CFLAGS=\"$CFLAGS -fuse-ld=gold\"" >>  $MOZCONFIG
    echo "CXXFLAGS=\"$CXXFLAGS -fuse-ld=gold\"" >>  $MOZCONFIG
    echo "LD=ld.gold" >>  $MOZCONFIG
  fi

  add_mozilla_configure_opts \
      --disable-trace-malloc \
      --enable-jemalloc

  # Configure
  if [[ $BUILD_MODE == "Debug" ]]; then
    add_mozilla_configure_opts \
        --enable-debug \
        --enable-logging \
        --disable-optimize
    if [[ $ENABLE_DMD == true ]]; then
      add_mozilla_configure_opts --enable-dmd
    fi
  fi
  if [[ $USE_VALGRIND == true ]]; then
    add_mozilla_configure_opts \
        --disable-jemalloc \
        --enable-valgrind
  fi

  if [[ $USE_CCACHE == true ]]; then
    add_mozilla_configure_opts --with-ccache=$(which ccache)
  fi

  mkdir -p $BUILD_DIR/gecko
  cd $BUILD_DIR/gecko
  if [ ! -r $BUILD_DIR/gecko/config.log ] || [ $FORCE_CONFIGURE = true ]; then
    $GECKO_SRC_DIR/mach configure
  fi

  # Build
  $GECKO_SRC_DIR/mach build
  run_make -C $BUILD_DIR/gecko/embedding/embedlite
  run_make -C $BUILD_DIR/gecko/toolkit/library libs

  popd > /dev/null
}

function build_embedlite_components() {
  pushd $BUILD_DIR > /dev/null

  if [ ! -x $BUILD_DIR/embedlite-components/autogen.sh ]; then
    cp -as $EMBEDLITE_COMPONENTS_SRC_DIR embedlite-components
  fi

  cd $BUILD_DIR/embedlite-components
  if [ ! -x configure ]; then
    NO_CONFIGURE=yes ./autogen.sh
  fi

  if [ ! -r $BUILD_DIR/embedlite-components/config.log ] || [ $FORCE_CONFIGURE = true ]; then
    ./configure --with-engine-path=$BUILD_DIR/gecko
  fi
  make -C $BUILD_DIR/embedlite-components -j$MAKE_JOBS

  $EMBEDLITE_COMPONENTS_SRC_DIR/link_to_system.sh \
      $BUILD_DIR/gecko/dist/bin \
      $BUILD_DIR/embedlite-components

  popd > /dev/null
}

function build_qtmozembed() {
  mkdir -p $BUILD_DIR/qtmozembed
  pushd $BUILD_DIR/qtmozembed > /dev/null

  qmake \
      DEFAULT_COMPONENT_PATH=$BUILD_DIR/gecko/dist/bin \
      OBJ_PATH=$BUILD_DIR/gecko \
      OBJ_BUILD_PATH=obj \
      $QTMOZEMBED_SRC_DIR


  run_make -C $BUILD_DIR/qtmozembed

  ln -sf $QTMOZEMBED_SRC_DIR/qmlplugin5/qmldir $BUILD_DIR/qtmozembed/obj/qmlplugin5/qmldir
  rm -f $BUILD_DIR/qtmozembed/obj/qmlplugin5/Qt5Mozilla
  ln -sf $BUILD_DIR/qtmozembed/obj/qmlplugin5 $BUILD_DIR/qtmozembed/obj/qmlplugin5/Qt5Mozilla

  popd > /dev/null
}

function build_qmlmozbrowser() {
  mkdir -p $BUILD_DIR/qmlmozbrowser
  pushd $BUILD_DIR/qmlmozbrowser > /dev/null

  LIBQTEMBEDWIDGET="libqt5embedwidget.so"

  if [[ "$CONFIG" == "merqtxulrunner" ]]; then
    SF_TARGET=1
  fi

  qmake \
      SF_TARGET=$SF_TARGET \
      OBJ_BUILD_PATH=obj \
      DEFAULT_COMPONENT_PATH=$BUILD_DIR/gecko/dist/bin \
      QTEMBED_LIB+=$BUILD_DIR/qtmozembed/obj/src/$LIBQTEMBEDWIDGET \
      INCLUDEPATH+=$QTMOZEMBED_SRC_DIR/src/ \
      $QMLMOZBROWSER_SRC_DIR

  run_make -C $BUILD_DIR/qmlmozbrowser

  $QMLMOZBROWSER_SRC_DIR/link_to_system.sh $BUILD_DIR/gecko/dist/bin obj

  popd > /dev/null
}

function build_qzilla() {
  mkdir -p $BUILD_DIR/qzilla
  pushd $BUILD_DIR/qzilla > /dev/null

  qmake \
      INCLUDEPATH+=$QTMOZEMBED_SRC_DIR/src \
      LIBS+=$BUILD_DIR/qtmozembed/obj/src/$LIBQTEMBEDWIDGET \
      CONFIG+=debug \
      $QZILLA_SRC_DIR

  run_make -C $BUILD_DIR/qzilla

  popd > /dev/null
}

function build_sailfish_browser() {
  mkdir -p $BUILD_DIR/sailfish-browser
  pushd $BUILD_DIR/sailfish-browser > /dev/null

  LIBQTEMBEDWIDGET="libqt5embedwidget.so"

  export USE_RESOURCES=1
  qmake \
      USE_RESOURCES=1 \
      OBJ_BUILD_PATH=obj \
      DEFAULT_COMPONENT_PATH=$BUILD_DIR/gecko/dist/bin \
      QTEMBED_LIB+=$BUILD_DIR/qtmozembed/obj/src/$LIBQTEMBEDWIDGET \
      INCLUDEPATH+=$QTMOZEMBED_SRC_DIR/src \
      CONFIG+=debug \
      $SAILFISH_BROWSER_SRC_DIR


  run_make -C $BUILD_DIR/sailfish-browser

  popd > /dev/null
}

CONFIG=""
BUILD_MODE="Release"
BUILD_GECKO=true
FORCE_CONFIGURE=false
USE_CCACHE=false
USE_GOLD=true
VERBOSE=false
ENABLE_DMD=false
USE_VALGRIND=false

while [[ $# > 0 ]]; do
  case $1 in
    -c|--config)
      CONFIG=$2
      shift
      ;;
    -d|--debug)
      BUILD_MODE="Debug"
      ;;
    --dmd)
      ENABLE_DMD=true
      ;;
    -f|--force-configure)
      FORCE_CONFIGURE=true
      ;;
    -g|--skip-gecko)
      BUILD_GECKO=false
      ;;
    -h|--help)
      show_help
      ;;
    -j*)
      MAKE_JOBS=${1#-j}
      ;;
    -k|--ccache)
      USE_CCACHE=true
      ;;
    -l|--list-configs)
      list_configs
      ;;
    -x|--no-gold)
      USE_GOLD=false
      ;;
    --valgrind)
      USE_VALGRIND=true
      ;;
    -v|--verbose)
      VERBOSE=true
      ;;
  esac
  shift
done

if [[ $ENABLE_DMD == true && $BUILD_MODE == "Release" ]]; then
  echo "Error: DMD mode has no effect in release builds!";
  exit 1
fi

BUILD_DIR=${_TOPDIR}/out.$BUILD_MODE.$(uname -m).$CONFIG
mkdir -p $BUILD_DIR

[[ $BUILD_GECKO == true ]] && build_gecko
build_embedlite_components
build_qtmozembed
build_qmlmozbrowser
if [[ "$CONFIG" == "qtdesktop-ng" ]]; then
build_qzilla
fi
if [[ "$CONFIG" == "merqtxulrunner" ]]; then
  build_sailfish_browser
fi

echo "export LD_LIBRARY_PATH=$BUILD_DIR/qtmozembed/obj/src" > $BUILD_DIR/runtime.env
echo "export QML2_IMPORT_PATH=$BUILD_DIR/qtmozembed/obj/qmlplugin5" >> $BUILD_DIR/runtime.env

