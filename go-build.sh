#!/usr/bin/env bash
#
# Usage: go-build.sh -o BIN_NAME
#
set -eu

export GOOS=linux
export GOARCH=amd64

GOROOT=`go env GOROOT`
GOVERSION=`go env GOVERSION`
TOOL_DIR=$(go env GOTOOLDIR)

WORK=/tmp/go-build-bash/$(date +%s)
BUILD_ID=abcdefghijklmnopqrst/abcdefghijklmnopqrst
B="-buildid $BUILD_ID -goversion $GOVERSION"

# Associative arrays to manage properties of each package
declare -A PKGS=()
declare -A DEPENDS=()
declare -A FILE_NAMES_CACHE=()

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
if [[ $# -eq 0 ]]; then
  main_dir="."
  OUT_FILE="go-build-bash"
else
  shift
  OUT_FILE=$1
  main_dir="."
fi

debug="true" # true or false

function parseImportDecls() {
  set +e
  local file=$1
  cat $file \
   | tr '\n' '~' \
   | grep --only-matching --no-filename -E '~import\s*\([^\)]*\)' \
   | grep -E --only-matching '\"[^\"]+\"' \
   | tr -d '"'

  cat $file \
  | tr '\n' '~' \
   | grep --only-matching  --no-filename -E '~import\s*"[^"]+"' \
   | grep -E --only-matching '\"[^\"]+\"' \
   | tr -d '"'
  set -e
}

function parse_imports() {
  declare dir=$1
  shift;

  declare readonly files="$@"
  {
    for file in $files
    do
      parseImportDecls "$dir/$file"
    done
  } | sort | uniq | tr '\n' ' ' | awk '{$1=$1;print}'
}

function dump_depend_tree() {
  for p in "${!DEPENDS[@]}"
  do
    echo -n "$p:"
    for v in ${DEPENDS[$p]}
    do
      for w in $v
      do
      echo -n "\"$w\" "
      done
    done
    echo ""
  done
}

# Sort packages topologically
function sort_pkgs() {
  infile=$1
  local workfile=/tmp/work.txt

  cp $infile $workfile

  while true
  do
    leaves=$(cat $workfile | grep -e ': *$'| sed -e 's/: *//g')
    if [[ -z $leaves ]]; then
      return
    fi
    for l in $leaves
    do
      cat $workfile | grep -v -e "^$l:" | sed -E "s#\"$l\"##g" > /tmp/tmp.txt
      cp /tmp/tmp.txt $workfile
      echo $l
    done
  done
}

function build_pkg() {
std=$1
pkg=$2
shift;shift;
filenames="$@"

local gofiles=""
local afiles=""

for f in $filenames
do
  local file
  if [[ $std == "1" ]]; then
    file=$GOROOT/src/$pkg/$f
  else
    file=$f
  fi
  if [[ $f == *.go ]] ; then
    gofiles="$gofiles $file"
  elif [[ $f == *.s ]]; then
     afiles="$afiles $file"
  else
     echo "ERROR" >/dev/stderr
     exit 1
  fi
done

local wdir=$WORK/${PKGS[$pkg]}
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
  if [[ $pkg = "os"  ]] || [[ $pkg = "sync" ]] || [[ $pkg = "syscall" ]] \
   || [[ $pkg = "internal/poll" ]] || [[ $pkg = "time" ]]; then
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
local pkgopts=$(get_package_opts $pkg)
local pkgdir=$GOROOT/src/$pkg
log "compiling $pkg ($pkgdir) into $wdir/_pkg_.a"
$TOOL_DIR/compile -c=4 -nolocalimports -pack $pkgopts $otheropts $gofiles
if [[ -n $afiles ]]; then
  append_asm $pkg $afiles
fi
$TOOL_DIR/buildid -w $wdir/_pkg_.a # internal
}

function make_importcfg() {
pkg=$1
wdir=$WORK/${PKGS[$pkg]}
(
echo '# import config'
for f in  ${DEPENDS[$pkg]}
do
  echo "packagefile $f=$WORK/${PKGS[$f]}/_pkg_.a"
done
) >$wdir/importcfg
}

function gen_symabis() {
pkg=$1
shift
files="$@"
wdir=$WORK/${PKGS[$pkg]}

$TOOL_DIR/asm -p $pkg -trimpath "$wdir=>" -I $wdir/ -I $GOROOT/pkg/include -D GOOS_linux -D GOARCH_amd64 -compiling-runtime -D GOAMD64_v1 -gensymabis -o $wdir/symabis  $files
}

function append_asm() {
pkg=$1
shift
files="$@"

wdir=$WORK/${PKGS[$pkg]}
local ofiles=""
for f in $files
do
  local basename=${f##*/}
  local baseo=${basename%.s}.o
  local ofile=$wdir/$baseo
  $TOOL_DIR/asm -p $pkg -trimpath "$wdir=>" -I $wdir/ -I $GOROOT/pkg/include -D GOOS_linux -D GOARCH_amd64 -compiling-runtime -D GOAMD64_v1  -o $ofile $f
  ofiles="$ofiles $ofile"
done

$TOOL_DIR/pack r $wdir/_pkg_.a $ofiles
}

function get_package_opts() {
  pkg=$1
  wdir=$WORK/${PKGS[$pkg]}
  local pkgopts=" \
    -p $pkg \
    -o $wdir/_pkg_.a \
    -trimpath \"$wdir=>\" \
    $B \
    -importcfg $wdir/importcfg \
  "
  echo $pkgopts
}

## Final output
function do_link() {
local pkg=main
local wdir=$WORK/${PKGS[$pkg]}
local pkgsfiles=""
for p in "${!PKGS[@]}"
do
  pkgsfiles="${pkgsfiles}packagefile ${p}=$WORK/${PKGS[$p]}/_pkg_.a
"
done
cat >$wdir/importcfg.link << EOF # internal
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
}

function log() {
  if eval $debug ; then
    echo "$@" >/dev/stderr
  fi
}

function list_files_in_dir() {
  local dir=$1
  find $dir -maxdepth 1 -type f \( -name "*.go" -o -name "*.s" \) -printf "%f\n" \
   | grep -v -E '_test.go' | sort
}

function exclude_arch() {
  grep -v -E '_(android|ios|illumos|hurd|zos|darwin|plan9|windows|aix|dragonfly|freebsd|js|netbsd|openbsd|solaris)(\.|_)' \
   | grep -v -E '_(386|arm|armbe|arm64|arm64be|loong64|mips|mipsle|mips64.*|ppc64|ppc64le|riscv64|ppc|riscv|s390|s390x|sparc.*|wasm)\.(go|s)'
}

function get_build_tag() {
  local fullpath=$1
  set +e
  matched=`grep -m 1 --only-matching -E '^//go:build .+$' $fullpath`
  set -e
  matched=${matched##"//go:build "}
  echo $matched
}

function match_arch() {
  local matched=$1
      #log -n "[$f: '$matched' ]"
      if [[ $matched = "ignore" ]]; then
       # ignore
       return 1
      elif [[ -z $matched ]]; then
        # empty
         return 0
      else
      converted=$(echo $matched \
      | sed -E 's/(unix|linux|amd64)/@@@/g' \
      | sed -E 's/goexperiment\.(coverageredesign|regabiwrappers|regabiargs|unified)/@@@/' | sed -E 's/goexperiment\.\w+/false/g' \
      | sed -E 's/\w+/false/g' | sed -E 's/@@@/true/g' \
      | sed -e 's/!true/false/g' | sed -e 's/!false/true/g' \
      | sed -e 's/^true ||.*/true/' | sed -e 's/^true &&//g' | sed -e 's/^false ||//g' | sed -e 's/^false &&.*/false/g' \
       )
          :
           #log -n "=> '$converted'"
        if eval $converted ; then
           # do build
           return 0
        else
          return 1
       fi
      fi

}

function find_files_in_dir() {
  local dir=$1
  local files=$(list_files_in_dir $dir | exclude_arch)
  local gofiles=""
  local sfiles=""

  local buildfiles=""

  for f in $files
  do
    local fullpath="$dir/$f"
    local tag=$(get_build_tag $fullpath)
    if match_arch "$tag" ; then
         # log " => ok"
         buildfiles="$buildfiles $f"
    else
        :
         # log " => ng"
    fi
  done

  for f in $buildfiles
  do
    if [[ $f == *.go ]] ; then
      gofiles="$gofiles $f"
    elif [[ $f == *.s ]] ; then
      sfiles="$sfiles $f"
    else
      log ERROR
      exit 1
    fi
  done

  for s in $gofiles
  do
    echo -n " $s"
  done

  for s in $sfiles
  do
    echo -n " $s"
  done

  echo ''

}

function find_depends() {
  local pkg=$1
  if [ -v 'DEPENDS[$pkg]' ]; then
    return
  fi
  local dir=$GOROOT/src/$pkg
  log "$pkg:$dir"
  local files=$(find_files_in_dir $dir)
  log "  files:" $files
  FILE_NAMES_CACHE[$dir]="$files"
  local _pkgs=$(parse_imports $dir $files )
  local pkgs=""
  for _pkg in $_pkgs
  do
    if [[ $_pkg != "unsafe" ]]; then
      if [[ -z $pkgs ]]; then
        pkgs=$_pkg
      else
        pkgs="$pkgs $_pkg"
      fi
    fi
  done

  log "  imports:$pkgs"
  DEPENDS[$pkg]=$pkgs

  for _pkg in $pkgs
  do
    find_depends $_pkg
  done
}

function resolve_dep_tree() {
    local files="$@" # main files
    local pkgs=$( parse_imports . $files )
    DEPENDS[main]=$pkgs

    for pkg in $pkgs
    do
      find_depends $pkg
    done
}

function get_std_pkg_dir() {
  local pkg=$1
  echo $GOROOT/src/$pkg
}

# main procedure
function go_build() {
  rm -f $OUT_FILE

  PKGS[main]=1
  id=2

  log ""
  log "#"
  log "# Finding files"
  log "#"
  local main_files=$(find_files_in_dir $main_dir)
  FILE_NAMES_CACHE[$main_dir]="$main_files"
  resolve_dep_tree $main_files
  mkdir -p $WORK

  dump_depend_tree > $WORK/depends.txt
  log ""
  log "#"
  log "# Dependency tree has been made"
  log "#"
  cat $WORK/depends.txt >/dev/stderr
  log ""
  log "#"
  log "# Sorting dependency ree"
  log "#"
  sort_pkgs  $WORK/depends.txt > $WORK/sorted.txt
  cat $WORK/sorted.txt >/dev/stderr

  std_pkgs=`cat $WORK/sorted.txt | grep -v -e '^main$'`
  for pkg in $std_pkgs
  do
    PKGS[$pkg]=$id
    id=$((id + 1))
  done

  log ""
  log "#"
  log "# Compiling packages"
  log "#"
  for pkg in $std_pkgs
  do
    dir=$GOROOT/src/$pkg
    files=${FILE_NAMES_CACHE[$dir]}
    build_pkg 1 $pkg $files
  done

  log ""
  log "#"
  log "# Compiling the main package"
  log "#"
  cd $main_dir
  build_pkg 0 "main" ${FILE_NAMES_CACHE[$main_dir]}

  log ""
  log "#"
  log "# Link packages"
  log "#"
  do_link
}

go_build
