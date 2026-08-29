# Release build scripts

`BuildBlackMoonRelease.ps1` is the entry point used by the GitHub release
workflow. It builds the legacy Win32 archive, builds the selected modern core
revision for FNE metadata and the x64 fallback archive, then runs
`BuildBlackMoonCoreAdapter.ps1` to create the x64 ABI adapter.

The adapter scripts intentionally derive command mappings from the modern
core's metadata and the legacy source comments. They do not contain a list of
special-case command names. The modern core directory is an explicit input so
local builds and CI use the same dependency boundary.

For an already audited dependency set, pass `-X86MetadataFne`,
`-X64MetadataFne`, and `-X64FallbackLibrary` instead of using the modern
core's generated files. The FNE and archive versions must match.

All generated files are written below `artifacts/` (or the path passed to
`-OutputRoot`) and are ignored by Git. The source files in `krnln/` remain
CP936/GBK; the release script converts a private build copy to UTF-8 before
invoking MSBuild. Generated PowerShell and C++ files are UTF-8.

Tags without a prerelease suffix (for example `v1.2.3`) produce a stable
release. SemVer suffixes such as `-beta.1`, `-pre`, and `-rc.1` are recorded as
`prerelease` in `blackmoon-package.json`; the release workflow uses that field
to publish a GitHub Pre-release and leaves the repository's Latest release
unchanged. Legacy tags containing `beta`, `pre`, `alpha`, `preview`, `rc`, or
`dev` without a hyphen are recognized as prereleases as well.
