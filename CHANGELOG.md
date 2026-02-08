# Development History

此文件记录对 server 目录的重要修改，供后续 AI 检阅。

**📝 日志规范：请将最新的修改记录添加在文件顶部（紧接本说明之后），保持新历史在上、旧历史在下的顺序。**

**⚠️ 重要提醒：drone_racer 项目相关的详细开发历史已迁移到 `drone_racer/dev_history.md`，请查看该文件获取完整的技术细节和实现说明。本文件仅保留高层次的概述。**

---

## 2026-01-27: drone_racer 项目更新概述 ✅

**详细内容请查看**: `drone_racer/dev_history.md`

**主要更新**:
1. **日志优化** - 添加编号前缀和北京时间支持
2. **时间同步** - Docker 容器时间同步脚本
3. **碰撞检测修复** - 从射线检测改为点查询算法（待测试）
4. **速度惩罚分析** - 二值惩罚优于连续惩罚

**修改文件**:
- `drone_racer/scripts/rsl_rl/train.py`
- `drone_racer/scripts/rsl_rl/cli_args.py`
- `drone_racer/sync_time.sh`
- `drone_racer/tasks/drone_racer/utils/warp_funcs.py`
- `drone_racer/tasks/drone_racer/mdp/terminations.py`

---

### 1. 日志目录命名改进

**问题**: 日志目录命名难以追踪实验顺序，且使用UTC时间不符合北京时间习惯。

**解决方案**:
- 在 `logs/rsl_rl/` 下创建带两位数编号前缀的实验目录
- 使用北京时间（UTC+8）命名子目录

**修改文件**:
- `drone_racer/scripts/rsl_rl/train.py`
- `drone_racer/scripts/rsl_rl/cli_args.py`

**实现细节**:

1. **train.py** - 添加编号和北京时间:
```python
from datetime import datetime, timezone, timedelta

# 统计现有实验目录数量
base_log_path = Path('~/server_logs/drone_racer/logs/rsl_rl').expanduser().absolute()
experiment_number = len([d for d in base_log_path.iterdir() if d.is_dir()])

# 创建带编号的实验目录
numbered_experiment_name = f'{experiment_number + 1:02d}_{agent_cfg.experiment_name}'
log_root_path = Path(base_log_path, numbered_experiment_name)

# 使用北京时间创建子目录
beijing_tz = timezone(timedelta(hours=8))
log_dir = datetime.now(beijing_tz).strftime('%Y-%m-%d_%H-%M-%S')
```

2. **cli_args.py** - 修复 `--experiment` 参数:
```python
# 使用 --experiment 参数设置 experiment_name
if args_cli.experiment_name is None and args_cli.experiment is not None:
    agent_cfg.experiment_name = args_cli.experiment
```

**效果**:
- 命令: `just train-uav-cnn --experiment noco_10hz_noconv_side01`
- 目录结构: `01_noco_10hz_noconv_side01/2026-01-27_17-02-36/`
- TensorBoard 可按编号自然排序查看实验

### 2. Docker 时间同步脚本

**问题**: Docker 容器时钟可能与主机不同步。

**解决方案**: 创建 `drone_racer/sync_time.sh` 脚本

```bash
#!/bin/bash
# Sync docker container time with NTP server
ntpdate -u ntp.aliyun.com || ntpdate -u pool.ntp.org
echo "Updated container time: $(date)"
echo "Note: Logs will use Beijing Time (UTC+8) via Python timezone conversion"
```

**设计思路**:
- 系统层面保持 UTC 时间（使用 ntpdate 同步）
- Python 代码层面转换为北京时间（用于日志命名）

### 3. Lattice 碰撞终止项

**功能**: 添加基于晶格点检测的碰撞终止条件

**修改文件**:
- `drone_racer/tasks/drone_racer/mdp/terminations.py`
- `drone_racer/tasks/drone_racer/uav_nav_env_cfg.py`

**实现**:

1. **terminations.py** - 新增函数:
```python
def lattice_collision(
  env: ManagerBasedRLEnv,
  collision_threshold: float = 0.0,
  asset_cfg: SceneEntityCfg = SceneEntityCfg('robot'),
) -> torch.Tensor:
  """Terminate when lattice points detect collision with obstacles.
  
  Uses LatticeManager to detect if any lattice points on the drone mesh 
  have entered obstacles.
  """
  from .observations import robot_lattice_collision_fraction
  collision_fraction = robot_lattice_collision_fraction(env, asset_cfg=asset_cfg)
  return collision_fraction > collision_threshold
```

2. **uav_nav_env_cfg.py** - 添加终止项:
```python
lattice_collision = DoneTerm(
  func=mdp.lattice_collision,
  params={'collision_threshold': 0.0},
)
```

**特点**:
- 基于无人机 STL 网格形状进行精确碰撞检测
- 复用 LatticeManager，效率高
- 支持可配置的容差阈值

### 4. 速度惩罚函数对比分析

**发现**: 连续惩罚 vs 二值惩罚的效果差异显著

**对比**:

| 函数 | velocity_limit_penalty | lin_vel_limit_violation |
|------|----------------------|------------------------|
| 类型 | 连续线性惩罚 | 二值惩罚（0或1） |
| 公式 | `max(0, vel - 3.0)` | `(vel > 5.0).float()` |
| 权重 | -0.5 | -100.0 |
| 阈值 | 3.0 m/s | 5.0 m/s |

**效果差异原因**:

1. **连续惩罚问题**:
   - 惩罚太弱: 3-5 m/s 最大惩罚仅 -1.0
   - 持续干扰: 一直给予小惩罚，影响其他学习信号
   - 梯度平缓: Agent 认为超速代价小，不值得改变

2. **二值惩罚优势**:
   - 信号清晰: 只有安全/危险两个状态
   - 惩罚足够: -100 是强信号，Agent 会严格避免
   - 不干扰正常行为: 5 m/s 以下完全无惩罚
   - 阈值更合理: 5 m/s 给予更多探索空间

**类比**: 红绿灯（二值：-100/0）vs 测速罚款（连续：每超速1km/h罚1元）

---

## 2026-01-26: 修改目标采样逻辑 - 目标在无人机前方指定角度范围内 ✅

### 问题背景
之前尝试通过调整reset时的yaw朝向来避免初始大转弯，但实现复杂且容易出现command resample后yaw不匹配的问题。

### 解决方案
采用更简洁的方案：保持yaw随机，但让目标位置采样在无人机当前yaw的前方指定角度范围内。

### 修改文件
1. `drone_racer/tasks/drone_racer/mdp/pos_commands.py` - 修改采样逻辑
2. `drone_racer/tasks/drone_racer/uav_nav_env_cfg.py` - 添加angular_range_deg配置
3. `drone_racer/tasks/drone_racer/mdp/events.py` - 删除reset_root_state_facing_goal函数

### 实现细节

#### 1. 修改 PositionControlCommand._resample_command()
```python
def _resample_command(self, env_ids):
    # 获取robot当前yaw
    robot_quat = self.robot.data.root_quat_w[env_ids]
    robot_yaw = torch.atan2(
      2.0 * (robot_quat[:, 0] * robot_quat[:, 3] + robot_quat[:, 1] * robot_quat[:, 2]),
      1.0 - 2.0 * (robot_quat[:, 2]**2 + robot_quat[:, 3]**2)
    )
    
    # 在annular模式下：
    # - 采样半径：[radial_min, radial_max]
    # - 采样角度：robot_yaw ± angular_range_deg
    # - 相对robot位置计算目标点
    angular_range_rad = torch.deg2rad(torch.tensor(self.cfg.angular_range_deg))
    relative_angle = rand() * 2 * angular_range_rad - angular_range_rad
    angle = robot_yaw + relative_angle
    
    robot_pos = self.robot.data.root_pos_w[env_ids]
    x = robot_pos[:, 0] + radius * torch.cos(angle)
    y = robot_pos[:, 1] + radius * torch.sin(angle)
```

#### 2. 添加配置参数
在 `PositionControlCommandCfg` 中：
```python
angular_range_deg: float = 90.0
"""Angular constraint for target sampling relative to robot yaw. 
Target will be sampled within ±angular_range_deg from robot's forward direction."""
```

在 `CommandsCfg` 中使用：
```python
goal_command = mdp.PositionControlCommandCfg(
    ...
    angular_range_deg=90.0,  # Target in front 180° arc
)
```

#### 3. 恢复使用原生reset函数
在 `EventCfg` 中恢复使用 `mdp.reset_root_state_uniform`，yaw完全随机：
```python
reset_robot = EventTerm(
    func=mdp.reset_root_state_uniform,
    params={
      'pose_range': {
        'yaw': (-np.pi, np.pi),  # Random yaw
      }
    }
)
```

### 效果
- **`angular_range_deg = 90.0`**: 目标在无人机前方180°范围内（±90°）
- **`angular_range_deg = 60.0`**: 目标在无人机前方120°范围内（±60°）
- **`angular_range_deg = 45.0`**: 目标在无人机前方90°范围内（±45°）

无人机spawn后，目标点保证在其前方指定范围内，最多只需转动 `angular_range_deg` 即可朝向目标。

### 优势
1. **实现简单**: 不需要在reset事件中手动管理command的resample
2. **逻辑清晰**: 目标采样逻辑完全在command term内部，不涉及跨manager通信
3. **无竞态条件**: 避免了event和command_manager.reset()之间的顺序问题
4. **灵活配置**: 可以通过调整 `angular_range_deg` 来控制任务难度

### 测试结果
✅ 已在play模式下测试通过，无人机spawn后目标点确实在其前方指定角度范围内，避免了初始大幅度转向。

---

## 2026-01-26: 实现无人机朝向目标方向的智能reset机制（已废弃）

**注意：此方案因实现复杂且存在command resample时序问题已被废弃，改用上面的"目标在无人机前方"方案。**

---

## 2026-01-26: 显式配置地形障碍物参数

### 修改文件
- `drone_racer/tasks/drone_racer/uav_nav_env_cfg.py`

### 修改内容
在 `TerrainGeneratorCfg.sub_terrains['uni_terrain']` 中显式设置所有障碍物参数：

```python
UniformPillarsCapsuleTerrainCfg(
  function=UniformPillarsCapsuleTerrain,
  size=(50.0, 50.0),              # 地形大小（匹配父配置）
  base_obstacle_num=250,          # 障碍物数量
  pillar_height_range=(2.0, 8.0), # 柱子高度范围（米）
  pillar_radius_range=(0.3, 1.0), # 柱子半径范围（米）
  capsule_length_range=(0.2, 0.3),# 胶囊长度范围（米）
  capsule_radius_range=(0.1, 0.2),# 胶囊半径范围（米）
  safe_zone_size=(4.0, 4.0, 5.0), # spawn点安全区域（x,y,z米）
  pillar_prob=0.7,                # 柱子概率（0.7=70%柱子，30%胶囊）
)
```

### 改进
- **可读性**: 所有参数一目了然，无需查看类定义
- **可调性**: 方便快速调整地形难度，无需修改terrain类
- **文档化**: 参数注释说明了每个字段的作用和单位

---

## 2026-01-26: 实现 checkpoint 配置自动保存与加载

### 问题背景
用户遇到 checkpoint 兼容性问题：训练完成后，如果修改了观察空间（observations）或网络配置，旧的 checkpoint 就无法加载运行（"每次训完的权重我play的时候，如果我的观测更新了和原来的对应不上，就跑不了"）。

### 解决方案
实现训练时自动保存配置、推理时自动加载配置的机制，无需手动管理配置版本。

### 修改文件
- `drone_racer/scripts/rsl_rl/play.py`

### 实现细节

#### 1. 添加配置加载支持
在 play.py 中添加 `load_yaml` 导入：
```python
from isaaclab.utils.io import load_yaml
```

#### 2. 自动加载 checkpoint 配置
在加载 checkpoint 前，检查 checkpoint 对应的训练日志目录是否包含保存的配置文件：

```python
log_dir = Path(resume_path).parent  # checkpoint 目录
saved_env_cfg_path = log_dir.parent / 'params' / 'env.yaml'
saved_agent_cfg_path = log_dir.parent / 'params' / 'agent.yaml'

if saved_env_cfg_path.exists() and saved_agent_cfg_path.exists():
    # 加载环境配置（主要是 observations）
    saved_env_dict = load_yaml(saved_env_cfg_path)
    if 'observations' in saved_env_dict:
        env_cfg.observations = saved_env_dict['observations']
    
    # 加载智能体配置（policy 和 algorithm）
    saved_agent_dict = load_yaml(saved_agent_cfg_path)
    if 'policy' in saved_agent_dict:
        for key, value in saved_agent_dict['policy'].items():
            if hasattr(agent_cfg.policy, key):
                setattr(agent_cfg.policy, key, value)
```

#### 3. 训练脚本已有自动保存
train.py（第292-293行）已经在训练开始时自动保存配置：
```python
dump_yaml(str(log_dir / 'params' / 'env.yaml'), env_cfg)
dump_yaml(str(log_dir / 'params' / 'agent.yaml'), agent_cfg.to_dict())
```

### 目录结构
```
outputs/2026-01-26/experiment_name/
├── checkpoints/
│   ├── model_1000.pt
│   └── model_2000.pt
└── params/
    ├── env.yaml       # 保存的环境配置（observations 等）
    └── agent.yaml     # 保存的网络配置（policy, algorithm 等）
```

### 使用方式
**无需任何额外操作**：
- 训练时：配置文件自动保存到 `log_dir/params/`
- 推理时：从 checkpoint 对应的 `params/` 目录自动加载配置

如果没有找到保存的配置（旧的 checkpoint），会自动回退到使用当前代码中的配置。

### 优势
1. **零手动操作**：训练和推理都是自动的
2. **向后兼容**：旧 checkpoint 仍然可以用当前代码配置运行
3. **完全解耦**：checkpoint 和配置独立，可以随时修改当前代码而不影响已训练模型

---

## 2026-01-26: 调整 UAV Nav CNN 网络配置为 MasterRacing 风格

### 修改文件
- `drone_racer/tasks/drone_racer/rsl_rl_uav_nav_cfg.py`

### 修改内容

#### 1. CNN 结构调整（CnnCfg）
将 UAV Nav 任务的 CNN 配置改为与 MasterRacing 项目一致的结构：

**卷积层配置**：
- **通道数**：`[16, 32, 64]`（原：`[16, 8, 1]`）
- **卷积核大小**：`[3, 3, 2]`（原：`[7, 5, 3, 3]`）
- **步长**：`[3, 3, 2]`（原：`[2, 2, 2, 1]`）
- **扩张率**：`[1, 1, 1]`（原：`[1, 2, 2, 1]`）
- **填充方式**：`'none'`（字符串类型，原：数值列表）
- **激活函数**：`'lrelu'`（LeakyReLU，原：`'elu'`）
- **归一化**：`'batch'`（BatchNorm2d，原：`'none'`）

**图像处理流程**（72×96 输入）：
```
72×96 → Conv(16, 3×3, stride=3) → 24×32×16
      → Conv(32, 3×3, stride=3) → 8×10×32  
      → Conv(64, 2×2, stride=2) → 4×5×64
      → Flatten → 1280 维特征向量
```

#### 2. MLP 隐藏层调整
- **Actor hidden dims**：`[128, 128]`（原：`[64, 64, 64]`）
- **Critic hidden dims**：`[128, 128]`（原：`[256, 256, 256]`）
- **激活函数**：统一改为 `'lrelu'`

#### 3. 参数类型修正
- **重要**：`padding` 参数必须是字符串类型（`'none'`, `'zeros'`, `'reflect'`, `'replicate'`, `'circular'`），而不是数值列表
- 这是 rsl_rl CNN 类的 API 要求

### 网络架构说明

**完整数据流**：
```
输入观察 → 分离为 1D + 2D
         ↓
1D观察 (low_dim)  +  2D图像 (72×96)
         ↓                 ↓
    保持原样          CNN提取特征 (→1280维)
         ↓                 ↓
         ├─────────────────┤
         ↓ 拼接特征
    MLP [128, 128]
         ↓
      输出动作/价值
```

### 设计理念
- **CNN 作为特征提取器**：将 6912 维图像压缩为 1280 维特征
- **更小的 MLP**：CNN 已完成主要特征提取，128→128 足够学习特征组合
- **与 MasterRacing 对齐**：便于迁移学习和经验共享

### 支持的 rsl_rl 激活函数
验证了 `'lrelu'` 在 rsl_rl 中完全支持，其他可用激活函数包括：
`elu`, `selu`, `relu`, `crelu`, `lrelu`, `tanh`, `sigmoid`, `softplus`, `gelu`, `swish`, `mish`, `identity`

---

## 2026-01-26: 补充 interactive.py 交互式奖励调试脚本文档

### 脚本位置
- 文件：`drone_racer/scripts/rsl_rl/interactive.py`
- 快捷命令：`just interactive` 或 `just i` 或 `just int`

### 功能说明
这是一个**交互式奖励调试工具**，用于在 Isaac Sim GUI 中手动拖动无人机，实时观察奖励函数的变化。主要特性：

1. **单环境模式**：强制使用 1 个环境（`num_envs=1`），便于专注调试
2. **运动学模式**：允许在 GUI 中手动拖动无人机位置
3. **实时奖励显示**：在终端中实时打印总奖励和各个奖励分量
4. **与训练配置一致**：使用与 `train.py` 相同的环境配置，确保调试的奖励函数与实际训练一致
5. **零动作模式**：脚本发送零动作（悬停），用户通过 GUI 手动控制无人机

### 使用方法

#### 基础用法
```bash
# 使用默认任务 (Vtol-Collision-Avoidance)
cd drone_racer
just interactive

# 或使用别名
just i
just int
```

#### 指定任务
```bash
# 调试 UAV-Nav 任务
just interactive --task Uav-Nav

# 调试其他任务
just interactive --task Vtol-Collision-Avoidance-MLP
```

#### 操作步骤
1. **启动脚本**：执行 `just interactive`，会打开 Isaac Sim GUI
2. **启用运动学模式**：
   - 在视口中点击选中无人机
   - 按 **K** 键切换运动学模式
   - 或在 Property 面板中设置 `Physics > Rigid Body > Kinematic Target`
3. **拖动调试**：
   - 使用鼠标拖动无人机到不同位置
   - 观察终端中实时更新的奖励值
   - 脚本会每 50 步打印一次奖励总和及前 5 个奖励分量
4. **退出**：按 ESC 或关闭窗口

#### 输出示例
```
Step      0 | Reward:    1.234 | rew_pos: 0.456 | rew_vel: -0.123 | rew_collision: -2.000
Step     50 | Reward:    0.987 | rew_pos: 0.654 | rew_vel: -0.098 | rew_collision: 0.000
```

### 配置特点
- **禁用随机化**：更可预测的调试环境
- **禁用相机**：提升性能（`enable_cameras=False`）
- **强制 GUI 模式**：必须有图形界面（`headless=False`）
- **零动作输入**：发送全零动作，让无人机保持悬停状态

### 适用场景
- 🎯 调试奖励函数设计
- 🔍 验证碰撞检测逻辑
- 📊 观察不同位置的奖励分布
- 🐛 排查奖励异常行为
- 📝 理解奖励函数各分量的贡献

### 技术细节
- 使用 Hydra 配置系统，与训练脚本共享配置
- 自动处理观察空间和动作空间
- 支持所有已注册的任务 ID（Vtol-*、Uav-* 等）
- 发生 episode 终止时自动重置环境

---

## 2026-01-26: 修复远端LFS文件被还原为指针的问题

### 问题描述
执行 `just up` 同步代码后，发现远端的 `drone_racer/assets/5_in_drone/5_in_quadrotor.usd` 文件变成了 LFS 指针文件，内容为：
```
version https://git-lfs.github.com/spec/v1
oid sha256:eb9379717df9fb2cc961dc2f7d3f3ff992410f067f4b490796135bc6892516fa
size 5065
```
而不是真实的 USD 二进制内容。

### 根本原因
1. 脚本在远端应用变更时设置了 `GIT_LFS_SKIP_SMUDGE=1`
2. 执行 `git reset --hard` 或 `git apply` 时，LFS 文件被还原为指针文件
3. 脚本只传输"新增或修改"的 LFS 文件（`git diff --diff-filter=AM`）
4. 如果文件在此次同步中没有被修改，即使远端是指针文件，也不会被重新传输

### 修复内容
在 `transfer_codebase_by_git_diff.sh` 中添加第5步：**检测并修复远端的LFS指针文件**

**实现逻辑**：
1. 应用完所有变更后，在远端查找所有 LFS tracked 文件（当前聚焦于 drone_racer 子仓库）
2. 使用 `git check-attr filter` + `git ls-files` 检测 LFS 文件
3. 检查这些文件内容是否为指针（首行包含 `version https://git-lfs.github.com`）
4. 对于所有指针文件，从本地传输真实内容（使用 `scp`）
5. 只传输本地已下载的真实文件，跳过本地也是指针的文件

**效果**：
- ✅ 远端的 LFS 文件始终保持真实内容
- ✅ 自动修复因 git 操作导致的指针文件
- ✅ 无需手动干预或额外命令
- ✅ 支持所有 LFS tracked 文件类型（.usd、.pt 等）

**测试结果**：成功检测并修复了 `5_in_quadrotor.usd` 和 `arrow_x.usd` 两个指针文件。

---

## 2026-01-24: 修复 transfer_codebase_by_git_diff.sh

### 问题描述
1. 之前的 AI 修改导致脚本有bug，执行 `just up` 后本地的修改全部丢失（被reset）
2. 原脚本使用 `git diff` 无法识别新增的 untracked 文件和删除的文件
3. 脚本使用服务器别名（如 rec-server），不够直接

### 修复内容
1. **完全重写 `transfer_codebase_by_git_diff.sh`**
   - 不再使用服务器别名，直接使用环境变量 `$SERVER_IP`（默认：14.103.52.172）
   - 远端用户名固定为 `zhw`
   - 支持主仓库和所有子仓库（submodules）的变更检测
   - 使用 `git add -A` + `git diff --cached --binary` 来生成 patch，能正确识别：
     - 新增文件（untracked files）
     - 删除的文件
     - 修改的文件
     - 二进制文件
   - 生成 patch 后会恢复本地暂存区状态，不影响本地工作区
   - 远端应用 patch 前会 reset 远端的未提交更改并清理 untracked 文件

2. **更新 `justfile`**
   - `just up`: 执行 `./transfer_codebase_by_git_diff.sh`（无需参数）
   - `just sync-logs`: 执行 `./sync_server_logs.sh`

### 配置说明
脚本使用以下环境变量（均有默认值）：
- `SERVER_IP`: 远端服务器 IP（默认：14.103.52.172）
- `REMOTE_USER`: 远端用户名（默认：zhw）
- `LOCAL_PROJECT_DIR`: 本地项目路径（默认：$HOME/framework/server/）
- `REMOTE_PROJECT_DIR`: 远端项目路径（默认：/home/zhw/framework/server/）
- `SSH_KEY_PATH`: SSH 密钥路径（默认：$HOME/.ssh/id_rsa.pub）

### 使用方法
```bash
# 同步本地更改到远端服务器
just up

# 从远端服务器同步训练日志
just sync-logs
```

### 2026-01-24 14:57 修复远端路径

**问题**: `REMOTE_PROJECT_DIR` 默认使用了 `$HOME/framework/server/`，但 `$HOME` 会展开为本地用户路径 `/home/arc`，导致远端找不到目录。

**修复**: 将远端路径硬编码为 `/home/zhw/framework/server/`。

### 2026-01-24 15:00 修复 Git LFS 导致新增文件未应用

**问题**: 远端应用 patch 时，Git LFS 文件（如 .usd）触发 LFS smudge filter，因远端未配置 GitHub 凭据导致失败，进而导致整个 patch 应用不完整，新增的文件没有被创建。

**修复**: 在远端应用 patch 时设置 `GIT_LFS_SKIP_SMUDGE=1` 环境变量，跳过 LFS 文件的自动下载。patch 应用完成后重新启用 LFS。

**效果**: 
- 新增文件正常创建 ✅
- 删除文件正常删除 ✅
- 修改文件正常更新 ✅
- LFS 文件以 pointer 形式存在（需要时可手动 `git lfs pull`）

### 2026-01-24 15:09 自动传输 Git LFS 文件真实内容

**问题**: 虽然 patch 能应用成功，但 LFS 文件（如 .usd）在远端只是 pointer 文件，不是真实内容，导致程序运行时找不到文件。

**修复**: 
1. 在创建 patch 时，自动检测哪些文件是 LFS tracked 的
2. 收集所有新增或修改的 LFS 文件列表
3. patch 应用完成后，使用 `scp` 直接传输这些 LFS 文件的真实内容
4. 只传输本地已下载的真实文件（跳过本地也是 pointer 的文件）

**效果**: 
- LFS 文件自动传输为真实内容 ✅
- 无需远端配置 Git 凭据 ✅
- 远端可直接使用 USD 等资源文件 ✅

### 2026-01-24 15:12 添加 Tensorboard 端口映射命令

**新增**: `just tb-local-tunnel` 命令用于创建 SSH 隧道，将远端 Tensorboard 端口映射到本地。

**使用方法**:
```bash
just tb-local-tunnel 8008 7007 $SERVER_IP
# 将远端的 7007 端口映射到本地 8008 端口
# 然后在浏览器访问 http://localhost:8008
```

### 2026-01-24 15:39 支持识别已commit的变化

**问题**: 本地commit后，`just up` 识别不到commit的内容，只能同步未commit的工作区变化。

**修复**: 
1. 在创建patch前，先查询远端各仓库的HEAD commit
2. 对比本地HEAD与远端HEAD的差异
3. 如果本地领先，使用 `git bundle` 传输commits而非patch
4. Bundle 传输后，远端 `reset --hard` 到和本地相同的commit
5. 如果还有未commit的工作区变化，额外传patch
6. 在 bundle 应用和 reset 过程中禁用 Git LFS（`GIT_LFS_SKIP_SMUDGE=1`）避免凭据问题

**效果**:
- ✅ 能识别并同步已commit的变化
- ✅ 远端和本地的commit id完全一致
- ✅ 能识别并同步未commit的工作区变化
- ✅ 两者都有时，都会被同步
- ✅ 清晰显示patch包含的内容类型（committed / uncommitted / both）
- ✅ 无需在远端创建新commit，保持commit历史一致

**实现细节**:
- 使用 `git bundle create "remote_head..HEAD"` 创建增量 bundle
- 同时创建 `.head` 文件记录目标 commit hash
- 远端 fetch bundle 后 reset 到 `.head` 指定的 commit
- 所有 git 操作前设置 `GIT_LFS_SKIP_SMUDGE=1` 避免 LFS 触发下载

---