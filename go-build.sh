#!/usr/bin/env bash
#
# Usage: go-build.sh -o BIN_NAME DIR_NAME
#
set -eu

readonly WORK=/tmp/go-build-bash/w/$(date +%s)
readonly CACHE=/tmp/go-build-bash/cache
readonly BUILD_ID=abcdefghijklmnopqrst/abcdefghijklmnopqrst

readonly GOROOT=$(go env GOROOT)
readonly GOVERSION=$(go env GOVERSION)
readonly TOOL_DIR=$(go env GOTOOLDIR)

if [[ ! -v GOARCH || -z $GOARCH ]]; then
  GOARCH=$(go env GOHOSTARCH)
fi

if [[ ! -v GOOS || -z $GOOS ]]; then
  GOOS=$(go env GOHOSTOS)
fi

# For now we support only darwin and linux,
# which means !darwin == linux
if  [[ $GOOS = "darwin" ]]; then
  readonly NON_GOOS="linux"
elif [[ $GOOS = "linux" ]]; then
  readonly NON_GOOS="darwin"
else
  echo "ERROR: unsupported GOOS: $GOOS" >/dev/stderr
  exit 1
fi

readonly ASM_D_GOOS=GOOS_${GOOS}
readonly ASM_D_GOARCH=GOARCH_${GOARCH}

# Use gnu tools for MacOS
if [[ $OSTYPE == "darwin"* ]]; then
  if ! which gfind >/dev/null || ! which gsed >/dev/null; then
    "gfind and gsed commands are required. Please try 'brew install bash findutils gnu-sed coreutils'" >/dev/stderr
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
declare -A PKGS_ID=()        # e.g. "fmt" => "007"
declare -A PKGS_DEPEND=()    # e.g. "fmt" => "os strconv"
declare -A PKGS_FILES=()     # e.g. "fmt" => "print.go foo.go bar.s"

# Parse import declarations from given files
function parse_imports() {
  local -r dir=$1
  shift
  local -r absfiles="$@"

  local -r tmpfile=$WORK/_source_nl_stripped.txt
  cat $absfiles | sed -E 's#//.+##g' | tr '\n' '~' >$tmpfile

  (
    cat $tmpfile |
      grep --only-matching --no-filename -E '~import\s*\([^\)]*\)'

    cat $tmpfile |
      grep --only-matching --no-filename -E '~import\s*[^"]*"[^"]+"'
  ) | grep -E --only-matching '\"[^\"]+\"' | grep -v '"unsafe"' | tr -d '"' | sort | uniq
}

# Print dependency tree of packages
function print_depend_tree() {
  local p v w
  for p in ${!PKGS_DEPEND[@]}; {
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
  local -r infile=$1
  local -r workfile=$WORK/_tmp_sort_pkgs_work.txt
  local -r tmpfile=$WORK/_tmp_sort_pkgs_tmp.txt

  cp $infile $workfile
  local leaves l
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

readonly NON_GOOS_LIST="$NON_GOOS|android|ios|illumos|hurd|zos|plan9|windows|aix|dragonfly|freebsd|js|netbsd|openbsd|solaris"
readonly NON_GOARCH_LIST='386|arm[^_]*|loong64|mips[^_]*|ppc64[^_]*|riscv[^_]*|ppc|s390[^_]*|sparc[^_]*|wasm'

# List source files in a dir and filter them by filename rules
function list_source_files_in_dir() {
  local -r dir=$1
  local -r allfiles=$(find $dir -maxdepth 1 -type f \( -name "*.go" -o -name "*.s" \) -printf "%f\n")
  local -ar ary=($allfiles)
  log "  allfiles: (${ary[@]})"
  local f
  for f in  $allfiles ; {
    if [[ $f = *_test.go ]]; then
      :
    elif [[ $f =~  _(${NON_GOOS_LIST})(\.|_) ]]; then
      :
    elif [[ $f =~ _(${NON_GOARCH_LIST})\.(go|s) ]]; then
      :
    else
      echo $f
    fi
  }
}

readonly _TRUE_="@@@"

# Evaluate logical expressions in the build tag
function eval_build_tag() {
  local -r f=$1 # for logging
  local -r tag=$2
  if [[ $tag = "ignore" ]]; then
    # ignore
    return 1 # false
  elif [[ -z $tag ]]; then
    # empty
    return 0 # true
  fi

  local is_unix=""
  if [[ $GOOS = "linux" || $GOOS = "darwin" ]]; then
    is_unix="unix|"
  fi

  # TODO: goVersion parsing is not correct.
  logical_expr=$(
    echo $tag \
    | sed -E "s/(boringcrypto|gccgo)/ false /g" \
    | sed -E "s/(${is_unix}$GOOS|$GOARCH|gc)/$_TRUE_/g" \
    | sed -E "s/goexperiment\.(coverageredesign|regabiwrappers|regabiargs|unified)/$_TRUE_/" \
    | sed -E 's/goexperiment\.\w+/ false /g' \
    | sed -E "s/go1\.[0-9][0-9]?/${_TRUE_}/g" \
    | sed -E 's/[a-zA-Z0-9_\-\.]+/ false /g' \
    | sed -E "s/$_TRUE_/ true /g" \
    | sed -e 's/!/! /g'
  )
  log "    $f: $logical_expr ($tag)"
  eval $logical_expr;
}

# Parse build tag from source file
function get_build_tag() {
  local -r sourcefile=$1
  local matched=$(grep -m 1 --only-matching -E '^//go:build.+$' $sourcefile)
  if [[ -n $matched ]]; then
    matched=${matched##"//go:build "}
    echo $matched
    return
  fi

  local matched=$(grep -m 1 --only-matching -E '^// *\+build.+$' $sourcefile)
  if [[ -n $matched ]]; then
    matched=$(echo $matched | sed -E 's#^// *\+build##' | tr ',' ' ')
    echo $matched
    return
  fi
}

function debug_build_tag() {
  local files="$@"
  log "  checking build tag ..."
  for f in $files; {
    local tag=$(get_build_tag $f)
    log "    $f: $tag"
    eval_build_tag "$f" "$tag"
  }
}

# select files to compile
function select_source_files() {
  local dir=$1
  local files=$(list_source_files_in_dir $dir)
  local gofiles=()
  local asfiles=()
  log "  checking build tag ..."
  local f
  for f in $files; {
    local sourcefile="$dir/$f"
    local tag=$(get_build_tag $sourcefile)
    if eval_build_tag "$f" "$tag"; then
      if [[ $sourcefile == *.go ]]; then
        gofiles+=($sourcefile)
      elif [[ $sourcefile == *.s ]]; then
        asfiles+=($sourcefile)
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
# Mostly for pretty logging
function abspaths_to_basenames() {
  local paths="$@"
  local files=""
  for path in $paths; {
    file=$(basename $path)
    files="$files $file"
  }
  echo $files
}

# Find dependencies by looking for import decls recursively
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
      log "  package type: in-module"
      relpath=${pkg#${MAIN_MODULE}}
      log "relpath=$relpath"
      pkgdir=${MAIN_MODULE_DIR}${relpath}
    elif [[ $pkg = golang.org/x/* ]]; then
      if [[ -e ./vendor/${pkg} ]]; then
        log "  package type: vendor"
        pkgdir=./vendor/${pkg}
      else
        log "  package type: std"
        pkgdir=$GOROOT/src/vendor/$pkg
      fi
    else
      log "  package type: vendor"
      pkgdir=./vendor/${pkg}
    fi
  else
      log "  package type: std"
    pkgdir=$GOROOT/src/$pkg
  fi

  if [[ ! -e $pkgdir ]]; then
    log "[ERROR] directory not found: $pkgdir"
    return 1
  fi

  log "  dir:$pkgdir"
  local files=$(select_source_files $pkgdir)
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


# Make an importcfg file.
# It contains a list of packages this package directly imports
function make_importcfg() {
  local cfgfile=$1
  shift;
  local pkgs="$@"

  {
    echo '# import config'
    for p in $pkgs; {
      echo "packagefile $p=$WORK/${PKGS_ID[$p]}/_pkg_.a"
    }
  } > $cfgfile
  log "  generating the import config file: $cfgfile"
  log "      ----"
  awk '{$1="      "$1}1' <$cfgfile >/dev/stderr
  log "      ----"
}

# Process embed tags if present
function process_embed() {
  local dir=$1
  local cfgfile=$2
  shift; shift;
  local gofiles=$@
  local matched=$(cat $gofiles | grep -E --only-matching --no-filename '^\s*//go:embed .*'  | sed -e 's#//go:embed ##g' | sed -e 's#//.*##g')
  if [[ -z $matched ]]; then
    return
  fi
  log "  embed tag:" $matched
  local pattern=""
  local -A fileToPath=()
  local -A patterns=() # 'pattern' => '"file1","file2",...'
  local needcomma=""
  for pattern in $matched ; {
    # pattern is either a filename, dirname or glob
    log "  embed_pattern=$pattern"
    local path=$dir/$pattern
    if [[ -f $path ]]; then
      log "  type=file, path=$path"
      local filepath=$(realpath $path)
      patterns[$pattern]="\"$pattern\""
      fileToPath[$pattern]=$filepath
    elif [[ -d $path ]]; then
      log "  embed type=dir"
      local files=$(find $path -type f  -not -name test -printf " %P")
      log "  files=$files"
      needcomma=""
      local pttrns=""
      for f in $files; {
        log "    f=" $f
        local relname=$pattern/$f
        log "    rel=" $relname
        fileToPath[$relname]=$(realpath $path/$f)
        local comma=""
        if [[ -z $needcomma ]]; then
          needcomma="1"
        else
          comma=","
        fi
        pttrns="${pttrns}${comma}\"$relname\""
      }
      patterns[$pattern]=$pttrns
    elif [[ $path =~ \* ]]; then
      log "  embed type=glob"
      local expanded_files=$(echo $path)
      log " expanded=(" $expanded_files ")"
      needcomma=""
      local pttrns=""
      local f
      for f in "$expanded_files"; {
        log "    f=" $f
        local relname=${f##$dir/}
        log "    rel=" $relname
        fileToPath[$relname]=$(realpath $f)
        local comma=""
        if [[ -z $needcomma ]]; then
          needcomma="1"
        else
          comma=","
        fi
        pttrns="${pttrns}${comma}\"$relname\""
      }
      patterns[$pattern]=$pttrns
    else
      log "[ERROR] unexpected embed entity"
      return 1
    fi
  }

  # print json
  {

      echo "{"
      echo ' "Patterns": {'
      needcomma=""
      for pattern in ${!patterns[@]} ; {
        if [[ -z $needcomma ]]; then
          needcomma="1"
        else
          echo -n ","
        fi
        echo "  \"$pattern\": ["
        echo "     ${patterns[$pattern]}"
        echo "   ]"
      }
      echo '  },'

      echo ' "Files": {'
      needcomma=""
      for f in ${!fileToPath[@]} ; {
        if [[ -z $needcomma ]]; then
          needcomma="1"
        else
          echo -n ","
        fi

        echo "  \"$f\":\"${fileToPath[$f]}\""
      }

      echo '  }'
      echo "}"
    } > $cfgfile

}

# Generate symabis file
function gen_symabis() {
  local pkg=$1
  shift
  local asfiles="$@"
  local wdir=$WORK/${PKGS_ID[$pkg]}
  local outfile=$wdir/symabis
  log "  generating the symabis file: $outfile"
  $TOOL_DIR/asm -p $pkg -trimpath "$wdir=>" -I $wdir/ -I $GOROOT/pkg/include -D $ASM_D_GOOS -D $ASM_D_GOARCH -compiling-runtime -D GOAMD64_v1 -gensymabis -o $outfile $asfiles
}

# Assemble ams files and append them to the archive
function append_asm() {
  local pkg=$1
  shift
  local files="$@"

  local wdir=$WORK/${PKGS_ID[$pkg]}
  local ofiles=""
  local obasenames=() # for logging
  local f
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

# Build a package
function build_pkg() {
  local pkg=$1
  shift
  local filenames=($@)
  local pkgdir=$(dirname ${filenames[0]})
  local pkgcachedir=${CACHE}/${GOOS}_${GOARCH}/${pkg}
  local cachefile=$pkgcachedir/_pkg_.a
  local wdir=$WORK/${PKGS_ID[$pkg]}
  local archive=$wdir/_pkg_.a

  log ""
  log "[$pkg]"
  log "  source:" $pkgdir

  # Create a work directory to build the package
  # All outputs are stored into this directory
  log "  mkdir -p $wdir/"
  mkdir -p $wdir/

  # Restore from cache if exists
  if [[ $pkg == "main" ]]; then
    rm -f $cachefile
  fi
  if [[ -f $cachefile ]]; then
    log "  restoring from cache:" $cachefile
    ln -s $cachefile $archive
    return
  fi


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

  make_importcfg $wdir/importcfg ${PKGS_DEPEND[$pkg]}

  local embedcfg=$wdir/embedcfg
  process_embed $pkgdir $embedcfg $gofiles

  # Preparing compile options
  local asmopts=""
  local sruntime=""
  local scomplete=""
  local std=""
  local sstd=""
  local slang=""
  local sembed=""

  if [[ ! $pkg =~ \. ]] && [[ $pkg != "main" ]]; then
    std="1"
  fi

  # If there is any asm files,
  #  generate a symabis file and pass it to the compile option
  if [[ -n $asmfiles ]]; then
    touch $wdir/go_asm.h
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
    if [[ $pkg = "net" || $pkg = "bytes" || $pkg = "os" || $pkg = "sync" || $pkg = "syscall" || $pkg = "internal/poll" || $pkg = "time" || $pkg = "runtime/metrics" || $pkg = "runtime/pprof" || $pkg = "runtime/trace" ]]; then
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

  if [[ -f $embedcfg ]]; then
    sembed="-embedcfg $embedcfg"
  fi
  local pkgopts="-p $pkg -o $archive\
 -trimpath \"$wdir=>\"\
 -buildid $BUILD_ID -goversion $GOVERSION -importcfg $wdir/importcfg $sembed $sruntime $scomplete $sstd $slang $asmopts"

  local compile_opts="$pkgopts -c=4 -nolocalimports -pack "
  log "  compile option:" $compile_opts
  log "  compiling: (${gobasenames[@]})"
  $TOOL_DIR/compile $compile_opts $gofiles
  if [[ -n $asmfiles ]]; then
    append_asm $pkg $asmfiles
  fi
  $TOOL_DIR/buildid -w $archive # internal
  mkdir -p $pkgcachedir
  cp $archive $pkgcachedir
}


# Make a binary executable
function do_link() {
  local pkg=main
  local wdir=$WORK/${PKGS_ID[$pkg]}
  local pkgsfiles=""
  for p in ${!PKGS_ID[@]}; {
    pkgsfiles="${pkgsfiles}packagefile ${p}=$WORK/${PKGS_ID[$p]}/_pkg_.a
"
  }
  cat >$wdir/importcfg.link <<EOF # internal
$pkgsfiles
modinfo "0w\xaf\f\x92t\b\x02A\xe1\xc1\a\xe6\xd6\x18\xe6path\tgithub.com/DQNEO/go-build-bash\nmod\tgithub.com/DQNEO/go-build-bash\t(devel)\t\nbuild\t-buildmode=exe\nbuild\t-compiler=gc\nbuild\tCGO_ENABLED=0\nbuild\tGOARCH=amd64\nbuild\tGOOS=linux\nbuild\tGOAMD64=v1\nbuild\tvcs=git\nbuild\tvcs.revision=a721858f4c22cb178c3f3853f9c55aa3773afc2c\nbuild\tvcs.time=2023-06-02T12:08:04Z\nbuild\tvcs.modified=true\n\xf92C1\x86\x18 r\x00\x82B\x10A\x16\xd8\xf2"
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

  log ""
  log "#"
  log "# Detecting build mode"
  log "#"

  log "  pkgpath='$pkgpath'"
  if [[ $pkgpath ==  ./vendor/* ]]; then
    # relative path
    log "  assuming vendor package"
    buildmode=archive
    pkgdir=$pkgpath
    toplevelpkg=${pkgpath##./vendor/}
  elif [[ $pkgpath == "." || $pkgpath == \.* ]]; then
    # relative path
    log "  relative path"
    buildmode="" # decided later
    toplevelpkg=""
    pkgdir=$pkgpath
    if [[ -z $OUT_FILE ]]; then
      OUT_FILE=$(basename $MAIN_MODULE)
    fi
  elif [[ $pkgpath =~ \. ]]; then
    # url like path
    log "[ERROR] unsupported path"
    return 1
  else
    # stdlib style: "foo/bar"
    log "  assuming std package"
    buildmode=archive
    pkgdir=$GOROOT/src/$pkgpath
    toplevelpkg=$pkgpath
  fi

  local files=$(select_source_files $pkgdir)
  if [[ -z $files ]]; then
    log "ERROR: no files"
    return 1
  fi

  local -a _current_files=( $files )
  if [[ -z $toplevelpkg ]]; then
    toplevelpkg=$(grep -E '^package ' ${_current_files[0]} | awk '{print $2}')
    if [[ $toplevelpkg == "main" ]]; then
      buildmode="exe"
    else
      buildmode="archive"
    fi
  fi

  log ""
  log "buildmode: $buildmode"

  log ""
  log "#"
  log "# Finding packages recursively"
  log "#"
  log "[$toplevelpkg]"
  log "  dir: $pkgdir"
  log "  files:" $files

  PKGS_FILES[$toplevelpkg]="$files"
  local -a pkgs=($(parse_imports $pkgdir $files))
  if [[ $toplevelpkg == "main" && ${#pkgs[@]} -eq 0 ]]; then
    # insert runtime
    pkgs[0]="runtime"
  fi
  log "  imports:(${pkgs[@]})"
  log "  "
  PKGS_DEPEND[$toplevelpkg]="${pkgs[@]}"
  local _pkg
  for _pkg in "${pkgs[@]}"; {
    find_depends $_pkg $toplevelpkg
  }

  print_depend_tree >$WORK/depends.txt
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
  for _pkg in $sorted_pkgs; {
    id_string=$(printf "%03d" $id)
    PKGS_ID[$_pkg]=$id_string
    log "[$id_string] $_pkg"
    id=$((id + 1))
  }
  PKGS_ID[$toplevelpkg]="001"
  log "[001] $toplevelpkg"

  log ""
  log "#"
  log "# Compiling packages"
  log "#"
  for _pkg in $sorted_pkgs; {
    build_pkg $_pkg ${PKGS_FILES[$_pkg]}
  }

  log ""
  log "#"
  log "# Compiling the top level package"
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
  # module root
  MAIN_MODULE=$(grep -E '^module\s+.*' go.mod | awk '{print $2}')
  go mod vendor
fi

# Parse argv
# Check special debug flags
if (( $# >= 1 )); then
  if [[ $1 = "--debug-embed" ]]; then
    # examples:
    # /usr/local/opt/go/libexec/src/crypto/internal/nistec/p256_asm.go
    # ./examples/kubectl/vendor/k8s.io/kubectl/pkg/util/i18n/i18n.go
    # ./examples/kubectl/vendor/k8s.io/kubectl/pkg/explain/v2/template.go
    declare debug_embed_filepath=$2 # pass a go file
    declare debug_embed_dir=$(dirname $debug_embed_filepath)
    #set -x
    process_embed $debug_embed_dir /dev/stderr $debug_embed_filepath
    exit 0
  elif [[ $1 = "--debug-tag" ]]; then
    shift;
    debug_build_tag "$@" # pass go files
    exit 0
  elif [[ $1 = "--debug-select-files" ]]; then
    select_source_files $2 # pass a directory
    exit 0
  fi
fi


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
