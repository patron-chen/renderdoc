# Build scripts

The build.sh in this folder is used for building packaged builds of renderdoc on both windows and linux.

On windows the only supported environment is a MSYS2 bash shell, other shells may work but modifications to support them are unlikely to be accepted.

Running build.sh will print the usage instructions. It can be run from anywhere.

By default it will compile everything and package, which will work out of a fresh checkout. You can also pass --skipcompile to package already built binaries, but in this case ensure that everything is compiled as expected:

* On windows, Win32 and x64 Release targets must be built.
* On windows, the `htmlhelp` docs target must be built, and on Linux the `html` target.
* On all platforms, an arm32 android build must exist in the `build-android-arm32` subfolder under the root, and likewise for arm64.
* On linux, the cmake build must be `make installed` to a `dist` folder in the root.

As above, running build.sh by default will compile all this.

# Running

Running build.sh apart from the optional arguments must pass `--snapshot <name>`. The name is used in packaging, i.e. the resulting zips will be `RenderDoc_name.zip`.

The output files will be placed in a `package` subfolder under the root.

`gpg` is used to generate signatures for the file, so a public/private key should be configured.

# Extras

Some extra files can be used, see the `support` subfolder. Also https://renderdoc.org/plugins.zip contains the windows plugins, and https://renderdoc.org/plugins.tgz contains the linux plugins. Extracting these in the root of the repository will be included in the package builds.

On windows PySide2 can be included with the Qt build by extracting https://renderdoc.org/qrenderdoc_3rdparty.zip in the root.

For windows to build installers, all these extras must be present.

# Requirements

In addition to the usual build requirements for native and android builds, windows requires the WiX toolset to generate installer files.

Linux requires docker to build the tool in an isolated container for maximum compatibility, although using the above mentioned `--skipcompile` you could get around this by building locally.

Both platforms require s phinx to be available in python, and in addition windows requires the HTML help workshop.

## Local Android APK builds on Windows

Use `build_android_apks.bat` from a normal Command Prompt or PowerShell session to generate and build stripped Release APKs for both supported ARM ABIs:

```
util\buildscripts\build_android_apks.bat
```

The script creates `build-android-release-arm32` and `build-android-release-arm64`, verifies both APK signatures, and copies the results to `x64\Development\plugins\android`. Run with `--help` for single-ABI, configure-only, toolchain-path, and parallel-build options.

The script uses one JDK from `JAVA_HOME` or `-JdkHome`; JDK 17 is recommended. It selects the newest installed Android build-tools version containing `d8` by default, avoiding the legacy `dx` tool and its Java 8 requirement. The default minimum Android API level is 28.

Android cross-compilation also requires a Windows C++ compiler for host helper tools. The script uses `-HostCppCompiler` when provided, then searches `CXX`, MinGW in `PATH`, and Visual Studio LLVM installations.

For the MinGW Makefiles generator, the script uses `-MakeProgram`, `mingw32-make.exe` from `PATH`, or the Android NDK's bundled `make.exe`, in that order.
