<div align="center">

# 🖥️ Server Training Framework

**基于 Isaac Lab 的服务器端无人机强化学习训练框架**

[![IsaacSim](https://img.shields.io/badge/IsaacSim-5.1.0-silver.svg)](https://docs.isaacsim.omniverse.nvidia.com/latest/index.html)
[![Isaac Lab](https://img.shields.io/badge/Isaac_Lab-2.3-green.svg)](https://github.com/isaac-sim/IsaacLab)
[![Python](https://img.shields.io/badge/python-3.12-blue.svg)](https://docs.python.org/3/whatsnew/3.12.html)

*服务器端训练框架，提供代码同步、日志管理和优化的强化学习算法*

[English](#) | [中文](#)

</div>

---

## 📌 项目简介

本仓库基于 [原始仓库](https://github.com/WarriorHanamy/server/tree/main) 和 Isaac Lab 框架构建，主要用于服务器端的分布式训练和模型开发。相比原仓库，我们做了以下关键改进和扩展，以支持更高效的开发工作流和更强大的算法性能。

---

## ✨ 相比原仓库的主要改进

### 🔄 1. 服务器同步工具 (`scripts/`)

为了实现本地开发和服务器训练的无缝协作，我们在 `scripts/` 目录下提供了一套完整的同步工具：

#### **代码同步脚本**

- **`transfer_codebase.sh`** - 完整代码库传输工具
  - 支持增量同步，只传输修改的文件
  - 自动压缩传输，节省带宽
  - 可配置的过滤规则（`.gitignore` 支持）
  - 支持多服务器配置

- **`transfer_codebase_by_git_diff.sh`** - 基于 Git diff 的智能同步
  - 只同步 Git 追踪的变更文件
  - 更精确的增量更新
  - 适合频繁的小改动同步
  - 避免传输大型中间文件

#### **日志同步脚本**

- **`sync_server_logs.sh`** - 服务器训练日志实时同步
  - 持续监控并下载服务器训练日志
  - 只增量添加新文件，不删除本地文件
  - 可配置同步间隔（默认 10 秒）
  - 支持单次同步或持续监控模式
  - 自动保存到 `server_logs/` 目录

```bash
# 示例用法
# 持续同步日志
./scripts/sync_server_logs.sh

# 单次同步
./scripts/sync_server_logs.sh --once

# 自定义间隔（5秒同步一次）
./scripts/sync_server_logs.sh -i 5
```

---

### 🧠 2. RSL-RL 算法优化 (`rsl_rl/`)

为了与 [MasterRacing](https://github.com/MasterRacing) 项目保持一致的架构，我们对 RSL-RL 库进行了关键修改：

#### **特征融合架构**

原始的 CNN-MLP 架构直接将高维 CNN 输出（1280维）与状态特征拼接。我们采用了更优雅的**双流特征融合**架构：

```python
# 改进前：直接拼接高维特征
features = torch.cat([cnn_output, state], dim=-1)  # 例如 1280 + 12 = 1292 维

# 改进后：对齐维度 + 特征相加 + MLP
cnn_features = cnn_projection(cnn_output)      # 1280 -> 128
state_features = state_projection(state)       # 12 -> 128
fused_features = cnn_features + state_features # 128 + 128 = 128（逐元素相加）
output = mlp(fused_features)                   # 128 -> ...
```

#### **技术细节**

- **CNN 输出投影**: 将 CNN 编码后的 1280 维特征压缩到 128 维
- **状态 MLP 映射**: 低维状态（位置、速度等）通过 MLP 映射到 128 维
- **特征相加融合**: 两个 128 维特征向量逐元素相加，而非拼接
- **后续 MLP 处理**: 融合后的 128 维特征继续通过 MLP 进行策略/价值预测

相关文件: [`rsl_rl/rsl_rl/modules/actor_critic_cnn.py`](rsl_rl/rsl_rl/modules/actor_critic_cnn.py)

---

### 🎯 3. Drone Racer 任务优化 (`drone_racer/`)

#### **动力学控制优化 - 直接角速度写入** ([`drone_racer/tasks/drone_racer/mdp/actions_cl.py`](drone_racer/tasks/drone_racer/mdp/actions_cl.py))

我们对无人机动力学控制进行了重大改进，**不再使用传统的力矩控制，而是直接写入角速度**：

**传统方法的问题**:
```python
# ❌ 旧方法：力矩 → 角加速度 → 积分 → 角速度
torque = I * angular_acceleration
robot.set_external_force_and_torque(force, torque)
# 需要经过物理引擎的多步积分，存在：
# - 积分误差累积
# - 响应延迟
# - 参数调优困难
```

**新方法的优势**:
```python
# ✅ 新方法：直接设置角速度
# 1. 通过二阶动力学模型更新内部状态
ang_vel_dynamics.compute(ang_vel_cmd)

# 2. 获取期望的角速度（体坐标系）
ang_vel_b = ang_vel_dynamics.angular_velocity

# 3. 转换到世界坐标系
ang_vel_w = quat_apply(root_quat_w, ang_vel_b)

# 4. 直接写入仿真器
robot.write_root_velocity_to_sim(root_vel_w)
```

**动力学模型**:
- 推力：一阶系统 `Thrust/(s) = 1/(τs + 1)`
- 角速度：二阶系统 `AngVel/(s) = ω_n²/(s² + 2ζω_n·s + ω_n²)`
- 支持 Domain Randomization，模拟不同飞行器特性

相关文件: 
- [`drone_racer/tasks/drone_racer/mdp/actions_cl.py`](drone_racer/tasks/drone_racer/mdp/actions_cl.py) - 动作执行
- [`drone_racer/dynamics/angular_velocity.py`](drone_racer/dynamics/angular_velocity.py) - 角速度动力学

---

#### **Lattice 网格管理器修复** ([`drone_racer/tasks/drone_racer/mdp/lattice_manager.py`](drone_racer/tasks/drone_racer/mdp/lattice_manager.py))

我们修复并扩展了 Lattice 网格生成器，这是用于无人机感知和避障的核心模块：

**修复内容**:
- 🐛 **Mesh 偏置问题修复**: 修正了之前版本中网格坐标系统的偏移错误，现在网格中心精确对齐无人机位置
- 🔧 **性能优化**: 实现了延迟计算和缓存机制，配合 decimation factor 减少 75% 的计算量
- 📊 **可视化改进**: 同步更新频率与策略频率，避免不必要的渲染

**新增功能**:
- ✨ **机翼 Lattice 生成**: 添加了专门针对固定翼/VTOL 的机翼区域网格生成
  - 考虑机翼几何形状的特殊感知需求
  - 支持不对称机翼配置
  - 优化前向飞行的障碍物检测范围

**技术特点**:
- 自适应网格密度：根据飞行速度和任务动态调整
- 高效缓存策略：仅在策略步更新时重新计算
- 统一接口设计：observation 和 reward 共享同一份计算结果

#### **训练配置** ([`drone_racer/tasks/drone_racer/uav_cfg/`](drone_racer/tasks/drone_racer/uav_cfg/))

所有 UAV 相关的训练配置和超参数都集中在 `uav_cfg` 目录中：

```bash
drone_racer/tasks/drone_racer/uav_cfg/
├── rsl_rl_uav_nav_cfg.py       # CNN 策略配置（深度图像输入）
├── rsl_rl_uav_nav_mlp_cfg.py   # MLP 策略配置（点云/状态输入）
├── uav_nav_env_cfg.py          # 环境配置（奖励、观测、场景）
└── ...
```

**主要配置项**:
- 📸 **视觉输入**: RGB-D 深度图像配置（分辨率、FOV、范围）
- 🎮 **动作空间**: 推力、姿态控制参数
- 🏆 **奖励函数**: 目标导航、碰撞惩罚、速度奖励、姿态稳定等
- 🌍 **环境设置**: 障碍物密度、地形难度、课程学习策略
- 🧠 **网络架构**: Actor-Critic 结构、隐藏层维度、激活函数

---

##  仓库结构

```
server/
├── scripts/                    # 🔄 服务器同步工具
│   ├── sync_server_logs.sh    #    日志同步脚本
│   ├── transfer_codebase.sh   #    代码传输脚本
│   └── transfer_codebase_by_git_diff.sh
│
├── rsl_rl/                     # 🧠 优化的 RSL-RL 算法库
│   └── rsl_rl/modules/
│       └── actor_critic_cnn.py #    特征融合架构（1280->128+128）
│
├── drone_racer/                # 🚁 无人机训练任务
│   ├── dynamics/               #    动力学模型
│   │   ├── angular_velocity.py #    二阶角速度动力学
│   │   ├── thrust.py           #    一阶推力动力学
│   │   └── aerodynamics.py     #    气动力模型
│   ├── tasks/drone_racer/
│   │   ├── mdp/
│   │   │   ├── actions_cl.py   #    直接角速度写入控制
│   │   │   └── lattice_manager.py  # 修复的网格管理器
│   │   └── uav_cfg/            #    训练配置目录
│   │       ├── rsl_rl_uav_nav_cfg.py
│   │       └── uav_nav_env_cfg.py
│   └── scripts/                #    训练和评估脚本
│
├── IsaacLab/                   # 🎮 Isaac Lab 框架（子模块）
├── docker/                     # 🐳 Docker 配置
└── README.md                   # 📖 本文档
```

---

## 🔗 相关项目

- [Isaac Lab](https://github.com/isaac-sim/IsaacLab) - NVIDIA 机器人学习框架
- [MasterRacing](https://github.com/MasterRacing) - 无人机竞速项目（架构参考）
- [RSL-RL](https://github.com/leggedrobotics/rsl_rl) - ETH Zurich 强化学习库

---

## 📄 许可证

本项目遵循 BSD-3-Clause 许可证。详见 [LICENSE](LICENSE) 文件。

部分代码基于 Isaac Lab 框架，遵循其原始许可证。

---

<div align="center">

### ⭐ 如果这个项目对你有帮助，请给一个 Star！

**Made with ❤️ by DiffRobot VTOL Team**

[⬆ 回到顶部](#️-server-training-framework)

</div>
