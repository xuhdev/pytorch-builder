# meant to be called only from the neighboring build.sh and build_cpu.sh scripts

set -ex
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

# TODO move this into the Docker images
retry yum install -q -y zip openssl

# We use the package name to test the package by passing this to 'pip install'
# This is the env variable that setup.py uses to name the package. Note that
# pip 'normalizes' the name first by changing all - to _
if [[ -z "$TORCH_PACKAGE_NAME" ]]; then
    TORCH_PACKAGE_NAME='torch'
fi
TORCH_PACKAGE_NAME="$(echo $TORCH_PACKAGE_NAME | tr '-' '_')"
echo "Expecting the built wheels to all be called '$TORCH_PACKAGE_NAME'"

# Version: setup.py uses $PYTORCH_BUILD_VERSION.post$PYTORCH_BUILD_NUMBER if
# PYTORCH_BUILD_NUMBER > 1
build_version="$PYTORCH_BUILD_VERSION"
build_number="$PYTORCH_BUILD_NUMBER"
if [[ -n "$OVERRIDE_PACKAGE_VERSION" ]]; then
    # This will be the *exact* version, since build_number<1
    build_version="$OVERRIDE_PACKAGE_VERSION"
    build_number=0
fi
if [[ -z "$build_version" ]]; then
    build_version=1.0.0
fi
if [[ -z "$build_number" ]]; then
    build_number=1
fi
export PYTORCH_BUILD_VERSION=$build_version
export PYTORCH_BUILD_NUMBER=$build_number

export CMAKE_LIBRARY_PATH="/opt/intel/lib:/lib:$CMAKE_LIBRARY_PATH"
export CMAKE_INCLUDE_PATH="/opt/intel:$CMAKE_INCLUDE_PATH"

# If given a python version like 3.6m or 2.7mu, convert this to the format we
# expect. The binary CI jobs pass in python versions like this; they also only
# ever pass one python version, so we assume that DESIRED_PYTHON is not a list
# in this case
if [[ -n "$DESIRED_PYTHON" && "$DESIRED_PYTHON" != cp* ]]; then
    if [[ "$DESIRED_PYTHON" == '2.7mu' ]]; then
      DESIRED_PYTHON='cp27-cp27mu'
    else
      python_nodot="$(echo $DESIRED_PYTHON | tr -d m.u)"
      DESIRED_PYTHON="cp${python_nodot}-cp${python_nodot}m"
    fi
fi


# Build for given Python versions, or for all in /opt/python if none given
if [[ -z "$DESIRED_PYTHON" ]]; then
    pushd /opt/python
    DESIRED_PYTHON=(*/)
    popd
fi
python_installations=()
for desired_py in "${DESIRED_PYTHON[@]}"; do
    python_installations+=("/opt/python/$desired_py")
    if [[ ! -d "/opt/python/$desired_py" ]]; then
        echo "Error: Given Python $desired_py is not in /opt/python"
        echo "All array elements of env variable DESIRED_PYTHON must be"
        echo "valid Python installations under /opt/python"
        exit 1
    fi
done
echo "Will build for all Pythons versions: ${DESIRED_PYTHON[@]}"

mkdir -p /tmp/$WHEELHOUSE_DIR
# clone pytorch source code
pytorch_rootdir="/pytorch"
if [[ ! -d "$pytorch_rootdir" ]]; then
    git clone https://github.com/pytorch/pytorch $pytorch_rootdir
    pushd $pytorch_rootdir
    if ! git checkout v${PYTORCH_BUILD_VERSION}; then
          git checkout tags/v${PYTORCH_BUILD_VERSION}
    fi
else
    pushd $pytorch_rootdir
fi
git submodule update --init --recursive


# ########################################################
# # Compile wheels as well as libtorch
# #######################################################
OLD_PATH=$PATH
for PYDIR in "${python_installations[@]}"; do
    export PATH=$PYDIR/bin:$OLD_PATH
    python setup.py clean
    retry pip install -qr requirements.txt
    if [[ $PYDIR  == "/opt/python/cp37-cp37m" ]]; then
        retry pip install -q numpy==1.15
    else
        retry pip install -q numpy==1.11
    fi
    echo "Calling setup.py bdist at $(date)"
    time CMAKE_ARGS=${CMAKE_ARGS[@]} \
         EXTRA_CAFFE2_CMAKE_FLAGS=${EXTRA_CAFFE2_CMAKE_FLAGS[@]} \
         python setup.py bdist_wheel -d /tmp/$WHEELHOUSE_DIR
    echo "Finished setup.py bdist at $(date)"
done

LIBTORCH_VARIANTS=(
    shared-with-deps
    shared-without-deps
    static-with-deps
    static-without-deps
)

# Build libtorch packages
if [[ -n "$BUILD_PYTHONLESS" ]]; then
    for VARIANT in ${LIBTORCH_VARIANTS[@]}; do
        # Now build pythonless libtorch
        # Note - just use whichever python we happen to be on
        python setup.py clean

        if [[ $VARIANT = *"static"* ]]; then
            STATIC_CMAKE_FLAG="-DTORCH_STATIC=1"
        fi

        mkdir -p build
        pushd build
        echo "Calling tools/build_libtorch.py at $(date)"
        time CMAKE_ARGS=${CMAKE_ARGS[@]} \
             EXTRA_CAFFE2_CMAKE_FLAGS="${EXTRA_CAFFE2_CMAKE_FLAGS[@]} $STATIC_CMAKE_FLAG" \
             python ../tools/build_libtorch.py
        echo "Finished tools/build_libtorch.py at $(date)"
        popd

        mkdir -p libtorch/{lib,bin,include,share}
        cp -r build/build/lib libtorch/

        # for now, the headers for the libtorch package will just be copied in
        # from one of the wheels
        ANY_WHEEL=$(ls /tmp/$WHEELHOUSE_DIR/torch*.whl | head -n1)
        unzip -d any_wheel $ANY_WHEEL
        if [[ -d any_wheel/torch/include ]]; then
            cp -r any_wheel/torch/include libtorch/
        else
            cp -r any_wheel/torch/lib/include libtorch/
        fi
        cp -r any_wheel/torch/share/cmake libtorch/share/
        rm -rf any_wheel

        echo $PYTORCH_BUILD_VERSION > libtorch/build-version
        echo "$(pushd $pytorch_rootdir && git rev-parse HEAD)" > libtorch/build-hash

        mkdir -p /tmp/$LIBTORCH_HOUSE_DIR
        zip -rq /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$VARIANT-$PYTORCH_BUILD_VERSION.zip libtorch
        cp /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$VARIANT-$PYTORCH_BUILD_VERSION.zip \
           /tmp/$LIBTORCH_HOUSE_DIR/libtorch-$VARIANT-latest.zip
    done
fi

popd

#######################################################################
# ADD DEPENDENCIES INTO THE WHEEL
#
# auditwheel repair doesn't work correctly and is buggy
# so manually do the work of copying dependency libs and patchelfing
# and fixing RECORDS entries correctly
######################################################################

fname_with_sha256() {
    HASH=$(sha256sum $1 | cut -c1-8)
    DIRNAME=$(dirname $1)
    BASENAME=$(basename $1)
    if [[ $BASENAME == "libnvrtc-builtins.so" ]]; then
        echo $1
    else
        INITNAME=$(echo $BASENAME | cut -f1 -d".")
        ENDNAME=$(echo $BASENAME | cut -f 2- -d".")
        echo "$DIRNAME/$INITNAME-$HASH.$ENDNAME"
    fi
}

make_wheel_record() {
    FPATH=$1
    if echo $FPATH | grep RECORD >/dev/null 2>&1; then
        # if the RECORD file, then
        echo "$FPATH,,"
    else
        HASH=$(openssl dgst -sha256 -binary $FPATH | openssl base64 | sed -e 's/+/-/g' | sed -e 's/\//_/g' | sed -e 's/=//g')
        FSIZE=$(ls -nl $FPATH | awk '{print $5}')
        echo "$FPATH,sha256=$HASH,$FSIZE"
    fi
}

echo 'Built these wheels:'
ls /tmp/$WHEELHOUSE_DIR
mkdir -p "/$WHEELHOUSE_DIR"
mv /tmp/$WHEELHOUSE_DIR/torch*linux*.whl /$WHEELHOUSE_DIR/
if [[ -n "$BUILD_PYTHONLESS" ]]; then
    mkdir -p /$LIBTORCH_HOUSE_DIR
    mv /tmp/$LIBTORCH_HOUSE_DIR/*.zip /$LIBTORCH_HOUSE_DIR
    rm -rf /tmp/$LIBTORCH_HOUSE_DIR
fi
rm -rf /tmp/$WHEELHOUSE_DIR
rm -rf /tmp_dir
mkdir /tmp_dir
pushd /tmp_dir

for pkg in /$WHEELHOUSE_DIR/torch*linux*.whl /$LIBTORCH_HOUSE_DIR/libtorch*.zip; do

    # if the glob didn't match anything
    if [[ ! -e $pkg ]]; then
        continue
    fi

    rm -rf tmp
    mkdir -p tmp
    cd tmp
    cp $pkg .

    unzip -q $(basename $pkg)
    rm -f $(basename $pkg)

    if [[ -d torch ]]; then
        PREFIX=torch
    else
        PREFIX=libtorch
    fi

    if [[ $pkg != *"without-deps"* ]]; then
        # copy over needed dependent .so files over and tag them with their hash
        patched=()
        for filepath in "${DEPS_LIST[@]}"; do
            filename=$(basename $filepath)
            destpath=$PREFIX/lib/$filename
            if [[ "$filepath" != "$destpath" ]]; then
                cp $filepath $destpath
            fi

            patchedpath=$(fname_with_sha256 $destpath)
            patchedname=$(basename $patchedpath)
            if [[ "$destpath" != "$patchedpath" ]]; then
                mv $destpath $patchedpath
            fi
            patched+=("$patchedname")
            echo "Copied $filepath to $patchedpath"
        done

        echo "patching to fix the so names to the hashed names"
        for ((i=0;i<${#DEPS_LIST[@]};++i)); do
            find $PREFIX -name '*.so*' | while read sofile; do
                origname=${DEPS_SONAME[i]}
                patchedname=${patched[i]}
                if [[ "$origname" != "$patchedname" ]]; then
                    set +e
                    patchelf --print-needed $sofile | grep $origname 2>&1 >/dev/null
                    ERRCODE=$?
                    set -e
                    if [ "$ERRCODE" -eq "0" ]; then
                        echo "patching $sofile entry $origname to $patchedname"
                        patchelf --replace-needed $origname $patchedname $sofile
                    fi
                fi
            done
        done
    fi

    # set RPATH of _C.so and similar to $ORIGIN, $ORIGIN/lib
    find $PREFIX -maxdepth 1 -type f -name "*.so*" | while read sofile; do
        echo "Setting rpath of $sofile to " '$ORIGIN:$ORIGIN/lib'
        patchelf --set-rpath '$ORIGIN:$ORIGIN/lib' $sofile
        patchelf --print-rpath $sofile
    done

    # set RPATH of lib/ files to $ORIGIN
    find $PREFIX/lib -maxdepth 1 -type f -name "*.so*" | while read sofile; do
        echo "Setting rpath of $sofile to " '$ORIGIN'
        patchelf --set-rpath '$ORIGIN' $sofile
        patchelf --print-rpath $sofile
    done


    # regenerate the RECORD file with new hashes
    record_file=`echo $(basename $pkg) | sed -e 's/-cp.*$/.dist-info\/RECORD/g'`
    if [[ -e $record_file ]]; then
        echo "Generating new record file $record_file"
        rm -f $record_file
        # generate records for folders in wheel
        find * -type f | while read fname; do
            echo $(make_wheel_record $fname) >>$record_file
        done
    fi

    # zip up the wheel back
    zip -rq $(basename $pkg) $PREIX*

    # replace original wheel
    rm -f $pkg
    mv $(basename $pkg) $pkg
    cd ..
    rm -rf tmp
done

# Copy wheels to host machine for persistence before testing
if [[ -n "$PYTORCH_FINAL_PACKAGE_DIR" ]]; then
    mkdir -p "$PYTORCH_FINAL_PACKAGE_DIR" || true
    if [[ -n "$BUILD_PYTHONLESS" ]]; then
        cp /$LIBTORCH_HOUSE_DIR/libtorch*.zip "$PYTORCH_FINAL_PACKAGE_DIR"
    else
        cp /$WHEELHOUSE_DIR/torch*.whl "$PYTORCH_FINAL_PACKAGE_DIR"
    fi
fi

# remove stuff before testing
rm -rf /opt/rh
if ls /usr/local/cuda* >/dev/null 2>&1; then
    rm -rf /usr/local/cuda*
fi


# Test that all the wheels work
if [[ -z "$BUILD_PYTHONLESS" ]]; then
  export OMP_NUM_THREADS=4 # on NUMA machines this takes too long
  pushd $pytorch_rootdir/test
  for (( i=0; i<"${#DESIRED_PYTHON[@]}"; i++ )); do
    # This assumes that there is a 1:1 correspondence between python versions
    # and wheels, and that the python version is in the name of the wheel,
    # and that the python version matches the regex "cp\d\d-cp\d\dmu?"
    pydir="${python_installations[i]}"
    curpip="${pydir}/bin/pip"
    curpy="${pydir}/bin/python"
    pyver="${DESIRED_PYTHON[i]}"
    pyver_short="${pyver:2:1}.${pyver:3:1}"

    # Install the wheel for this Python version
    "$curpip" uninstall -y "$TORCH_PACKAGE_NAME"
    "$curpip" install "$TORCH_PACKAGE_NAME" --no-index -f /$WHEELHOUSE_DIR --no-dependencies -v

    # Print info on the libraries installed in this wheel
    installed_libraries=($(find "$pydir/lib/python$pyver_short/site-packages/torch/" -name '*.so*'))
    echo "The wheel installed all of the libraries: ${installed_libraries[@]}"
    for installed_lib in "${installed_libraries[@]}"; do
        ldd "$installed_lib"
    done

    # Run the tests
    echo "$(date) :: Running tests"
    pushd "$pytorch_rootdir"
    LD_LIBRARY_PATH=/usr/local/nvidia/lib64 \
            PYCMD="$curpy" \
            "${SOURCE_DIR}/../run_tests.sh" 'manywheel' "$pyver_short" "$DESIRED_CUDA"
    popd
    echo "$(date) :: Finished tests"
  done
fi
