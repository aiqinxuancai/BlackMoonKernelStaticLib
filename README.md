## 黑月核心静态库

[![Release](https://github.com/zhongjianhua163/BlackMoonKernelStaticLib/actions/workflows/release.yml/badge.svg)](https://github.com/zhongjianhua163/BlackMoonKernelStaticLib/actions/workflows/release.yml)

[![Validation](https://github.com/zhongjianhua163/BlackMoonKernelStaticLib/actions/workflows/ci.yml/badge.svg)](https://github.com/zhongjianhua163/BlackMoonKernelStaticLib/actions/workflows/ci.yml)

## 编译与安装
  1. 根据你电脑上所安装的VS版本，打开对应的工程文件
  2. 打开工程后能看见三个方案：krnln、krnln_Obj、MFCBlackMoon。  
    通常情况下你不需要理会后两者，除非你知道它的作用。选中krnln方案，切换配置为Release，并编译。
  3. 编译后，将release目录下的kernel.lib替换到易语言安装目录的  
  \BlackMoon\obj\kernel.lib。(黑月4.0以上版本)  
  \BlackMoon\lib\kernel.lib。(黑月4.0以下版本)

## e-packager Release 包

`scripts/BuildBlackMoonRelease.ps1` 会生成可直接交给 e-packager 的统一目录：

```
adapter/
├── lib/x86/krnln.fne                 # x86 动态支持库元数据
├── lib/x64/krnln.fne                 # x64 动态支持库元数据
├── static_lib/x86/krnln_static.lib   # x86 静态实现
└── static_lib/x64/                   # x64 适配主归档、后备归档及清单
```

旧核心源码保存为 CP936/GBK。发布脚本会先在隔离工作区按 CP936 解码并转换为
UTF-8，再使用 `/source-charset:utf-8 /execution-charset:.936` 编译；资源编译
固定使用代码页 936。适配器生成的现代源码同样显式使用 UTF-8，因此结果不依赖
开发机或 GitHub runner 的系统区域设置，也不会把 CP936 选项错误地施加到 UTF-8
Windows SDK 头文件上。

x64 原始源码包含 x86 内联汇编和旧 ABI，不能直接把 x86 工程输出改名为 x64。
发布脚本会从本仓库源码生成 x64 主归档，并使用明确指定版本的现代核心源码生成
ABI 兼容的后备归档。`ModernCoreRoot` 必须指向包含
`支持库源码/krnln` 的 `ycIDE-electron` 工作区；脚本不会读取固定的开发机路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\BuildBlackMoonRelease.ps1 `
  -ModernCoreRoot D:\path\to\ycIDE-electron
```

如果已有经过验证的匹配文件，也可以用 `-X86MetadataFne`、`-X64MetadataFne`
和 `-X64FallbackLibrary` 显式覆盖 Action 默认构建的依赖；不要把不同版本的
FNE 与静态归档混用。

产物位于 `artifacts/release/`，包含合并包以及独立的 x86/x64 zip。Tag 发布还会
附加独立的 `-vc6.zip`，其中包含由 VC6 构建的 Win32 `krnln.lib` 与构建清单。
合并包同时提供根级 `lib/`、`static_lib/` 投影，解压后可直接叠加到
e-packager 产品目录；也可以只使用 `adapter/` 子目录。对 x64 e-packager
传入解压后的 `adapter` 目录：

```powershell
e-packager.exe compile input.e output.exe --arch x64 --compile-mode blackmoon `
  --blackmoon-x64-dir .\adapter
```

x86 黑月链接仍使用传统入口对象和 VC6 链接器；将
`adapter/static_lib/x86/krnln.lib`（或同目录的 `_static` 别名）作为核心归档
传入 `--lib` 即可替换实现。

这里的“动态库”指易语言支持库 `.fne`（接口和 ABI 元数据）；真正的函数实现位于
对应的静态归档中。`MFCBlackMoon` 工程中的入口对象用于传统黑月链接流程，
不应与 FNE 元数据混用。

推送 `v1.2.3` 会发布稳定 Release；推送 `v1.2.3-beta.1`、`v1.2.3-pre`、
`v1.2.3-rc.1` 等带后缀 tag 会发布 Pre-release，并且不会被标记为 Latest。
工作流也识别不带连字符的 `beta`、`pre`、`rc`、`alpha`、`preview` 和
`dev` 标志；只有稳定 tag 才会设置为 Latest。

## 源码使用事项
  原则上，只要不是商业用途及非法用途，源码可以任意使用及传播，
  编译后的静态库文件kernel.lib可以用于编译链接到商业作品中。  
  在复制与传播时，必须注明开源地址：  
  https://github.com/zhongjianhua163/BlackMoonKernelStaticLib (国外服务器)  
  https://gitee.com/zhongjianhua163/BlackMoonKernelStaticLib (国内服务器)

## 代码编写规范
  如果你想参与更新、优化或修复BUG，请仔细阅读以下事项：
  1. 代码的必须能让所有版本的VS通过编译，若需要使用特定版本的VS的特性，
    则需要合理使用宏 _MSC_VER 来进行兼容。
  2. 变量、常量、函数等命名时尽量能准确表达其属性及用途。
  3. 少用或尽量不要用内联汇编。
    如果必须要用到内联汇编，则尽量不要使用新的指令集，如SSE\AVX等。
    如果必须要用到新的指令集，请务必做好自适配代码，确保老的CPU及远古级别的
    32位CPU能正常运行，并实现指定效果。(常规做法是编写两份代码，一份使用新
    的指令集，另一份使用常规指令集，并根据用户的CPU所支持的指令集来进行调用)
  4. 确保代码的简洁美观、高效、稳定及安全性。
  5. 确保函数的参数、返回值及运行效果与易语言原生核心库保持一致。
  6. 编辑的源代码文件的时候，请使用ANSI和GB2312编码，切勿使用UTF8或其他编码。
  7. 使用git来push前，请将自动替换换行符功能: autoCRLF 设置为 false。

## 参与贡献
  1. 可以加入此开源项目的管理团队
  2. 可以在GitHub或Gitee中通过Issues页面提交错误和改进建议
  3. 可以在GitHub或Gitee中`Fork`, 修改后通过`Pull Request`合并代码


## 许可证
原作者：云外归鸟  
后续升级：泪闯天涯(邓学彬)  
后续优化：被封七号  
  
根据 `BSD 3-Clause` 获得许可
