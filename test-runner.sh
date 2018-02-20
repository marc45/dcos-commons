# Exit immediately on errors
set -e -x

# Export the required environment variables:
export DCOS_ENTERPRISE
export PYTHONUNBUFFERED=1
export SECURITY


REPO_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Determine the list of frameworks if it is not specified
if [ -z "${FRAMEWORK}" -o x"${AUTO_DETECT_FRAMEWORKS}" == x"True" ]; then
    if [ -d "$REPO_ROOT_DIR/frameworks" ]; then
        FRAMEWORK_LIST=$(ls $REPO_ROOT_DIR/frameworks)
    else
        FRAMEWORK_LIST=$(basename ${REPO_ROOT_DIR})
    fi
elif [ "$FRAMEWORK" = "all" ]; then
    if [ -n "$STUB_UNIVERSE_URL" ]; then
        echo "Cannot set \$STUB_UNIVERSE_URL when building all frameworks"
        exit 1
    fi
    # randomize the FRAMEWORK_LIST
    FRAMEWORK_LIST=$(ls $REPO_ROOT_DIR/frameworks | while read -r fw; do printf "%05d %s\n" "$RANDOM" "$fw"; done | sort -n | cut -c7- )
else
    FRAMEWORK_LIST=$FRAMEWORK
fi

# First we need to build the framework(s)
echo "Using FRAMEWORK_LIST: ${FRAMEWORK_LIST}"

if [ -n "$STUB_UNIVERSE_URL" ]; then
    echo "Using provided STUB_UNIVERSE_URL: $STUB_UNIVERSE_URL"
else
    for framework in $FRAMEWORK_LIST; do
        echo "STARTING: $framework"
        FRAMEWORK_DIR=$REPO_ROOT_DIR/frameworks/${framework}

        if [ ! -d ${FRAMEWORK_DIR} -a "${FRAMEWORK}" != "all" ]; then
            echo "FRAMEWORK_DIR=${FRAMEWORK_DIR} does not exist."
            echo "Assuming single framework in ${REPO_ROOT}."
            FRAMEWORK_DIR=${REPO_ROOT_DIR}
        fi

        echo "Starting build for $framework at "`date`
        export UNIVERSE_URL_PATH=${FRAMEWORK_DIR}/${framework}-universe-url
        ${FRAMEWORK_DIR}/build.sh aws
        if [ ! -f "$UNIVERSE_URL_PATH" ]; then
            echo "Missing universe URL file: $UNIVERSE_URL_PATH"
            exit 1
        fi
        if [ -z ${STUB_UNIVERSE_LIST} ]; then
            STUB_UNIVERSE_LIST=$(cat ${UNIVERSE_URL_PATH})
        else
            STUB_UNIVERSE_LIST="${STUB_UNIVERSE_LIST},$(cat ${UNIVERSE_URL_PATH})"
        fi
        echo "Finished build for $framework at "`date`
    done
    export STUB_UNIVERSE_URL=${STUB_UNIVERSE_LIST}
    echo "Using STUB_UNIVERSE_URL: $STUB_UNIVERSE_URL"
fi

# Ensure that the ssh-agent is running:
eval "$(ssh-agent -s)"
if [ -f /ssh/key ]; then
    ssh-add /ssh/key
fi

### ==== TODO: Integrate the following retry logic:
### See https://jira.mesosphere.com/browse/INFINITY-3060
# Make the test cluster
# Make the test cluster
set -e
LAUNCH_SUCCESS="False"
if [ x"$SECURITY" == x"strict" ]; then
    # For the time being, only try to relaunch a cluster on strict mode.
    # This is where we are alerting. If this is successful, then we can move
    # this to the other clusters.
    RETRY_LAUNCH="True"
else
    RETRY_LAUNCH="False"
fi

while [ x"$LAUNCH_SUCCESS" == x"False" ]; do
    dcos-launch create -c /build/config.yaml
    if [ x"$RETRY_LAUNCH" == x"True" ]; then
        set +e
    else
        set -e
    fi
    dcos-launch wait 2>&1 | tee dcos-launch-wait-output.stdout

    # Grep exits with an exit code of 1 if no lines are matched. We thus need to
    # disable exit on errors.
    set +e
    ROLLBACK_FOUND=$(grep -o "Exception: StackStatus changed unexpectedly to: ROLLBACK_IN_PROGRESS" dcos-launch-wait-output.stdout)
    if [ -n "$ROLLBACK_FOUND" ]; then
        # This would be a good place to add some form of alerting!

        # We only retry once!
        RETRY_LAUNCH="False"
        set -e

        # We need to wait for the current stack to be deleted
        dcos-launch delete
        rm -f cluster_info.json
        echo "Cluster creation failed. Retrying after 30 seconds"
        sleep 30
    else
        LAUNCH_SUCCESS="True"
    fi
done
set -e


### ========

# Now create a cluster if it doesn't exist.
if [ -z "$CLUSTER_URL" ]; then
    echo "No DC/OS cluster specified. Attempting to create one now"
    # TODO(elezar) Find the best way to create the config.yaml
    dcos-launch create -c /build/config.yaml
    dcos-launch wait

    export CLUSTER_URL=https://`dcos-launch describe | jq -r .masters[0].public_ip`
    CLUSTER_WAS_CREATED=True
fi

echo "Configuring dcoscli for cluster: $CLUSTER_URL"
echo "\tDCOS_ENTERPRISE=$DCOS_ENTERPRISE"
/build/tools/dcos_login.py

if [ -f cluster_info.json ]; then
    if [ `cat cluster_info.json | jq .key_helper` == 'true' ]; then
        cat cluster_info.json | jq -r .ssh_private_key > /root/.ssh/id_rsa
        chmod 600 /root/.ssh/id_rsa
        ssh-add /root/.ssh/id_rsa
    fi
fi

# Now run the tests:

# Strip the quotes from the -k and -m options to pytest
PYTEST_K_FROM_PYTEST_ARGS=`echo "$PYTEST_ARGS" \
    | sed -e "s#.*-k [\'\"]\([^\'\"]*\)['\"].*#\1#"`
if [ "$PYTEST_K_FROM_PYTEST_ARGS" == "$PYTEST_ARGS" ]; then
    PYTEST_K_FROM_PYTEST_ARGS=
else
    if [ -n "$PYTEST_K" ]; then
        PYTEST_K="$PYTEST_K "
    fi
    PYTEST_K="${PYTEST_K}${PYTEST_K_FROM_PYTEST_ARGS}"
    PYTEST_ARGS=`echo "$PYTEST_ARGS" \
        | sed -e "s#-k [\'\"]\([^\'\"]*\)['\"]##"`
fi

PYTEST_M_FROM_PYTEST_ARGS=`echo "$PYTEST_ARGS" \
    | sed -e "s#.*-m [\'\"]\([^\'\"]*\)['\"].*#\1#"`
if [ "$PYTEST_M_FROM_PYTEST_ARGS" == "$PYTEST_ARGS" ]; then
    PYTEST_M_FROM_PYTEST_ARGS=
else
    if [ -n "$PYTEST_M" ]; then
        PYTEST_M="$PYTEST_M "
    fi
    PYTEST_M="${PYTEST_M}${PYTEST_M_FROM_PYTEST_ARGS}"
    PYTEST_ARGS=`echo "$PYTEST_ARGS" \
        | sed -e "s#-m [\'\"]\([^\'\"]*\)['\"]##"`
fi


pytest_args=()

# PYTEST_K and PYTEST_M are treated as single strings, and should thus be added
# to the pytest_args array in quotes.
if [ -n "$PYTEST_K" ]; then
    pytest_args+=(-k "$PYTEST_K")
fi

if [ -n "$PYTEST_M" ]; then
    pytest_args+=(-m "$PYTEST_M")
fi

# Each of the space-separated parts of PYTEST_ARGS are treated separately.
if [ -n "$PYTEST_ARGS" ]; then
    pytest_args+=($PYTEST_ARGS)
fi

# First in the root.
if [ -d ${REPO_ROOT_DIR}/tests ]; then
    FRAMEWORK_TESTS_DIR=${REPO_ROOT_DIR}/tests
    echo "Starting test for $FRAMEWORK_TESTS_DIR at "`date`
    py.test -vv -s "${pytest_args[@]}" ${FRAMEWORK_TESTS_DIR}
    exit_code=$?
    echo "Finished test for $FRAMEWORK_TESTS_DIR at "`date`
fi

for framework in $FRAMEWORK_LIST; do
    echo "Checking framework ${framework}"
    FRAMEWORK_DIR=$REPO_ROOT_DIR/frameworks/${framework}
    FRAMEWORK_TESTS_DIR=${FRAMEWORK_DIR}/tests
    if [ ! -d ${FRAMEWORK_TESTS_DIR} ]; then
        echo "No tests found for ${framework} at ${FRAMEWORK_TESTS_DIR}"
    else
        echo "Starting test for $FRAMEWORK_TESTS_DIR at "`date`
        py.test -vv -s "${pytest_args[@]}" ${FRAMEWORK_TESTS_DIR}
        exit_code=$?
        echo "Finished test for $FRAMEWORK_TESTS_DIR at "`date`
    fi
done

echo "Finished integration tests at "`date`

if [ -n "$CLUSTER_WAS_CREATED" ]; then
    echo "The DC/OS cluster $CLUSTER_URL was created. Please run"
    echo "\t\$ dcos-launch delete"
    echo "to remove the cluster."
fi

exit $exit_code
