# 资料包文件：从 Windows 复制到 WSL2 并运行操作指南

> **适用场景**：你把资料包文件下载到了 Windows（C盘/D盘/桌面/下载文件夹），现在需要在 WSL2-Ubuntu 里运行这些 `.sh` / `.py` / `.yaml` 文件。
> 
> **核心思路**：WSL2 把 Windows 磁盘挂载到了 `/mnt/` 下，所以 Linux 可以直接读取 Windows 文件。只需要"复制过去 → 赋执行权限 → 运行"。

---

## 目录

1. [WSL2 读取 Windows 文件的基本原理](#一wsl2-读取-windows-文件的基本原理)
2. [找到你的资料包在 WSL 中的路径](#二找到你的资料包在-wsl-中的路径)
3. [复制文件到 E 盘项目目录](#三复制文件到-e-盘项目目录)
4. [赋予执行权限并运行](#四赋予执行权限并运行)
5. [常见问题与排查](#五常见问题与排查)
6. [完整操作流（一步不漏）](#六完整操作流一步不漏)

---

## 一、WSL2 读取 Windows 文件的基本原理

### Windows 路径 vs WSL2 路径对照

| Windows 资源管理器里看到的路径 | WSL2 里对应的路径 |
|-----------------------------|------------------|
| `C:\Users\哈瑟尔88\Downloads` | `/mnt/c/Users/哈瑟尔88/Downloads` |
| `D:\下载` | `/mnt/d/下载` |
| `E:\Projects\eriq-eval` | `/mnt/e/Projects/eriq-eval` |
| `C:\Program Files` | `/mnt/c/Program Files` |

**规则**：把 Windows 路径中的反斜杠 `\` 换成斜杠 `/`，盘符 `X:` 换成 `/mnt/x/`，就能在 WSL 中访问。

### 在 WSL 中确认挂载

```bash
ls /mnt/
# 应输出类似：c  d  e
# 表示 C盘、D盘、E盘 都已挂载进 WSL2
```

---

## 二、找到你的资料包在 WSL 中的路径

### Step 1：在 Windows 侧确认文件位置

打开 Windows 文件资源管理器，找到你下载的资料包文件。

**常见位置**：
- `C:\Users\哈瑟尔88\Downloads\` （浏览器的"下载"文件夹）
- `C:\Users\哈瑟尔88\Desktop\` （桌面）
- `D:\下载\` （如果你改了下载路径）

**确认这些文件存在**：
- `setup_e_drive.sh`
- `setup_eriq_project.sh`
- `check_env.sh`
- `run_from_config.py`
- `extract_scores.py`
- `compare_with_paper.py`
- `*.yaml` 配置文件

### Step 2：在 WSL 中确认能读取到

打开 Ubuntu 终端，根据你的实际路径替换下面的命令：

**情况 A：文件在 C 盘下载文件夹**

```bash
ls /mnt/c/Users/哈瑟尔88/Downloads/
# 应看到资料包文件名
```

**情况 B：文件在 D 盘**

```bash
ls /mnt/d/
# 查看 D 盘根目录，或
ls /mnt/d/下载/
# 如果你在 D 盘创建了"下载"文件夹
```

**情况 C：文件在桌面**

```bash
ls /mnt/c/Users/哈瑟尔88/Desktop/
```

> **如果用户名包含中文（如"哈瑟尔88"），直接输入中文即可**，WSL2 完全支持中文路径。

---

## 三、复制文件到 E 盘项目目录

### Step 3：创建目标目录（如果还没创建）

```bash
# 创建 E 盘项目目录
mkdir -p /mnt/e/Projects/eriq-eval/{scripts,configs,eval_code}

# 验证
ls /mnt/e/Projects/eriq-eval/
# 应看到：scripts  configs  eval_code（或其他你创建的子目录）
```

### Step 4：复制 .sh 脚本到项目根目录

假设你的资料包在 `C:\Users\哈瑟尔88\Downloads\`：

```bash
# 复制所有 .sh 文件到项目根目录
# 注意：Windows 文件名可能有空格，用引号包裹
cp /mnt/c/Users/哈瑟尔88/Downloads/setup_e_drive.sh /mnt/e/Projects/eriq-eval/
cp /mnt/c/Users/哈瑟尔88/Downloads/setup_eriq_project.sh /mnt/e/Projects/eriq-eval/
cp /mnt/c/Users/哈瑟尔88/Downloads/check_env.sh /mnt/e/Projects/eriq-eval/

# 如果文件多，可以一次复制多个
cp /mnt/c/Users/哈瑟尔88/Downloads/*.sh /mnt/e/Projects/eriq-eval/
```

**验证复制是否成功**：
```bash
ls -l /mnt/e/Projects/eriq-eval/*.sh
# 应看到 3 个 .sh 文件，且大小不是 0
```

### Step 5：复制 .py 脚本到 scripts/ 目录

```bash
cp /mnt/c/Users/哈瑟尔88/Downloads/run_from_config.py /mnt/e/Projects/eriq-eval/scripts/
cp /mnt/c/Users/哈瑟尔88/Downloads/extract_scores.py /mnt/e/Projects/eriq-eval/scripts/
cp /mnt/c/Users/哈瑟尔88/Downloads/compare_with_paper.py /mnt/e/Projects/eriq-eval/scripts/

# 或者一次性复制
cp /mnt/c/Users/哈瑟尔88/Downloads/*.py /mnt/e/Projects/eriq-eval/scripts/
```

**验证**：
```bash
ls -l /mnt/e/Projects/eriq-eval/scripts/
```

### Step 6：复制 .yaml 配置文件到 configs/ 目录

```bash
cp /mnt/c/Users/哈瑟尔88/Downloads/*.yaml /mnt/e/Projects/eriq-eval/configs/

# 验证
ls -l /mnt/e/Projects/eriq-eval/configs/
# 应看到：qwen2.5-vl-3b.yaml  qwen2.5-vl-7b.yaml  qwen3-vl-8b.yaml  internvl2.5-8b.yaml
```

### Step 7：确认最终目录结构

```bash
cd /mnt/e/Projects/eriq-eval
tree -L 2 . 2>/dev/null || find . -maxdepth 2 | sort
```

**期望的输出**：
```
.
./check_env.sh
./configs
./configs/internvl2.5-8b.yaml
./configs/qwen2.5-vl-3b.yaml
./configs/qwen2.5-vl-7b.yaml
./configs/qwen3-vl-8b.yaml
./eval_code
./eval_code/eval_hf.py        ← 从 GitHub 下载的
./scripts
./scripts/compare_with_paper.py
./scripts/extract_scores.py
./scripts/run_from_config.py
./setup_e_drive.sh
./setup_eriq_project.sh
```

---

## 四、赋予执行权限并运行

### Step 8：给 .sh 文件添加执行权限

Linux 下刚复制过来的文件默认没有"可执行"权限，必须手动加上：

```bash
cd /mnt/e/Projects/eriq-eval

# 给所有 .sh 文件添加执行权限
chmod +x *.sh

# 验证（权限位中出现 x）
ls -l *.sh
# 输出示例：
# -rwxrwxrwx 1 adminxidaduo adminxidaduo  2.3K  setup_e_drive.sh
#                    ↑
#                    这里出现 x 表示可执行
```

### Step 9：运行脚本

```bash
# 先运行环境检查
cd /mnt/e/Projects/eriq-eval
bash check_env.sh

# 如果环境检查通过，运行 E 盘初始化
bash setup_e_drive.sh

# 如果需要重新装环境（一般不需要，你已经有 conda 了）
# bash setup_eriq_project.sh
```

> **注意**：运行 `.sh` 脚本有两种写法，效果相同：
> - `bash check_env.sh` （推荐，不需要 chmod +x 也能运行）
> - `./check_env.sh` （需要先 chmod +x）
> 
> 如果报错 `Permission denied`，用 `bash xxx.sh` 方式即可。

---

## 五、常见问题与排查

### 问题 1：找不到 Windows 文件路径

**现象**：`ls /mnt/c/Users/...` 报错 `No such file or directory`

**排查步骤**：

```bash
# 1. 确认 C 盘已挂载
ls /mnt/c/
# 应能看到 Windows 的文件夹

# 2. 如果 C 盘没挂载，检查 WSL 配置
mount | grep /mnt/c
# 应看到 drvfs 挂载信息

# 3. 如果完全没输出，重启 WSL
wsl --shutdown
# 然后重新打开 Ubuntu 终端

# 4. 如果文件名有空格，用引号包裹
ls "/mnt/c/Users/哈瑟尔88/Downloads/"
```

### 问题 2：复制时报错 `cp: cannot stat ...`

**原因**：文件名写错了，或路径中有空格没有用引号。

**解决**：
```bash
# 先列出目录确认文件名
ls /mnt/c/Users/哈瑟尔88/Downloads/ | grep setup

# 如果文件名是 setup_e_drive.sh.txt（Windows 自动加了扩展名）
cp /mnt/c/Users/哈瑟尔88/Downloads/setup_e_drive.sh.txt /mnt/e/Projects/eriq-eval/setup_e_drive.sh

# 或者用 Tab 自动补全（按 Tab 键）
cp /mnt/c/Users/哈瑟尔88/Downloads/setup<Tab>
# 系统会自动补全文件名
```

### 问题 3：运行 .sh 时报错 `/bin/bash^M: bad interpreter`

**原因**：Windows 编辑器保存的文件使用了 CRLF 换行符（`\r\n`），Linux 只认 LF（`\n`）。

**解决**：
```bash
# 方法 1：用 dos2unix 转换（推荐）
sudo apt install -y dos2unix
dos2unix /mnt/e/Projects/eriq-eval/*.sh

# 方法 2：用 sed 直接替换
sed -i 's/\r$//' /mnt/e/Projects/eriq-eval/*.sh

# 方法 3：用 Vim 打开后设置
vim /mnt/e/Projects/eriq-eval/setup_e_drive.sh
# 在 Vim 中输入 :set fileformat=unix 然后保存 :wq
```

**预防**：以后在 Windows 下编辑脚本时，用 VS Code 并把右下角换行符改成 **LF**（不是 CRLF）。

### 问题 4：运行 .sh 时报错 `Permission denied`

**原因**：文件没有执行权限。

**解决**：
```bash
chmod +x /mnt/e/Projects/eriq-eval/*.sh

# 或者用 bash 直接运行（不需要执行权限）
bash /mnt/e/Projects/eriq-eval/setup_e_drive.sh
```

### 问题 5：Windows 资源管理器中文路径显示乱码

**原因**：WSL 和 Windows 的字符编码不一致。

**解决**：不影响实际复制，直接按中文输入即可：
```bash
# 即使资源管理器显示乱码，WSL 中路径是正确的
ls /mnt/c/Users/哈瑟尔88/Downloads/
# 能正常列出文件就说明路径对了
```

### 问题 6：`hf` 命令找不到

**原因**：资料包里没有 `hf` 这个命令，`hf` 是 HuggingFace 的命令行工具，需要单独安装。

**解决**：
```bash
# 新版 transformers 通常自带 huggingface-hub
pip install --upgrade huggingface-hub

# 验证
which hf
# 应输出路径，如 /home/adminxidaduo/.local/bin/hf

# 如果 which hf 没输出，可能需要把 .local/bin 加到 PATH
echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

---

## 六、完整操作流（一步不漏）

把下面这段复制到一个文本文件里，逐行执行：

```bash
# ===== 第 0 步：确认自己在 Ubuntu 终端里 =====
echo $USER
# 应输出: adminxidaduo

# ===== 第 1 步：确认 Windows 文件能读到 =====
ls /mnt/c/Users/哈瑟尔88/Downloads/*.sh
# 应看到 setup_e_drive.sh 等

# ===== 第 2 步：创建 E 盘项目目录 =====
mkdir -p /mnt/e/Projects/eriq-eval/{scripts,configs,eval_code}

# ===== 第 3 步：复制所有文件 =====
cp /mnt/c/Users/哈瑟尔88/Downloads/*.sh /mnt/e/Projects/eriq-eval/
cp /mnt/c/Users/哈瑟尔88/Downloads/*.py /mnt/e/Projects/eriq-eval/scripts/
cp /mnt/c/Users/哈瑟尔88/Downloads/*.yaml /mnt/e/Projects/eriq-eval/configs/

# ===== 第 4 步：处理换行符（Windows → Linux）=====
sed -i 's/\r$//' /mnt/e/Projects/eriq-eval/*.sh

# ===== 第 5 步：赋执行权限 =====
chmod +x /mnt/e/Projects/eriq-eval/*.sh

# ===== 第 6 步：验证目录结构 =====
cd /mnt/e/Projects/eriq-eval
ls -l *.sh
ls -l scripts/
ls -l configs/

# ===== 第 7 步：运行环境检查 =====
bash check_env.sh

# ===== 第 8 步：运行 E 盘初始化 =====
bash setup_e_drive.sh

# ===== 第 9 步：下载数据集 =====
cd /mnt/e/Projects/eriq-eval/data
hf download --repo-type dataset KineMind/ERIQ --local-dir .
```

---

**如果在任何一步报错，把完整的错误信息复制给我，我帮你判断是哪种问题。**
