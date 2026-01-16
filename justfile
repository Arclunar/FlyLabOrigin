project_root := justfile_directory()
hostname := `hostname`
TAG_NAME := if hostname == "dcj" { "train-server-ali" } else if hostname == "wfzf" { "v0" } else { "v0" }
tmp_dirname := `cd .. && pwd`
SERVER_LOGS_DIR := tmp_dirname + "/server_logs"

elogs:
    echo "SERVER_LOGS_DIR: {{SERVER_LOGS_DIR}}"

build-sim:
    docker build -f docker/isaacsim5_ros2.dockerfile \
    --network=host \
    -t {{env_var("USER")}}-lab2.3-sim5.1:{{TAG_NAME}} .

run-sim:
    docker run --name {{env_var("USER")}}-lab2.3-sim5.1 -itd --privileged --gpus all --network host \
    --entrypoint bash \
    --runtime=nvidia \
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \
    -e DISPLAY -e QT_X11_NO_MITSHM=1 \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v $HOME/.Xauthority:/root/.Xauthority \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v ~/docker/isaac-sim5.1/cache/kit:/isaac-sim/kit/cache:rw \
    -v ~/docker/isaac-sim5.1/cache/ov:/root/.cache/ov:rw \
    -v ~/docker/isaac-sim5.1/cache/pip:/root/.cache/pip:rw \
    -v ~/docker/isaac-sim5.1/cache/glcache:/root/.cache/nvidia/GLCache:rw \
    -v ~/docker/isaac-sim5.1/cache/computecache:/root/.nv/ComputeCache:rw \
    -v ~/docker/isaac-sim5.1/logs:/root/.nvidia-omniverse/logs:rw \
    -v ~/docker/isaac-sim5.1/data:/root/.local/share/ov/data:rw \
    -v ~/docker/isaac-sim5.1/documents:/root/Documents:rw \
    -v {{project_root}}/.git:/workspace/.git \
    -v {{project_root}}/rsl_rl:/workspace/rsl_rl \
    -v {{project_root}}/drone_racer:/workspace/drone_racer \
    -v {{SERVER_LOGS_DIR}}:/root/server_logs:rw \
    -v {{SERVER_LOGS_DIR}}/outputs:/workspace/drone_racer/outputs:rw \
    {{env_var("USER")}}-lab2.3-sim5.1:{{TAG_NAME}}

exec-sim:
    docker exec -it {{env_var("USER")}}-lab2.3-sim5.1 /bin/bash

stop-sim:
    docker stop {{env_var("USER")}}-lab2.3-sim5.1 || true && \
    docker rm {{env_var("USER")}}-lab2.3-sim5.1 || true

start:
    docker restart {{env_var("USER")}}-lab2.3-sim5.1:{{TAG_NAME}}

build-sim-local:
    docker build -f docker/isaacsim5_ros2.dockerfile \
    --network=host \
    -t isaacsim5:latest .

run-sim-local:
    docker run --name isaac-lab2.3-sim5.1 -it --privileged --gpus all --network host \
    --rm \
    --entrypoint bash \
    --runtime=nvidia \
    -e ACCEPT_EULA=Y -e PRIVACY_CONSENT=Y \
    -e DISPLAY -e QT_X11_NO_MITSHM=1 \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v $HOME/.Xauthority:/root/.Xauthority \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v ~/docker/isaac-sim5.1/cache/kit:/isaac-sim/kit/cache:rw \
    -v ~/docker/isaac-sim5.1/cache/ov:/root/.cache/ov:rw \
    -v ~/docker/isaac-sim5.1/cache/pip:/root/.cache/pip:rw \
    -v ~/docker/isaac-sim5.1/cache/glcache:/root/.cache/nvidia/GLCache:rw \
    -v ~/docker/isaac-sim5.1/cache/computecache:/root/.nv/ComputeCache:rw \
    -v ~/docker/isaac-sim5.1/logs:/root/.nvidia-omniverse/logs:rw \
    -v ~/docker/isaac-sim5.1/data:/root/.local/share/ov/data:rw \
    -v ~/docker/isaac-sim5.1/documents:/root/Documents:rw \
    -v {{justfile_directory()}}/.git:/workspace/.git \
    -v {{justfile_directory()}}/rsl_rl:/workspace/rsl_rl \
    -v {{justfile_directory()}}/drone_racer:/workspace/drone_racer \
    -v {{SERVER_LOGS_DIR}}:/root/server_logs:rw \
    -v {{SERVER_LOGS_DIR}}/outputs:/workspace/drone_racer/outputs:rw \
    -v {{justfile_directory()}}/shared:/workspace/drone_racer/shared:rw \
    -w /workspace/drone_racer \
    isaacsim5:latest

exec-sim-local:
    docker exec -it isaac-lab2.3-sim5.1 /bin/bash

stop-sim-local:
    docker stop isaac-lab2.3-sim5.1 || true && \
    docker rm isaac-lab2.3-sim5.1 || true

alias bsl := build-sim-local
alias rsl := run-sim-local
alias esl := exec-sim-local
alias ssl := stop-sim-local

alias b := build-sim
alias r := run-sim
alias e := exec-sim
alias s := stop-sim
