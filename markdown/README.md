# ERIQ 评测资料包 - 文件索引

> 本目录包含在 WSL2 + RTX 4090 环境下评测开源大模型在智元 ERIQ 测试集上的完整资料。  
> **项目路径方案：E盘方案** — 所有项目文件、数据集、模型权重均存放在 `/mnt/e/Projects/eriq-eval/`（不占用C盘空间）

---

## 📚 文档类

| 文件 | 内容 | 阅读顺序 |
|------|------|---------|
| **`ERIQ-Zero-to-Hero-Guide.md`** | 零基础完全手册（环境搭建→模型推理→评分） | **第 1 本** |
| **`ERIQ-Model-Switching-SOP.md`** | 模型切换与对比评测专项 SOP | **第 2 本** |

---

## 🔧 脚本类

| 文件 | 功能 | 使用时机 |
|------|------|---------|
| **`setup_e_drive.sh`** | E盘项目一键初始化（创建目录+复制脚本+下载评测代码） | 选择E盘方案时运行 |
| **`setup_eriq_project.sh`** | 基础环境+conda+依赖一键初始化 | 首次环境搭建 |
| **`check_env.sh`** | 环境检查脚本（8 大维度逐项验证） | 每完成一个阶段后运行 |
| **`run_inference_universal.py`** | 通用推理脚本（命令行参数切换模型） | 单模型评测 |
| **`run_from_config.py`** | 配置驱动推理脚本（YAML 配置切换模型） | **推荐：多模型切换评测** |
| **`batch_evaluate.sh`** | 批量评测流水线（自动切换环境+调试+评分） | 一次性跑多个模型 |
| **`extract_scores.py`** | 评分提取与对比报告生成（表格+Markdown） | 所有模型跑完后 |
| **`compare_with_paper.py`** | 与 ERIQ 论文 Baseline 对比 | 最终报告阶段 |

---

## ⚙️ 配置类

| 文件 | 对应模型 | 说明 |
|------|---------|------|
| **`qwen2.5-vl-3b.yaml`** | Qwen2.5-VL-3B-Instruct | 快速调试用小模型 |
| **`qwen2.5-vl-7b.yaml`** | Qwen2.5-VL-7B-Instruct | ERIQ 论文 baseline |
| **`qwen3-vl-8b.yaml`** | Qwen3-VL-8B | 最新 Qwen 系列 |
| **`internvl2.5-8b.yaml`** | InternVL2.5-8B | 另一大模型系列示例 |

---

## 🚀 快速开始路径

### 路径 A：零基础首次搭建（E盘方案）
1. 阅读 `ERIQ-Zero-to-Hero-Guide.md` 全文
2. 运行 `bash setup_eriq_project.sh` 搭建 conda + PyTorch 环境
3. 运行 `bash setup_e_drive.sh` 在 E 盘创建项目结构
4. 运行 `bash check_env.sh` 验证
5. 按手册跑通第一个模型

### 路径 B：已有环境，直接切换模型跑对比
1. 阅读 `ERIQ-Model-Switching-SOP.md` 全文
2. 复制配置模板到 `/mnt/e/Projects/eriq-eval/configs/`
3. 修改 `batch_evaluate.sh` 中的模型列表
4. 运行 `cd /mnt/e/Projects/eriq-eval && bash scripts/batch_evaluate.sh`
5. 运行 `python scripts/extract_scores.py` 生成对比报告
6. 运行 `python scripts/compare_with_paper.py` 与论文对齐

---

## 📁 推荐的项目目录结构（运行 setup_e_drive.sh 后自动生成）

```
E:\Projects\eriq-eval\                    # Windows 侧看到的项目根目录
/mnt/e/Projects/eriq-eval/               # WSL2 侧访问的相同目录
├── configs/                               # 模型配置文件（.yaml）
│   ├── qwen2.5-vl-7b.yaml
│   └── internvl2.5-8b.yaml
├── data/                                  # ERIQ 数据集（约 4GB，在 E 盘）
│   ├── images/
│   ├── QA_*.json
│   └── subtasks.yaml
├── eval_code/                             # 官方评测脚本
│   └── eval_hf.py
├── models/                                # 模型权重缓存（10~20GB）
├── results/                               # 评测结果（JSON + 评分报告）
│   ├── qwen2.5-vl-7b_predictions.json
│   ├── qwen2.5-vl-7b_score.txt
│   ├── comparison.json                    # extract_scores.py 生成
│   └── comparison.md                      # Markdown 报告
├── scripts/                               # 推理与评测脚本
│   ├── run_from_config.py
│   ├── extract_scores.py
│   └── compare_with_paper.py
├── check_env.sh                          # 环境检查脚本
└── setup_e_drive.sh                      # E盘初始化脚本（本项目自带）
```

---

## 📝 关键概念速查

| 术语 | 含义 |
|------|------|
| **ERIQ** | Embodied Reasoning Intelligence Quotient，智元机器人开源的具身推理评测集 |
| **VLM** | Vision-Language Model，视觉语言模型（能看图+文字） |
| **Conda 环境隔离** | 每个模型系列一个独立环境，避免依赖冲突 |
| **HF-Mirror** | HuggingFace 国内镜像站 (hf-mirror.com)，加速模型下载 |
| **eval_hf.py** | ERIQ 官方评分脚本，计算加权平均准确率 |
| **config-driven** | 通过 YAML 配置文件切换模型，无需修改 Python 代码 |

---

## 🔗 外部资源

- **ERIQ 论文**: https://arxiv.org/abs/2512.24125
- **ERIQ GitHub**: https://github.com/GenieReasoner/ERIQ
- **ERIQ 数据集 (HF)**: https://huggingface.co/datasets/KineMind/ERIQ
- **HF-Mirror 镜像**: https://hf-mirror.com

---

*文档版本: 2025-04-27*
