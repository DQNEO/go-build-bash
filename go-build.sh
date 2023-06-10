#!/usr/bin/env bash
#
# Usage: go-build.sh -o BIN_NAME
#
set -eu

export GOOS=linux
export GOARCH=amd64

DEFAULT_OUT_FILE="go-build-bash"

GOROOT=$(go env GOROOT)
GOVERSION=$(go env GOVERSION)
TOOL_DIR=$(go env GOTOOLDIR)

WORK=/tmp/go-build-bash/$(date +%s)
BUILD_ID=abcdefghijklmnopqrst/abcdefghijklmnopqrst

# Associative arrays to manage properties of each package
declare -A PKGS_ID=()
declare -A PKGS_DEPEND=()
declare -A PKGS_FILES=()

debug="true" # true or false

function log() {
  if eval $debug; then
    echo "$@" >/dev/stderr
  fi
}

# Detect OS type
if [[ $OSTYPE == "darwin"* ]]; then
  HOST_GOOS=darwin
  if ! which gfind >/dev/null || ! which gsed >/dev/null; then
    "gfind and gsed commands are required. Please try 'brew install findutils gnu-sed'" >/dev/stderr
    exit 1
  fi
  shopt -s expand_aliases
  alias find=gfind
  alias sed=gsed
elif [[ $OSTYPE == "linux"* ]]; then
  HOST_GOOS=linux
fi

# Parse argv
main_dir="."
OUT_FILE=$DEFAULT_OUT_FILE
if [[ $# -ge 1 ]]; then
  if [[ $1 == "-o" ]]; then
    shift
    OUT_FILE=$1
    shift
  fi

  if [[ $# -ge 1 ]]; then
    main_dir=$1
  fi
fi

log "# main directory:" $main_dir
log "# out file:" $OUT_FILE

function parse_imports() {
  local dir=$1
  shift
  local absfiles="$@"

  local tmpfile=$WORK/_tmp_parse_imports.txt
  cat $absfiles | tr '\n' '~' >$tmpfile

  set +e
  (
    cat $tmpfile |
      grep --only-matching --no-filename -E '~import\s*\([^\)]*\)'

    cat $tmpfile |
      grep --only-matching --no-filename -E '~import\s*"[^"]+"'
  ) |
    grep -E --only-matching '\"[^\"]+\"' |
    grep -v '"unsafe"' | tr -d '"' | sort | uniq | tr '\n' ' ' | awk '{$1=$1;print}'
  set -e
}

function dump_depend_tree() {
  for p in "${!PKGS_DEPEND[@]}"; do
    echo -n "$p:"
    for v in ${PKGS_DEPEND[$p]}; do
      for w in $v; do
        echo -n "\"$w\" "
      done
    done
    echo ""
  done
}

# Sort packages topologically
function sort_pkgs() {
  infile=$1
  local workfile=$WORK/_tmp_sort_pkgs_work.txt
  local tmpfile=$WORK/_tmp_sort_pkgs_tmp.txt

  cp $infile $workfile

  while true; do
    leaves=$(cat $workfile | grep -e ': *$' | sed -e 's/: *//g')
    if [[ -z $leaves ]]; then
      return
    fi
    for l in $leaves; do
      cat $workfile | grep -v -e "^$l:" | sed -E "s#\"$l\"##g" >$tmpfile
      mv -f $tmpfile $workfile
      echo $l
    done
  done
}

function build_pkg() {
  std=$1
  pkg=$2
  shift
  shift
  filenames="$@"

  local gofiles=""
  local afiles=""

  for f in $filenames; do
    local file=$f
    if [[ $f == *.go ]]; then
      gofiles="$gofiles $file"
    elif [[ $f == *.s ]]; then
      afiles="$afiles $file"
    else
      echo "ERROR" >/dev/stderr
      exit 1
    fi
  done

  local wdir=$WORK/${PKGS_ID[$pkg]}
  mkdir -p $wdir/
  make_importcfg $pkg

  local asmopts=""
  local sruntime=""
  local scomplete=""
  local sstd=""
  local slang=""

  if [[ -n $afiles ]]; then
    if [[ "$std" = "1" ]]; then
      touch $wdir/go_asm.h
    fi
    gen_symabis $pkg $afiles
    asmopts="-symabis $wdir/symabis -asmhdr $wdir/go_asm.h"
  fi

  if [[ $pkg = "runtime" ]]; then
    sruntime="-+"
  fi

  complete="1"
  if [[ -n $afiles ]]; then
    complete="0"
  fi
  if [[ "$std" = "1" ]]; then
    # see /usr/local/opt/go/libexec/src/cmd/go/internal/work/gc.go:119
    if [[ $pkg = "os" ]] || [[ $pkg = "sync" ]] || [[ $pkg = "syscall" ]] ||
      [[ $pkg = "internal/poll" ]] || [[ $pkg = "time" ]]; then
      complete="0"
    fi
  fi

  if [ "$complete" = "1" ]; then
    scomplete="-complete"
  fi
  if [ "$std" = "1" ]; then
    sstd="-std"
  fi
  if [ "$pkg" = "main" ]; then
    slang="-lang=go1.20"
  fi

  local otheropts=" $slang $sstd $sruntime $scomplete $asmopts "
  local pkgopts=" \
  -p $pkg \
  -o $wdir/_pkg_.a \
  -trimpath \"$wdir=>\" \
  -buildid $BUILD_ID \
  -goversion $GOVERSION \
  -importcfg $wdir/importcfg \
"

  local pkgdir=$GOROOT/src/$pkg
  log "compiling $pkg => $wdir/_pkg_.a"
  $TOOL_DIR/compile -c=4 -nolocalimports -pack $pkgopts $otheropts $gofiles
  if [[ -n $afiles ]]; then
    append_asm $pkg $afiles
  fi
  $TOOL_DIR/buildid -w $wdir/_pkg_.a # internal
}

function make_importcfg() {
  pkg=$1
  wdir=$WORK/${PKGS_ID[$pkg]}
  (
    echo '# import config'
    for f in ${PKGS_DEPEND[$pkg]}; do
      echo "packagefile $f=$WORK/${PKGS_ID[$f]}/_pkg_.a"
    done
  ) >$wdir/importcfg
}

function gen_symabis() {
  pkg=$1
  shift
  files="$@"
  wdir=$WORK/${PKGS_ID[$pkg]}

  $TOOL_DIR/asm -p $pkg -trimpath "$wdir=>" -I $wdir/ -I $GOROOT/pkg/include -D GOOS_linux -D GOARCH_amd64 -compiling-runtime -D GOAMD64_v1 -gensymabis -o $wdir/symabis $files
}

function append_asm() {
  pkg=$1
  shift
  files="$@"

  wdir=$WORK/${PKGS_ID[$pkg]}
  local ofiles=""
  for f in $files; do
    local basename=${f##*/}
    local baseo=${basename%.s}.o
    local ofile=$wdir/$baseo
    $TOOL_DIR/asm -p $pkg -trimpath "$wdir=>" -I $wdir/ -I $GOROOT/pkg/include -D GOOS_linux -D GOARCH_amd64 -compiling-runtime -D GOAMD64_v1 -o $ofile $f
    ofiles="$ofiles $ofile"
  done

  $TOOL_DIR/pack r $wdir/_pkg_.a $ofiles
}

## Final output
function do_link() {
  local pkg=main
  local wdir=$WORK/${PKGS_ID[$pkg]}
  local pkgsfiles=""
  for p in "${!PKGS_ID[@]}"; do
    pkgsfiles="${pkgsfiles}packagefile ${p}=$WORK/${PKGS_ID[$p]}/_pkg_.a
"
  done
  cat >$wdir/importcfg.link <<EOF # internal
packagefile github.com/DQNEO/go-samples/birudo=$wdir/_pkg_.a
$pkgsfiles
modinfo "0w\xaf\f\x92t\b\x02A\xe1\xc1\a\xe6\xd6\x18\xe6path\tgithub.com/DQNEO/go-samples/birudo\nmod\tgithub.com/DQNEO/go-samples/birudo\t(devel)\t\nbuild\t-buildmode=exe\nbuild\t-compiler=gc\nbuild\tCGO_ENABLED=0\nbuild\tGOARCH=amd64\nbuild\tGOOS=linux\nbuild\tGOAMD64=v1\nbuild\tvcs=git\nbuild\tvcs.revision=a721858f4c22cb178c3f3853f9c55aa3773afc2c\nbuild\tvcs.time=2023-06-02T12:08:04Z\nbuild\tvcs.modified=true\n\xf92C1\x86\x18 r\x00\x82B\x10A\x16\xd8\xf2"
EOF

  mkdir -p $wdir/exe/
  cd .
  $TOOL_DIR/link -o $wdir/exe/a.out -importcfg $wdir/importcfg.link -buildmode=exe -buildid=yekYyg_HZMgX517VPpiO/aHxht5d7JGm1qJULUhhT/ct0PU8-vieH10gtMxGeC/yekYyg_HZMgX517VPpiO -extld=cc $wdir/_pkg_.a
  log "$TOOL_DIR/link -o $wdir/exe/a.out -importcfg $wdir/importcfg.link -buildmode=exe -buildid=yekYyg_HZMgX517VPpiO/aHxht5d7JGm1qJULUhhT/ct0PU8-vieH10gtMxGeC/yekYyg_HZMgX517VPpiO -extld=cc $wdir/_pkg_.a"

  $TOOL_DIR/buildid -w $wdir/exe/a.out
  mv $wdir/exe/a.out $OUT_FILE

  log ""
  log "#"
  log "# Move the binary executable file"
  log "#"
  echo mv $wdir/exe/a.out $OUT_FILE

}

function list_maching_files_in_dir() {
  local dir=$1
  find $dir -maxdepth 1 -type f \( -name "*.go" -o -name "*.s" \) -printf "%f\n" |
    grep -v -E '_test.go' |
    grep -v -E '_(android|ios|illumos|hurd|zos|darwin|plan9|windows|aix|dragonfly|freebsd|js|netbsd|openbsd|solaris)(\.|_)' |
    grep -v -E '_(386|arm|armbe|arm64|arm64be|loong64|mips|mipsle|mips64.*|ppc64|ppc64le|riscv64|ppc|riscv|s390|s390x|sparc.*|wasm)\.(go|s)'
}

function get_build_tag() {
  local fullpath=$1
  set +e
  matched=$(grep -m 1 --only-matching -E '^//go:build .+$' $fullpath)
  set -e
  matched=${matched##"//go:build "}
  echo $matched
}

function match_arch() {
  local matched=$1
  if [[ $matched = "ignore" ]]; then
    # ignore
    return 1
  elif [[ -z $matched ]]; then
    # empty
    return 0
  else
    converted=$(
      echo $matched |
        sed -E 's/(unix|linux|amd64)/@@@/g' |
        sed -E 's/goexperiment\.(coverageredesign|regabiwrappers|regabiargs|unified)/@@@/' | sed -E 's/goexperiment\.\w+/false/g' |
        sed -E 's/\w+/false/g' | sed -E 's/@@@/true/g' |
        sed -e 's/!true/false/g' | sed -e 's/!false/true/g' |
        sed -e 's/^true ||.*/true/' | sed -e 's/^true &&//g' | sed -e 's/^false ||//g' | sed -e 's/^false &&.*/false/g'
    )
    :
    if eval $converted; then
      # do build
      return 0
    else
      return 1
    fi
  fi

}

function find_files_in_dir() {
  local dir=$1
  local files=$(list_maching_files_in_dir $dir)
  local gofiles=""
  local asfiles=""

  for f in $files; do
    local fullpath="$dir/$f"
    local tag=$(get_build_tag $fullpath)
    if match_arch "$tag"; then
      if [[ $fullpath == *.go ]]; then
        gofiles="$gofiles $fullpath"
      elif [[ $fullpath == *.s ]]; then
        asfiles="$asfiles $fullpath"
      else
        log "something wrong happened"
        exit 1
      fi
    fi
  done

  echo "$gofiles $asfiles"
}

# Convert absolute filenames to base names.
# The purpose is for log's readability
function abspaths_to_basenames() {
  local paths="$@"
  local files=""
  for path in $paths
  do
    file=$(basename $path)
    files="$files $file"
  done
  echo $files
}
function find_depends() {
  local pkg=$1
  if [ -v 'PKGS_DEPEND[$pkg]' ]; then
    return
  fi

  local pkgdir=$GOROOT/src/$pkg

  log "[$pkg]"
  log "  dir:$pkgdir"
  local files=$(find_files_in_dir $pkgdir)
  local filenames=$(abspaths_to_basenames $files)
  log "  files:" $filenames
  PKGS_FILES[$pkg]="$files"
  local pkgs=$(parse_imports $pkgdir $files)
  log "  imports:$pkgs"
  PKGS_DEPEND[$pkg]=$pkgs
  for _pkg in $pkgs; do
    find_depends $_pkg
  done
}

function get_std_pkg_dir() {
  local pkg=$1
  echo $GOROOT/src/$pkg
}

# main procedure
function go_build() {
  rm -f $OUT_FILE
  mkdir -p $WORK

  log ""
  log "#"
  log "# Finding files"
  log "#"
  local pkg="main"
  local pkgdir=$main_dir
  log "[$pkg]"
  log "  dir:$pkgdir"
  local files=$(find_files_in_dir $pkgdir)

  log "  files:" $files
  PKGS_FILES[$pkg]="$files"
  local pkgs=$(parse_imports $pkgdir $files)
  log "  imports:$pkgs"
  PKGS_DEPEND[$pkg]=$pkgs

  for _pkg in $pkgs; do
    find_depends $_pkg
  done

  dump_depend_tree >$WORK/depends.txt
  log ""
  log "#"
  log "# Got dependency tree"
  log "#"
  cat $WORK/depends.txt | sed -e 's/^([^:]+):/[\1] => /g' | tr -d '"' >/dev/stderr
  log ""
  log "#"
  log "# Sorting dependency tree"
  log "#"
  local sorted_pkgs=$(sort_pkgs $WORK/depends.txt | grep -v -E '^main$')

  # Assign package ID number
  PKGS_ID["main"]="001"
  local id=2
  for pkg in $sorted_pkgs; do
    id_string=$(printf "%03d" $id)
    PKGS_ID[$pkg]=$id_string
    id=$((id + 1))
    log "[$id_string] $pkg"
  done
  log "[001] main"

  log ""
  log "#"
  log "# Compiling packages"
  log "#"
  for pkg in $sorted_pkgs; do
    build_pkg 1 $pkg ${PKGS_FILES[$pkg]}
  done

  log ""
  log "#"
  log "# Compiling the main package"
  log "#"
  build_pkg 0 "main" ${PKGS_FILES["main"]}

  log ""
  log "#"
  log "# Link all packages"
  log "#"
  do_link
}

go_build
