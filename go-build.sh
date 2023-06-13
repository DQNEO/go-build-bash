#!/usr/bin/env bash
#
# Usage: go-build.sh -o BIN_NAME DIR_NAME
#
set -eu

WORK=/tmp/go-build-bash/$(date +%s)
BUILD_ID=abcdefghijklmnopqrst/abcdefghijklmnopqrst

GOROOT=$(go env GOROOT)
GOVERSION=$(go env GOVERSION)
TOOL_DIR=$(go env GOTOOLDIR)

if [[ (! -v GOARCH) || -z $GOARCH ]]; then
  GOARCH=$(go env GOHOSTARCH)
fi

if [[ ( ! -v GOOS ) || -z $GOOS ]]; then
  GOOS=$(go env GOHOSTOS)
fi

# TODO: Stop prohibited list style and use allowed list instead
if  [[ $GOOS = "darwin" ]]; then
  NON_GOOS="linux"
elif [[ $GOOS = "linux" ]]; then
  NON_GOOS="darwin"
else
  echo "ERROR: unsupported GOOS: $GOOS" >/dev/stderr
  exit 1
fi

ASM_D_GOOS=GOOS_${GOOS}
ASM_D_GOARCH=GOARCH_${GOARCH}

# Use gnu tools for MacOS
if [[ $OSTYPE == "darwin"* ]]; then
  if ! which gfind >/dev/null || ! which gsed >/dev/null; then
    "gfind and gsed commands are required. Please try 'brew install findutils gnu-sed'" >/dev/stderr
    exit 1
  fi
  shopt -s expand_aliases
  alias find=gfind
  alias sed=gsed
fi


debug="true" # true or false
function log() {
  if eval $debug; then
    echo "$@" >/dev/stderr
  fi
}


# Associative arrays to manage properties of each package
declare -A PKGS_ID=()
declare -A PKGS_DEPEND=()
declare -A PKGS_FILES=()

function get_std_pkg_dir() {
  local pkg=$1
  echo $GOROOT/src/$pkg
}

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
      grep --only-matching --no-filename -E '~import\s*[^"]*"[^"]+"'
  ) |
    grep -E --only-matching '\"[^\"]+\"' |
    grep -v '"unsafe"' | tr -d '"' | sort | uniq
  set -e
}

function dump_depend_tree() {
  for p in "${!PKGS_DEPEND[@]}"; {
    echo -n "$p:"
    for v in ${PKGS_DEPEND[$p]}; {
      for w in $v; {
        echo -n "\"$w\" "
      }
    }
    echo ""
  }
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
    for l in $leaves; {
      cat $workfile | grep -v -e "^$l:" | sed -E "s#\"$l\"##g" >$tmpfile
      mv -f $tmpfile $workfile
      echo $l
    }
  done
}

# Build a package
function build_pkg() {
  pkg=$1
  shift
  local filenames=($@)

  log ""
  log "[$pkg]"
  log "  source:" $(dirname ${filenames[0]})

  # Create a work directory to build the package
  # All outputs are stored into this directory
  local wdir=$WORK/${PKGS_ID[$pkg]}
  log "  mkdir -p $wdir/"
  mkdir -p $wdir/

  local gofiles=""
  local asmfiles=""
  local gobasenames=() # for logging

  # Split given files into .go and .s groups
  for f in ${filenames[@]}; {
    local file=$f
    if [[ $f == *.go ]]; then
      gofiles="$gofiles $file"
      gobasenames+=($(basename $file))
    elif [[ $f == *.s ]]; then
      asmfiles="$asmfiles $file"
    else
      echo "ERROR" >/dev/stderr
      exit 1
    fi
  }

  # Make an importcfg file.
  # It contains a list of packages this package imports
  make_importcfg $pkg

  local asmopts=""
  local sruntime=""
  local scomplete=""
  local std=""
  local sstd=""
  local slang=""

  if [[ ! $pkg =~ \. ]] && [[ $pkg != "main" ]]; then
    std="1"
  fi
  if [[ -n $asmfiles ]]; then
    if [[ "$std" = "1" ]]; then
      touch $wdir/go_asm.h
    fi
    gen_symabis $pkg $asmfiles
    asmopts="-symabis $wdir/symabis -asmhdr $wdir/go_asm.h"
  fi

  if [[ $pkg = "runtime" ]]; then
    sruntime="-+"
  fi

  complete="1"
  if [[ -n $asmfiles ]]; then
    complete="0"
  fi
  if [[ "$std" = "1" ]]; then
    # see /usr/local/opt/go/libexec/src/cmd/go/internal/work/gc.go:119
    if [[ $pkg = "os" || $pkg = "sync" || $pkg = "syscall" || $pkg = "internal/poll" || $pkg = "time" ]]; then
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

  local otheropts="$sruntime $scomplete $sstd $slang $asmopts "
  local pkgopts="-p $pkg -o $wdir/_pkg_.a\
 -trimpath \"$wdir=>\"\
 -buildid $BUILD_ID -goversion $GOVERSION -importcfg $wdir/importcfg"

  local compile_opts="$pkgopts $otheropts -c=4 -nolocalimports -pack "
  log "  compile option:" $compile_opts
  log "  compiling: (${gobasenames[@]})"
  $TOOL_DIR/compile $compile_opts $gofiles
  if [[ -n $asmfiles ]]; then
    append_asm $pkg $asmfiles
  fi
  $TOOL_DIR/buildid -w $wdir/_pkg_.a # internal
}

function make_importcfg() {
  pkg=$1
  wdir=$WORK/${PKGS_ID[$pkg]}
  local cfgfile=$wdir/importcfg
  (
    echo '# import config'
    for f in ${PKGS_DEPEND[$pkg]}; {
      echo "packagefile $f=$WORK/${PKGS_ID[$f]}/_pkg_.a"
    }
  ) >$cfgfile

  log "  generating the import config file: $cfgfile"
  log "      ----"
  awk '{$1="      "$1}1' <$cfgfile >/dev/stderr
  log "      ----"
}

function gen_symabis() {
  pkg=$1
  shift
  asfiles="$@"
  wdir=$WORK/${PKGS_ID[$pkg]}
  outfile=$wdir/symabis
  log "  generating the symabis file: $outfile"
  $TOOL_DIR/asm -p $pkg -trimpath "$wdir=>" -I $wdir/ -I $GOROOT/pkg/include -D $ASM_D_GOOS -D $ASM_D_GOARCH -compiling-runtime -D GOAMD64_v1 -gensymabis -o $outfile $asfiles
}

function append_asm() {
  pkg=$1
  shift
  files="$@"

  wdir=$WORK/${PKGS_ID[$pkg]}
  local ofiles=""
  local obasenames=() # for logging
  for f in $files; {
    local basename=$(basename $f)
    local baseo=${basename%.s}.o
    local ofile=$wdir/$baseo
    log "  assembling: $basename => $baseo"
    $TOOL_DIR/asm -p $pkg -trimpath "$wdir=>" -I $wdir/ -I $GOROOT/pkg/include -D $ASM_D_GOOS -D $ASM_D_GOARCH -compiling-runtime -D GOAMD64_v1 -o $ofile $f
    ofiles="$ofiles $ofile"
    obasenames+=($baseo)
  }

  log "  appending object file(s): (${obasenames[@]}) => $wdir/_pkg_.a"
  $TOOL_DIR/pack r $wdir/_pkg_.a $ofiles
}

NON_GOOS_LIST="$NON_GOOS|android|ios|illumos|hurd|zos|plan9|windows|aix|dragonfly|freebsd|js|netbsd|openbsd|solaris"
NON_GOARCH_LIST='386|arm[^_]*|loong64|mips[^_]*|ppc64[^_]*|riscv[^_]*|ppc|s390[^_]*|sparc[^_]*|wasm'

function list_maching_files_in_dir() {
  local dir=$1
  local allfiles=$(find $dir -maxdepth 1 -type f \( -name "*.go" -o -name "*.s" \) -printf "%f\n")
  local ary=($allfiles)
  log "  allfiles=(${ary[@]})"
  echo "$allfiles" |\
    grep -v -E '_test\.go' |
    grep -v -E 'go_below_11.\.go' |
    grep -v -E "_(${NON_GOOS_LIST})(\.|_)" |
    grep -v -E "_(${NON_GOARCH_LIST})\.(go|s)"
}

function eval_build_tag() {
  local f=$1
  local matched=$2
  if [[ $matched = "ignore" ]]; then
    # ignore
    return 1
  elif [[ -z $matched ]]; then
    # empty
    return 0
  fi

  _TRUE_="@@@"

  IS_UNIX=""
  if [[ $GOOS = "linux" || $GOOS = "darwin" ]]; then
    IS_UNIX="unix|"
  fi

  logical_expr=$(
    echo $matched \
    | sed -E "s/(${IS_UNIX}$GOOS|$GOARCH|gc)/$_TRUE_/g" \
    | sed -E "s/goexperiment\.(coverageredesign|regabiwrappers|regabiargs|unified)/$_TRUE_/" \
    | sed -E 's/goexperiment\.\w+/false/g' \
    | sed -E 's/[a-zA-Z0-9_\-\.]+/false/g' \
    | sed -E "s/$_TRUE_/true/g" \
    | sed -e 's/!true/false/g' \
    | sed -e 's/!false/true/g' \
    | sed -e 's/^true ||.*/true/' \
    | sed -e 's/^true &&//g' \
    | sed -e 's/^false ||//g' \
    | sed -e 's/^false &&.*/false/g'
  )
  log "    build tag: $f '$matched' => '$logical_expr'"
  eval $logical_expr;
}

function get_build_tag() {
  local fullpath=$1
  set +e
  matched=$(grep -m 1 --only-matching -E '^//go:build .+$' $fullpath)
  set -e
  matched=${matched##"//go:build "}
  echo $matched
}


function find_matching_files() {
  local dir=$1
  local files=$(list_maching_files_in_dir $dir)
  local gofiles=()
  local asfiles=()

  local f
  for f in $files; {
    local fullpath="$dir/$f"
    local tag=$(get_build_tag $fullpath)
    if eval_build_tag "$f" "$tag"; then
      if [[ $fullpath == *.go ]]; then
        gofiles+=($fullpath)
      elif [[ $fullpath == *.s ]]; then
        asfiles+=($fullpath)
      else
        log "something wrong happened"
        exit 1
      fi
    fi
  }
  if (( ${#gofiles[@]} + ${#asfiles[@]} == 0 )); then
    log "ERROR: no files to process"
    return 1
  fi
  echo "${gofiles[@]} ${asfiles[@]}"
}

# Convert absolute filenames to base names.
# The purpose is for log's readability
function abspaths_to_basenames() {
  local paths="$@"
  local files=""
  for path in $paths; {
    file=$(basename $path)
    files="$files $file"
  }
  echo $files
}

function find_depends() {
  local pkg=$1
  local used_from=$2
  if [ -v 'PKGS_DEPEND[$pkg]' ]; then
    return
  fi

  log "[$pkg]"
  log "  used from:" $used_from

  log "  finding package location ..."
  local pkgdir=""
  if [[ $pkg =~ \. ]]; then
    : # non-std lib
    if [[ $pkg = ${MAIN_MODULE}/* ]]; then
      log "  assuming in-module package"
      relpath=${pkg#${MAIN_MODULE}}
      log "relpath=$relpath"
      pkgdir=${MAIN_MODULE_DIR}${relpath}
    elif [[ $pkg = golang.org/x/* ]]; then
      log "  assuming sub std package"
      if [[ -e ./vendor/${pkg} ]]; then
        pkgdir=./vendor/${pkg}
      else
        pkgdir=$GOROOT/src/vendor/$pkg
      fi
    else
      log "  assuming vendor package"
      pkgdir=./vendor/${pkg}
    fi
  else
    log "  assuming std package"
    pkgdir=$(get_std_pkg_dir $pkg)
  fi

  if [[ ! -e $pkgdir ]]; then
    log "[ERROR] directory not found: $pkgdir"
    return 1
  fi

  log "  dir:$pkgdir"
  local files=$(find_matching_files $pkgdir)
  if [[ -z $files ]]; then
    log "ERROR: no files"
    return 1
  fi
  local filenames=$(abspaths_to_basenames $files)
  log "  files: ($filenames)"
  PKGS_FILES[$pkg]="$files"
  local pkgs=($(parse_imports $pkgdir $files))
  log "  imports:(${pkgs[@]})"
  log "  "
  PKGS_DEPEND[$pkg]="${pkgs[@]}"
  for _pkg in "${pkgs[@]}"; {
    find_depends $_pkg $pkg
  }
}


# Make a binary executable
function do_link() {
  local pkg=main
  local wdir=$WORK/${PKGS_ID[$pkg]}
  local pkgsfiles=""
  for p in "${!PKGS_ID[@]}"; {
    pkgsfiles="${pkgsfiles}packagefile ${p}=$WORK/${PKGS_ID[$p]}/_pkg_.a
"
  }
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
  log "# Moving the binary executable"
  log "#"
  log mv $wdir/exe/a.out $OUT_FILE
}

# main procedure
function go_build() {
  mkdir -p $WORK
  rm -f $OUT_FILE

  local pkgpath=$1
  local pkgdir=""
  local toplevelpkg=""
  local buildmode=""

  log "pkgpath='$pkgpath'"
  if [[ $pkgpath == "." ]] || [[ $pkgpath == \.* ]]; then
    # relative path
    log "assuming main package"
    buildmode=exe
    pkgdir=$pkgpath
    toplevelpkg="main"
    if [[ -z $OUT_FILE ]]; then
      OUT_FILE=$(basename $MAIN_MODULE)
    fi

  elif [[ $pkgpath =~ \. ]]; then
    # url like path
    log "[ERROR] unsupported path"
    return 1
  else
    # stdlib style: "foo/bar"
    log "assuming std package"
    buildmode=archive
    pkgdir=$(get_std_pkg_dir $pkgpath)
    toplevelpkg=$pkgpath
  fi

  log "buildmode=$buildmode"
  log ""
  log "#"
  log "# Finding files"
  log "#"
  log "[$toplevelpkg]"
  log "  dir:$pkgdir"
  local files=$(find_matching_files $pkgdir)
  if [[ -z $files ]]; then
    log "ERROR: no files"
    return 1
  fi
  log "  files:" $files
  PKGS_FILES[$toplevelpkg]="$files"
  local pkgs=($(parse_imports $pkgdir $files))
  if [[ $toplevelpkg == "main" && ${#pkgs[@]} -eq 0 ]]; then
    # insert runtime
    pkgs[0]="runtime"
  fi
  log "  imports:(${pkgs[@]})"
  log "  "
  PKGS_DEPEND[$toplevelpkg]="${pkgs[@]}"
  for _pkg in "${pkgs[@]}"; {
    find_depends $_pkg $toplevelpkg
  }

  dump_depend_tree >$WORK/depends.txt
  log ""
  log "#"
  log "# Got dependency tree"
  log "#"
  cat $WORK/depends.txt | sed -e 's/:/ => /g' | tr -d '"' >/dev/stderr
  log ""
  log "#"
  log "# Sorting dependency tree"
  log "#"
  local sorted_pkgs=$(sort_pkgs $WORK/depends.txt | grep -v -E "^${toplevelpkg}\$")

  # Assign package ID number
  local id=2
  for pkg in $sorted_pkgs; {
    id_string=$(printf "%03d" $id)
    PKGS_ID[$pkg]=$id_string
    log "[$id_string] $pkg"
    id=$((id + 1))
  }
  PKGS_ID[$toplevelpkg]="001"
  log "[001] $toplevelpkg"

  log ""
  log "#"
  log "# Compiling packages"
  log "#"
  for pkg in $sorted_pkgs; {
    build_pkg $pkg ${PKGS_FILES[$pkg]}
  }

  log ""
  log "#"
  log "# Compiling the main package"
  log "#"
  build_pkg $toplevelpkg ${PKGS_FILES[$toplevelpkg]}

  if [[ $buildmode = "exe" ]]; then
    log ""
    log "#"
    log "# Linking all packages into a binary executable"
    log "#"
    do_link
  fi
}

# Parse go.mod
declare MAIN_MODULE=""
declare MAIN_MODULE_DIR=$(pwd)
if [[ -e go.mod ]]; then
  MAIN_MODULE=$(grep -E '^module\s+.*' go.mod | awk '{print $2}')
fi

# Parse argv

# go help buildmode:
#	Listed main packages are built into executables and listed
#	non-main packages are built into .a files (the default
#	behavior).
declare OUT_FILE=""
if (( $# >= 1 )); then
  if [[ $1 == "-o" ]]; then
    shift
    OUT_FILE=$1
    shift
  fi
fi

declare ARG
if (( $# >= 1 )); then
  ARG=$1
else
  ARG="."
fi


log "#"
log "# Initial settings"
log "#"
log "GOOS:" $GOOS
log "GOARCH:" $GOARCH
log "main module:" $MAIN_MODULE
log "ARG:" $ARG
log "out file:" $OUT_FILE
log "work dir:" $WORK

go_build "$ARG"
