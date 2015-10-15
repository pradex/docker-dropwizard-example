#!/bin/bash -e

#
# Downloads the latest Cloud Debugger agent and formats Java "-agentpath:..."
# command line option to enable Java Cloud Debugger in Google Compute Engine
# runtime environment.
#
# This script guarantees two properties:
# 1. All service instances use exactly the same version of Cloud Debugger agent.
#    Cloud Debugger requires that all instances a service must use the same
#    version of the Cloud Debugger agent.
# 2. When deploying a new version of the service, the latest Cloud Debugger
#    agent is used.
#
# TODO(vlif): link to public documentation
#
# Dependencies:
# 1. getopt
# 2. wget
# 3. md5sum
#

# Default parameter values.
VERBOSE=0
APP_DIRS=
MODULE=
VERSION=
GCS_BUCKET_PREFIX="cdbg-agent_"
AGENT_PATH="/opt/cdbg"
RETRY_ATTEMPTS=5
SKIP_DOWNLOAD=0
AGENT_LOGS_DIR="/tmp"
ENABLE_SERVICE_ACCOUNT_AUTH=0
PROJECT_ID=
PROJECT_NUMBER=
SERVICE_ACCOUNT_EMAIL=
SERVICE_ACCOUNT_P12_FILE=
TEST_MODE=0

# Helper constants.
METADATA_HEADER="Metadata-Flavor: Google"
STORAGE_API_BASE="https://www.googleapis.com"

# Trims leading and trailing whitespaces from the argument strings
function TrimWhitespaces() {
  echo "$@" | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g'
}

# Prints the argument string to standard error output if verbose logging option
# is enabled.
function VerboseLog() {
  if [[ VERBOSE -eq 1 ]]; then
    echo "$@" >&2
  fi
}

# Computes hash of all application files and the version tuple.
function ComputeHash() {
  if [[ -n "${APP_DIRS}" ]]; then
    local APP_FILES_HASH=$( find ${APP_DIRS} -type f -follow -print | sort | xargs md5sum -b | awk '{print $1}' )
  else
    local APP_FILES_HASH=""
  fi
  APP_FILES_HASH+="Project ID: ${PROJECT_ID}, module: ${MODULE}, version: ${VERSION}, service_account: ${ENABLE_SERVICE_ACCOUNT_AUTH}"
  VERSION_HASH="$( echo ${APP_FILES_HASH} | md5sum -b -  | awk '{print $1}' )"

  VerboseLog "Version hash: ${VERSION_HASH}"
}

# Reads OAuth token and project information from local metadata service or
# exchange private key for access token if service account authentication was
# enabled in command line options.
function ReadProjectMetadata() {
  if [[ ENABLE_SERVICE_ACCOUNT_AUTH -eq 0 ]]; then
    VerboseLog "Querying metadata service"

    local METADATA_URL="http://metadata.google.internal/computeMetadata/v1"

    OAUTH_TOKEN="$( wget -q -O - --no-cookies --header "${METADATA_HEADER}" "${METADATA_URL}/instance/service-accounts/default/token" | \
                    sed -e 's/.*"access_token"\ *:\ *"\([^"]*\)".*$/\1/g' )"
    PROJECT_ID="$( wget -q -O - --no-cookies --header "${METADATA_HEADER}" "${METADATA_URL}/project/project-id" )"
    PROJECT_NUMBER="$( wget -q -O - --no-cookies --header "${METADATA_HEADER}" "${METADATA_URL}/project/numeric-project-id" )"

    VerboseLog "Project ID: ${PROJECT_ID}"
    VerboseLog "Project number: ${PROJECT_NUMBER}"
  else
    VerboseLog "Exchanging service account private key for OAuth access token"

    mkdir -p ${AGENT_PATH}

    if [[ -s "${AGENT_PATH}/cdbg_auth_tool.jar" ]]; then
      VerboseLog "${AGENT_PATH}/cdbg_auth_tool.jar already exists"
    else
      local SERVICE_ACCOUNT_AUTH_TOOL_URL="http://storage.googleapis.com/cloud-debugger/compute-java/cdbg_service_account_auth.jar"
      wget -q -O "${AGENT_PATH}/cdbg_auth_tool.jar" "${SERVICE_ACCOUNT_AUTH_TOOL_URL}"
    fi

    # If cdbg_auth_tool.jar fails to get OAuth token, it will print exception
    # information to stderr and will exit with return code of 1.
    OAUTH_TOKEN="$( java -jar ${AGENT_PATH}/cdbg_auth_tool.jar ${SERVICE_ACCOUNT_EMAIL} ${SERVICE_ACCOUNT_P12_FILE} )"
  fi

  AUTH_HEADER="Authorization: Bearer ${OAUTH_TOKEN}"
  VerboseLog "OAuth token: ${OAUTH_TOKEN}"
}

# Creates storage bucket for the Cloud Debugger if one doesn't already exists
# and verifies that the bucket belongs to this GCP project.
function CreateGcsBucket() {
  BUCKET_NAME="${GCS_BUCKET_PREFIX}${PROJECT_ID}"

  echo "Creating GCS bucket ${BUCKET_NAME}"

  local CREATE_BUCKET_JSON_REQUEST="{ \"name\": \"${BUCKET_NAME}\" }"
  local CREATE_BUCKET_URL="${STORAGE_API_BASE}/storage/v1/b?project=${PROJECT_ID}&predefinedAcl=projectPrivate&projection=noAcl"
  wget -nv -O - --post-data "${CREATE_BUCKET_JSON_REQUEST}" --header "${AUTH_HEADER}" --header "Content-Type:application/json" "${CREATE_BUCKET_URL}" || true

  echo "Verifying that bucket ${BUCKET_NAME} belongs to GCP project ${PROJECT_ID}"

  local QUERY_BUCKET_URL="${STORAGE_API_BASE}/storage/v1/b/${BUCKET_NAME}"
  local BUCKET_INFO="$( wget -q -O - --no-cookies --header "${AUTH_HEADER}" "${QUERY_BUCKET_URL}" )"

  echo "Bucket ${BUCKET_NAME} info: ${BUCKET_INFO}"

  if [[ ! "${BUCKET_INFO}" =~ \"projectNumber\":\ *\"${PROJECT_NUMBER}\" ]]; then
    echo "Bucket could not be created or belongs to another GCP project"
    exit 1
  fi

  echo "GCS bucket ${BUCKET_NAME} is ready"
}

# If the agent binary doesn't exist in the storage bucket, uploads the latest
# version to the current version directory. If the agent binary is already
# there, does nothing. This operation is atomic: the same binary version will
# be used on each instance even if multiple instances of this script are running
# concurrently.
function SaveCloudDebuggerAgentLatestVersion() {
  local SOURCE_BUCKET="cloud-debugger"
  if [[ ENABLE_SERVICE_ACCOUNT_AUTH -eq 0 ]]; then
    local SOURCE_OBJECT="compute-java/debian-wheezy/cdbg_java_agent_gce.tar.gz"
  else
    local SOURCE_OBJECT="compute-java/debian-wheezy/cdbg_java_agent_service_account.tar.gz"
  fi
  local DESTINATION_BUCKET="${BUCKET_NAME}"
  local DESTINATION_OBJECT="${VERSION_HASH}/cdbg_java_agent.tar.gz"

  echo "Copying agent binary from gs://${SOURCE_BUCKET}/${SOURCE_OBJECT} to gs://${DESTINATION_BUCKET}/${DESTINATION_OBJECT}"

  local COPY_OBJECT_URL="${STORAGE_API_BASE}/storage/v1/b/${SOURCE_BUCKET}/o/${SOURCE_OBJECT//\//%2F}/copyTo/b/${DESTINATION_BUCKET}/o/${DESTINATION_OBJECT//\//%2F}?ifGenerationMatch=0"
  wget -nv -O - --post-data "{}" --header "${AUTH_HEADER}" --header "Content-Type:application/json" "${COPY_OBJECT_URL}"
}

# Download and unpack the agent binary on the local drive.
function DownloadCloudDebuggerAgent() {
  local SOURCE="https://storage.googleapis.com/${BUCKET_NAME}/${VERSION_HASH}/cdbg_java_agent.tar.gz"
  local DESTINATION="${AGENT_PATH}/cdbg_java_agent-${VERSION_HASH}.tar.gz"

  echo "Trying to download the agent binary from ${SOURCE}"

  mkdir -p ${AGENT_PATH}

  local DOWNLOAD_FAILED=0
  wget -nv -O "${DESTINATION}" --header "${AUTH_HEADER}" "${SOURCE}" || DOWNLOAD_FAILED=1
  if [[ DOWNLOAD_FAILED -eq 1 ]]; then
    rm -f "${DESTINATION}"
    return 1
  fi

  # TODO(vlif): verify digital signature.

  mkdir -p ${AGENT_PATH}/${VERSION_HASH}
  tar xzf ${AGENT_PATH}/cdbg_java_agent-${VERSION_HASH}.tar.gz -C ${AGENT_PATH}/${VERSION_HASH}

  echo "Agent binaries extracted to ${AGENT_PATH}/${VERSION_HASH}"
}

# Single retry loop for PrepareCloudDebuggerAgent.
function TryPrepareCloudDebuggerAgent() {
  # It is important to call CreateGcsBucket before the attempt to download
  # the package. CreateGcsBucket verifies that the storage bucket belongs to
  # this project. Exits the script if it doesn't. Downloading from the GCE
  # bucket before this validation is not safe.
  CreateGcsBucket

  local NEED_COPY=0
  DownloadCloudDebuggerAgent || NEED_COPY=1
  if [[ NEED_COPY -eq 1 ]]; then
    SaveCloudDebuggerAgentLatestVersion
    DownloadCloudDebuggerAgent
  fi
}

# Applies all the storage manipulations explained above. Retries several times
# in case of an error. Errors may occur either due to GCS unavailability or
# due to race conditions when multiple instances of the script are executed
# at the same time. In either case this function handles these situations
# correctly.
function PrepareCloudDebuggerAgent() {
  if [[ SKIP_DOWNLOAD -eq 1 ]]; then
    return
  fi

  local ATTEMPT=0
  while [[ ATTEMPT -lt RETRY_ATTEMPTS ]]; do
    local PREPARE_FAILED=0

    if [[ VERBOSE -eq 1 ]]; then
      TryPrepareCloudDebuggerAgent 1>&2 || PREPARE_FAILED=1
    else
      TryPrepareCloudDebuggerAgent >> /dev/null 2>&1 || PREPARE_FAILED=1
    fi

    if [[ PREPARE_FAILED -eq 0 ]]; then
      return
    fi

    ATTEMPT=$[$ATTEMPT+1]

    VerboseLog "Failed to prepare the Cloud Debugger agent, attempt: ${ATTEMPT}"

    sleep 1
  done
}

function FormatCommandLine() {
  local AGENT_DIR="${AGENT_PATH}/${VERSION_HASH}"

  ARGS=
  if [[ -f "${AGENT_DIR}/cdbg_java_agent.so" ]]; then
    ARGS="-agentpath:${AGENT_DIR}/cdbg_java_agent.so="
    ARGS+="--log_dir=${AGENT_LOGS_DIR}"
    ARGS+=",--logtostderr=false"
    ARGS+=",--cdbg_agentdir=${AGENT_DIR}"
    ARGS+=",--cdbg_description_suffix="
    if [[ -n "${MODULE}" ]]; then
      ARGS+="-${MODULE}"
    fi
    if [[ -n "${VERSION}" ]]; then
      ARGS+="-${VERSION}"
    fi
    ARGS+=",--cdbg_extra_class_path=${APP_DIRS//[ ]/:}"
    if [[ -n "${CDBG_CONTROLLER}" ]]; then
      ARGS+=",--cdbg_controller=${CDBG_CONTROLLER}"
    fi
    if [[ ENABLE_SERVICE_ACCOUNT_AUTH -eq 1 ]]; then
      ARGS+=",--enable_service_account_auth=true"
      ARGS+=",--project_id=${PROJECT_ID}"
      ARGS+=",--project_number=${PROJECT_NUMBER}"
      ARGS+=",--service_account_email=${SERVICE_ACCOUNT_EMAIL}"
      ARGS+=",--service_account_p12_file=${SERVICE_ACCOUNT_P12_FILE}"
    fi
  else
    VerboseLog "Cloud Debugger agent not found: ${AGENT_DIR}/cdbg_java_agent.so"
  fi
}

function DisplayUsage() {
  echo "Bootstrap script to enable Cloud Debugger on a Java application
running on Google Compute Engine.

Please refer to TODO(vlif) for usage guide.

Required arguments:
  --app_class_path <directory>
      specifies directory with application Java class files (this argument
      can be specified multiple times)

  --version <version>
      application major version

Optional arguments:
  --module <module>
      application module

  --gcs_buclet_prefix <prefix>
      prefix for GCS bucket name to use (default: ${GCS_BUCKET_PREFIX})

  --retry_attempts <n>
      sets the number of retry attempts to copy and download the Cloud
      Debugger agent (default: ${RETRY_ATTEMPTS})

  --skip_download
      only formats the command line argument assuming this script has
      been already called to download the agent

  --agent_logs_dir <dir>
      local directory for Cloud Debugger agent logs
      (default: ${AGENT_LOGS_DIR})

  --agent_path <dir>
      local directory to store the Cloud Debugger agent
      (default: ${AGENT_PATH})

  --enable_service_account_auth
      instructs the Cloud Debugger agent to use private key authentication
      instead of querying the metadata server

  --project_id <id>
      GCP project ID in which the service account was created
      (only relevant if enable_service_account_auth was specified)

  --project_number <n>
      Project number of the project specified with --project_id
      (only relevant if enable_service_account_auth was specified)

  --service_account_email <email>
      Identifies the service account
      (only relevant if enable_service_account_auth was specified)

  --service_account_p12_file <path>
      Path to the file containing service account private key
      (only relevant if enable_service_account_auth was specified)

  --env <path>
      Runs a script to set configuration options. This can be used to
      configure the debugger from file rather than command line.

  --verbose
      enables verbose logging to standard error output

  -h | --help | --?
      displays this help message" >&2
}

function PrintConfig() {
  VerboseLog "VERBOSE=${VERBOSE}"
  VerboseLog "APP_DIRS=\"${APP_DIRS}\""
  VerboseLog "MODULE=\"${MODULE}\""
  VerboseLog "VERSION=\"${VERSION}\""
  VerboseLog "AGENT_PATH=\"${AGENT_PATH}\""
  VerboseLog "GCS_BUCKET_PREFIX=\"${GCS_BUCKET_PREFIX}\""
  VerboseLog "RETRY_ATTEMPTS=\"${RETRY_ATTEMPTS}\""
  VerboseLog "SKIP_DOWNLOAD=\"${SKIP_DOWNLOAD}\""
  VerboseLog "AGENT_LOGS_DIR=\"${AGENT_LOGS_DIR}\""
  VerboseLog "ENABLE_SERVICE_ACCOUNT_AUTH=${ENABLE_SERVICE_ACCOUNT_AUTH}"
  VerboseLog "PROJECT_ID=\"${PROJECT_ID}\""
  VerboseLog "PROJECT_NUMBER=\"${PROJECT_NUMBER}\""
  VerboseLog "SERVICE_ACCOUNT_EMAIL=\"${SERVICE_ACCOUNT_EMAIL}\""
  VerboseLog "SERVICE_ACCOUNT_P12_FILE=\"${SERVICE_ACCOUNT_P12_FILE}\""
}

function Test() {
  echo "Configuration options:"
  PrintConfig

  echo
  echo "Verifying authentication..."
  ReadProjectMetadata || export OAUTH_TOKEN=""
  if [[ -z "${OAUTH_TOKEN}" ]]; then
    echo "Failed to authenticate to Google Cloud Platform."
    exit 1
  fi
  echo "OAuth token: ${OAUTH_TOKEN}"

  echo
  echo "Computing application version hash..."
  ComputeHash
  echo "Version hash: ${VERSION_HASH}"

  echo
  echo "Verifying agent download..."
  PrepareCloudDebuggerAgent

  local AGENT_SO_FILE="${AGENT_PATH}/${VERSION_HASH}/cdbg_java_agent.so"
  if [[ ! -f "${AGENT_SO_FILE}" ]]; then
    echo "Debugger agent was not dowloaded."
    exit 1
  fi
  echo "Debugger agent library: ${AGENT_SO_FILE}"

  FormatCommandLine
  if [[ -z "${ARGS}" ]]; then
    echo "Debugger not available"
    exit 1
  fi
  echo "Debugger agent arguments: ${ARGS}"

  echo
  echo "Building test program..."
  echo "public class ReadLine {
  public static void main(String[] args) throws Exception {
    Thread.sleep(2500);
    System.out.println(\"The application is loaded with the debugger attached.\");
    System.out.println(\"You can now set a watchpoint, and it will be accepted\");
    System.out.println(\"and validated, but not triggered (as the application is not running).\");
    System.out.println(\"Press <Enter> to exit.\");
    java.io.BufferedReader in = new java.io.BufferedReader(new java.io.InputStreamReader(System.in));
    in.readLine();
  }
}" > ${AGENT_PATH}/ReadLine.java
  javac -g ${AGENT_PATH}/ReadLine.java

  echo
  echo "Starting the test program with debugger attached..."
  if [[ VERBOSE -eq 1 ]]; then
    ARGS=${ARGS//--logtostderr=false/--logtostderr=true}
  fi
  java ${ARGS} -cp ${AGENT_PATH} ReadLine

  echo "Test completed"
}

function Main() {
  PrintConfig

  ReadProjectMetadata
  ComputeHash
  if [[ ! -d "${AGENT_PATH}/${VERSION_HASH}" ]]; then
    PrepareCloudDebuggerAgent
  fi
  FormatCommandLine

  echo ${ARGS}
}

# read the options
GETOPT=`getopt -o h -u --long ?,help,env:,test,app_class_path:,verbose,module:,version:,gcs_bucket_prefix:,retry_attempts:,skip_download,agent_logs_dir:,agent_path:,enable_service_account_auth,project_id:,project_number:,service_account_email:,service_account_p12_file: -n 'format_env_gce.sh' -- "$@"`
eval set -- "${GETOPT}"

while true ; do
  case "$1" in
    --verbose ) let VERBOSE=1; shift ;;
    --test ) let TEST_MODE=1; shift ;;
    -a|--app_class_path ) APP_DIRS+="$2 "; shift 2 ;;
    --module ) MODULE="$2"; shift 2 ;;
    -v|--version ) VERSION="$2"; shift 2 ;;
    --gcs_bucket_prefix ) GCS_BUCKET_PREFIX="$2"; shift 2 ;;
    --retry_attempts ) let RETRY_ATTEMPTS="$2"; shift 2 ;;
    --skip_download ) SKIP_DOWNLOAD=1; shift ;;
    --agent_logs_dir ) AGENT_LOGS_DIR="$2"; shift 2 ;;
    --agent_path ) AGENT_PATH="$2"; shift 2 ;;
    --enable_service_account_auth ) let ENABLE_SERVICE_ACCOUNT_AUTH=1; shift ;;
    --project_id ) PROJECT_ID="$2"; shift 2 ;;
    --project_number ) PROJECT_NUMBER="$2"; shift 2 ;;
    --service_account_email ) SERVICE_ACCOUNT_EMAIL="$2"; shift 2 ;;
    --service_account_p12_file ) SERVICE_ACCOUNT_P12_FILE="$2"; shift 2 ;;
    --env ) . "$2"; shift 2 ;;
    -h|--?|--help ) DisplayUsage ; exit 1 ;;
    --) shift ; break ;;
    * ) echo "Error parsing command line arguments" >&2;
        exit 1
        ;;
  esac
done

APP_DIRS="$(TrimWhitespaces "${APP_DIRS}")"

if [[ TEST_MODE -eq 1 ]]; then
  Test
else
  Main
fi
