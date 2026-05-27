#!/usr/bin/env bash
# PostHog runtime bootstrap on Zerops — lifts the official PostHog Docker image filesystem
# (via crane) into /opt/posthog/, then repoints PostHog's hard-coded paths at Zerops's runtime.
#
# Usage: bash utils/init.sh <role>
#   role = web | worker | pluginserver
#
# web/worker use posthog/posthog (Django + Celery, Python 3.12). pluginserver uses
# posthog/posthog-node (Node 24). Each role needs different system libs from the image.
set -euo pipefail

ROLE="${1:?usage: init.sh <web|worker|pluginserver>}"

CRANE_URL="https://github.com/google/go-containerregistry/releases/download/v0.20.3/go-containerregistry_Linux_x86_64.tar.gz"

install_crane() {
  sudo wget -q "$CRANE_URL" -O - | sudo tar -xz -C /usr/local/bin crane
  sudo chmod +x /usr/local/bin/crane
}

install_python_libs() {
  # Wheels in the PostHog image link against these — install them now so xmlsec/psycopg2/etc. load
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates libpq5 libxml2 libssl3 libjemalloc2
}

install_node_libs() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates libssl3 librdkafka1
}

prepare_opt() {
  sudo mkdir -p /opt/posthog
  sudo chown zerops:zerops /opt/posthog
}

extract_python_image() {
  # Pull and extract code + python-runtime + docker-entrypoint.d + libxmlsec (matches xmlsec wheel ABI)
  sudo crane export posthog/posthog:latest /tmp/posthog.tar
  cd /opt/posthog
  sudo tar -xf /tmp/posthog.tar code python-runtime docker-entrypoint.d
  sudo bash -c 'tar -xf /tmp/posthog.tar $(tar -tf /tmp/posthog.tar \
    | grep -E "^usr/lib/x86_64-linux-gnu/libxmlsec1.*\.so(\.[0-9]+)*$" | tr "\n" " ")'
  sudo rm /tmp/posthog.tar
  sudo chown -R zerops:zerops /opt/posthog
  # Image's libxmlsec 1.2.37 (Bookworm) matches the xmlsec wheel; Ubuntu 22.04's 1.2.33 doesn't
  sudo cp -n /opt/posthog/usr/lib/x86_64-linux-gnu/libxmlsec1*.so* /usr/lib/x86_64-linux-gnu/
  sudo ldconfig
}

extract_node_image() {
  sudo crane export posthog/posthog-node:latest /tmp/node.tar
  cd /opt/posthog
  sudo tar -xf /tmp/node.tar code
  # librdkafka shipped with the image matches the bundled node-rdkafka build
  sudo bash -c 'tar -xf /tmp/node.tar $(tar -tf /tmp/node.tar \
    | grep -E "^usr/lib/x86_64-linux-gnu/librdkafka(\+\+)?\.so(\.[0-9]+)*$" | tr "\n" " ")'
  sudo rm /tmp/node.tar
  sudo chown -R zerops:zerops /opt/posthog
  sudo cp -n /opt/posthog/usr/lib/x86_64-linux-gnu/librdkafka*.so* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
  sudo ldconfig
}

repoint_python_venv() {
  # Image's venv references /usr/local/bin/python3.12; Zerops's Python is at /usr/bin/python3.12
  sudo rm -f /opt/posthog/python-runtime/bin/python \
             /opt/posthog/python-runtime/bin/python3 \
             /opt/posthog/python-runtime/bin/python3.12
  sudo ln -s /usr/bin/python3.12 /opt/posthog/python-runtime/bin/python3.12
  cd /opt/posthog/python-runtime/bin
  sudo ln -s python3.12 python
  sudo ln -s python3.12 python3
}

symlink_hardcoded_paths() {
  # PostHog source uses absolute /code and /docker-entrypoint.d everywhere
  sudo ln -sfn /opt/posthog/code /code
  if [ "$ROLE" != "pluginserver" ]; then
    sudo ln -sfn /opt/posthog/docker-entrypoint.d /docker-entrypoint.d
    sudo ln -sfn /opt/posthog/python-runtime /python-runtime
  fi
}

install_gunicorn() {
  # Image runs Django under Nginx Unit; we use gunicorn (added into the venv's site-packages)
  sudo /usr/bin/pip3 install --target=/opt/posthog/python-runtime/lib/python3.12/site-packages \
    --quiet gunicorn
}

case "$ROLE" in
  web)
    install_crane
    install_python_libs
    prepare_opt
    extract_python_image
    repoint_python_venv
    symlink_hardcoded_paths
    install_gunicorn
    ;;
  worker)
    install_crane
    install_python_libs
    prepare_opt
    extract_python_image
    repoint_python_venv
    symlink_hardcoded_paths
    ;;
  pluginserver)
    install_crane
    install_node_libs
    prepare_opt
    extract_node_image
    symlink_hardcoded_paths
    ;;
  *)
    echo "unknown role: $ROLE" >&2
    exit 1
    ;;
esac
