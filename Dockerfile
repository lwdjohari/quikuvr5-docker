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
    fi

# -------- PYTHON VENV & DEPENDENCIES --------
# Use repo-local env because app.py checks ./env and expects env/bin/audio-separator on Linux
WORKDIR "${UVR_HOME}"
RUN python3 -m venv "${UVR_ENV}"

RUN "${UVR_ENV}/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel \
 && "${UVR_ENV}/bin/pip" install --no-cache-dir -r requirements.txt

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

COPY validate_imports.py /tmp/validate_imports.py
RUN "${UVR_ENV}/bin/python" /tmp/validate_imports.py && rm -f /tmp/validate_imports.py

RUN "${UVR_ENV}/bin/python" app.py --help > /tmp/uvr_help.txt 2>&1 \
 && grep -q -- "--listen-port" /tmp/uvr_help.txt \
 && grep -q -- "--share" /tmp/uvr_help.txt \
 && rm -f /tmp/uvr_help.txt \
 && echo "Build-time app.py CLI validation passed"

# -------- DATA DIRECTORIES --------
RUN mkdir -p \
    /data/models \
    /data/inputs \
    /data/outputs \
    /data/cache \
    /data/pip-cache \
    /data/wheels

# Only chown /data (small). UVR_HOME is large — use find to fix only
# ownership mismatches instead of duplicating the entire tree in a new layer.
RUN chown -R "${UID}:${GID}" /data \
 && chown "${UID}:${GID}" "${UVR_HOME}" \
 && find "${UVR_HOME}" -not -user "${UID}" -exec chown "${UID}:${GID}" {} + 2>/dev/null || true

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
