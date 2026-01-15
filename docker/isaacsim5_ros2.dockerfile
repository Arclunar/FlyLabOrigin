ARG ISAACSIM_BASE_IMAGE=nvcr.io/nvidia/isaac-sim
ARG ISAACSIM_VERSION=5.1.0

FROM ${ISAACSIM_BASE_IMAGE}:${ISAACSIM_VERSION} AS simulation

# Re-declare ARG after FROM (inherits value from before FROM if not overridden)
ARG ISAACSIM_VERSION
ARG ISAACSIM_PATH=/isaac-sim
ARG ISAACLAB_PATH=/workspace/isaaclab
ARG DOCKER_USER_HOME=/root

# ${ISAACLAB_PATH}/_isaac_sim is a symlink to ${ISAACSIM_PATH}

ENV ISAACSIM_VERSION=${ISAACSIM_VERSION} \
    ISAACLAB_PATH=${ISAACLAB_PATH} \
    ISAACSIM_PATH=${ISAACSIM_PATH} \
    DOCKER_USER_HOME=${DOCKER_USER_HOME} \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    FASTRTPS_DEFAULT_PROFILES_FILE=${DOCKER_USER_HOME}/.ros/fastdds.xml \
    CYCLONEDDS_URI=${DOCKER_USER_HOME}/.ros/cyclonedds.xml \
    OMNI_KIT_ALLOW_ROOT=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    PATH="/root/.local/bin:$PATH"

SHELL ["/bin/bash", "-c"]

USER root

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libglib2.0-0 \
    ncurses-term \
    wget \
    curl \
    gedit \
    tmux \
    software-properties-common



WORKDIR /workspace
COPY ./IsaacLab ${ISAACLAB_PATH}
RUN chmod +x ${ISAACLAB_PATH}/isaaclab.sh
RUN ln -sf ${ISAACSIM_PATH} ${ISAACLAB_PATH}/_isaac_sim
RUN ${ISAACLAB_PATH}/isaaclab.sh -p -m pip install --upgrade pip
RUN ${ISAACLAB_PATH}/isaaclab.sh -i


RUN echo "export ISAACLAB_PATH=${ISAACLAB_PATH}" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias runapp=${ISAACSIM_PATH}/runapp.sh" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias runheadless=${ISAACSIM_PATH}/runheadless.sh" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias runoldstreaming=${ISAACSIM_PATH}/runoldstreaming.sh" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias isaaclab=${ISAACLAB_PATH}/isaaclab.sh" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias python=${ISAACLAB_PATH}/_isaac_sim/python.sh" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias python3=${ISAACLAB_PATH}/_isaac_sim/python.sh" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias pip='${ISAACLAB_PATH}/_isaac_sim/python.sh -m pip'" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias pip3='${ISAACLAB_PATH}/_isaac_sim/python.sh -m pip'" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "alias tensorboard='${ISAACLAB_PATH}/_isaac_sim/python.sh ${ISAACLAB_PATH}/_isaac_sim/tensorboard'" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "export TZ=$(date +%Z)" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "shopt -s histappend" >> ${DOCKER_USER_HOME}/.bashrc && \
    echo "PROMPT_COMMAND='history -a'" >> ${DOCKER_USER_HOME}/.bashrc

RUN mkdir -p ${ISAACSIM_PATH}/kit/cache && \
    mkdir -p ${DOCKER_USER_HOME}/.cache/ov && \
    mkdir -p ${DOCKER_USER_HOME}/.cache/pip && \
    mkdir -p ${DOCKER_USER_HOME}/.cache/nvidia/GLCache && \
    mkdir -p ${DOCKER_USER_HOME}/.nv/ComputeCache && \
    mkdir -p ${DOCKER_USER_HOME}/.nvidia-omniverse/logs && \
    mkdir -p ${DOCKER_USER_HOME}/.local/share/ov/data && \
    mkdir -p ${DOCKER_USER_HOME}/Documents

RUN touch /bin/nvidia-smi && \
    touch /bin/nvidia-debugdump && \
    touch /bin/nvidia-persistenced && \
    touch /bin/nvidia-cuda-mps-control && \
    touch /bin/nvidia-cuda-mps-server && \
    touch /etc/localtime && \
    mkdir -p /var/run/nvidia-persistenced && \
    touch /var/run/nvidia-persistenced/socket

    # =====================================================
# ROS2 Jazzy Installation (for Ubuntu 24.04 Noble)
# Note: Humble requires Ubuntu 22.04, Jazzy supports 24.04
# =====================================================
ARG ROS2_APT_PACKAGE=ros-base
ENV RMW_IMPLEMENTATION=rmw_fastrtps_cpp

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && \
    add-apt-repository universe && \
    curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-jazzy-${ROS2_APT_PACKAGE} \
    ros-jazzy-vision-msgs \
    ros-jazzy-rmw-cyclonedds-cpp \
    ros-jazzy-rmw-fastrtps-cpp \
    ros-jazzy-plotjuggler-ros \
    ros-dev-tools && \
    echo "source /opt/ros/jazzy/setup.bash" >> ${DOCKER_USER_HOME}/.bashrc

RUN mkdir -p ${DOCKER_USER_HOME}/.ros && \
    cp -r ${ISAACLAB_PATH}/docker/.ros/. ${DOCKER_USER_HOME}/.ros/ || true

VOLUME [ \
    "${ISAACSIM_PATH}/kit/cache", \
    "${DOCKER_USER_HOME}/.cache/ov", \
    "${DOCKER_USER_HOME}/.cache/pip", \
    "${DOCKER_USER_HOME}/.cache/nvidia/GLCache", \
    "${DOCKER_USER_HOME}/.nv/ComputeCache", \
    "${DOCKER_USER_HOME}/.nvidia-omniverse/logs", \
    "${DOCKER_USER_HOME}/.local/share/ov/data", \
    "${ISAACLAB_PATH}/docs/_build", \
    "${ISAACLAB_PATH}/logs", \
    "${ISAACLAB_PATH}/data_storage" \
]


RUN apt install just && \
    echo "alias j='just'" >> ${DOCKER_USER_HOME}/.bashrc


RUN ${ISAACLAB_PATH}/isaaclab.sh -p -m pip install manifold3d pygame

RUN rm /workspace/isaaclab/_isaac_sim/kit/python/lib/python3.11/site-packages/rsl_rl_lib-3.1.2.dist-info/ -r && \
    rm /workspace/isaaclab/_isaac_sim/kit/python/lib/python3.11/site-packages/rsl_rl/ -r

COPY ./rsl_rl /workspace/rsl_rl
RUN cd /workspace/rsl_rl && \
    ${ISAACLAB_PATH}/isaaclab.sh -p -m pip install -e .

RUN add-apt-repository ppa:maveonair/helix-editor && \
    apt update && \
    apt install helix && \
    echo "alias vim='hx'" >> /root/.bashrc

ENTRYPOINT ["/bin/bash"]

