# Microsoft Visual C++ runtime

Windows SDKs include the release DLLs from the selected Visual Studio toolset's
`VCToolsRedistDir/<architecture>/Microsoft.VC*.CRT` directory. These Microsoft
files are subject to their own license terms, not this repository's MIT license.

The original runtime license documents are included for both supported Visual
Studio generations:

- [Visual Studio 2022 runtime terms](https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/)
- [Visual Studio 2026 runtime terms](https://visualstudio.microsoft.com/license-terms/vs2026-ga-visualcpp-v14-redist-runtime/)

Deploy all SDK `lib/*.dll` files alongside the application's executable. Entries
in `runtimeLibraries` are deployment dependencies; they do not have SDK import
libraries or CMake link targets. Windows supplies the Universal CRT and ICU.
