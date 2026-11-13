#!/bin/sh
set -eu
apt-get update
apt-get install -y --no-install-recommends python3 python3-venv ca-certificates
python3 -m venv .work/cnb-python
.work/cnb-python/bin/pip install --disable-pip-version-check -r scripts/requirements-linux.txt
