# syntax=docker/dockerfile:1
# ============================================================
# Quikuvr5 - Docker UVR5 Quikseries Image
# Ultimate Vocal Remover 5 — Gradio WebUI
# ============================================================
FROM pytorch/pytorch:2.1.2-cuda12.1-cudnn8-runtime

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# -------- BUILD ARGS --------
ARG UID=1000
ARG GID=1000
ARG ENABLE_BUILD_TOOLS=false
ARG GIT_REF=
ARG GIT_REPO=https://github.com/Eddycrack864/UVR5-UI.git

LABEL maintainer="lwdjohari"
LABEL description="UVR5 Industrial — Ultimate Vocal Remover WebUI"
LABEL version="1.0.0"
LABEL org.opencontainers.image.source="https://github.com/lwdjohari/quikuvr5-docker"

# -------- ENV --------
ENV DEBIAN_FRONTEND=noninteractive
ENV UVR_HOME=/opt/UVR5-UI
ENV UVR_ENV=/opt/UVR5-UI/env
# Runtime pip cache dir — only used if someone runs `docker exec ... pip install`
# Build-time pip caching is handled by BuildKit --mount=type=cache (never stored in image)
ENV PIP_CACHE_DIR=/data/pip-cache
ENV PYTHONUNBUFFERED=1
ENV PATH="${UVR_ENV}/bin:${PATH}"

# -------- SYSTEM PACKAGES --------
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ffmpeg \
    libsndfile1 \
    libgl1 \
    libffi-dev \
    python3-venv \
    tini \
    ca-certificates \
    curl \
    bash \
    findutils \
    coreutils \
    procps \
    && rm -rf /var/lib/apt/lists/*

# -------- OPTIONAL BUILD TOOLS --------
RUN if [ "${ENABLE_BUILD_TOOLS}" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        python3-dev \
        cmake \
        pkg-config \
        cython3 \
      && rm -rf /var/lib/apt/lists/* ; \
    fi

# -------- USER --------
RUN groupadd -g "${GID}" appuser \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash appuser

# -------- DATA DIRECTORIES (as root, then hand off) --------
RUN mkdir -p \
    /opt/UVR5-UI \
    /data/models \
    /data/inputs \
    /data/outputs \
    /data/cache \
    /data/config \
    /data/pip-cache \
 && chown -R "${UID}:${GID}" /opt/UVR5-UI /data

# -------- SWITCH TO APPUSER --------
# Clone, venv, and pip install all run as appuser so every file
# is created with the correct ownership — no chown needed later.
USER appuser

# -------- CLONE UVR5 REPO --------
WORKDIR /opt
RUN echo "Cloning from: ${GIT_REPO}" \
 && if [ -n "${GIT_REF}" ]; then \
      git clone "${GIT_REPO}" "${UVR_HOME}" \
      && cd "${UVR_HOME}" \
      && git checkout "${GIT_REF}" \
      && echo "Pinned to: $(git log -1 --oneline)" ; \
    else \
      git clone --depth 1 "${GIT_REPO}" "${UVR_HOME}" ; \
    fi \
 && rm -rf "${UVR_HOME}/.git"

# -------- PYTHON VENV & DEPENDENCIES --------
# Use repo-local env because app.py checks ./env and expects env/bin/audio-separator on Linux
#
# Split into 3 layers so a failed requirements.txt install doesn't
# force re-downloading pip/setuptools on retry. BuildKit cache mount
# keeps pip's temp/download cache on the host — failed builds don't
# pollute container disk and retries reuse already-downloaded packages.
WORKDIR "${UVR_HOME}"

# Layer 1: Create venv (tiny, almost never changes)
RUN python3 -m venv "${UVR_ENV}"

# Layer 2: Upgrade pip tooling (cached separately)
RUN --mount=type=cache,target=/tmp/pip-cache,uid=${UID},gid=${GID} \
    "${UVR_ENV}/bin/pip" install \
      --cache-dir /tmp/pip-cache \
      --upgrade pip setuptools wheel

# Layer 3: Install app requirements (the big one — cached across retries)
RUN --mount=type=cache,target=/tmp/pip-cache,uid=${UID},gid=${GID} \
    "${UVR_ENV}/bin/pip" install \
      --cache-dir /tmp/pip-cache \
      -r requirements.txt

# -------- BUILD-TIME VALIDATION --------
RUN set -e \
 && test -d "${UVR_HOME}" \
 && test -f "${UVR_HOME}/app.py" \
 && test -f "${UVR_HOME}/requirements.txt" \
 && test -f "${UVR_HOME}/assets/config.json" \
 && test -f "${UVR_HOME}/assets/models.json" \
 && test -f "${UVR_HOME}/assets/default_settings.json" \
 && test -x "${UVR_ENV}/bin/python" \
 && test -x "${UVR_ENV}/bin/audio-separator" \
 && echo "Build-time file validation passed"

# -------- SWITCH BACK TO ROOT for COPY & final setup --------
USER root

COPY validate_imports.py /tmp/validate_imports.py
RUN "${UVR_ENV}/bin/python" /tmp/validate_imports.py && rm -f /tmp/validate_imports.py

RUN "${UVR_ENV}/bin/python" app.py --help > /tmp/uvr_help.txt 2>&1 \
 && grep -q -- "--listen-port" /tmp/uvr_help.txt \
 && grep -q -- "--share" /tmp/uvr_help.txt \
 && rm -f /tmp/uvr_help.txt \
 && echo "Build-time app.py CLI validation passed"

# Precompile bytecode for faster startup (PyTorch, Gradio, etc.)
RUN "${UVR_ENV}/bin/python" -m compileall -q "${UVR_ENV}/lib" 2>/dev/null || true

# -------- ENTRYPOINT --------
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER appuser
WORKDIR "${UVR_HOME}"

EXPOSE 7860

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["start"]
