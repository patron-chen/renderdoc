/******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2016-2026 Baldur Karlsson
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 ******************************************************************************/

#include "common/common.h"
#include "common/threading.h"
#include "hooks/hooks.h"
#include "plthook/plthook.h"

#include <android/dlext.h>
#include <dlfcn.h>
#include <errno.h>
#include <jni.h>
#include <link.h>
#include <stddef.h>
#include <sys/mman.h>
#include <unistd.h>
#include <algorithm>
#include <map>
#include <set>

// uncomment the following to print (very verbose) debugging prints for the android PLT hooking
// #define HOOK_DEBUG_PRINT(...) RDCLOG(__VA_ARGS__)

#if !defined(HOOK_DEBUG_PRINT)
#define HOOK_DEBUG_PRINT(...) \
  do                          \
  {                           \
  } while(0)
#endif

// from plthook_elf.c
#if defined __x86_64__ || defined __x86_64
#define R_JUMP_SLOT R_X86_64_JUMP_SLOT
#define Elf_Rel ElfW(Rela)
#define ELF_R_TYPE ELF64_R_TYPE
#define ELF_R_SYM ELF64_R_SYM
#elif defined __i386__ || defined __i386
#define R_JUMP_SLOT R_386_JMP_SLOT
#define Elf_Rel ElfW(Rel)
#define ELF_R_TYPE ELF32_R_TYPE
#define ELF_R_SYM ELF32_R_SYM
#elif defined __arm__ || defined __arm
#define R_JUMP_SLOT R_ARM_JUMP_SLOT
#define Elf_Rel ElfW(Rel)
#define ELF_R_TYPE ELF32_R_TYPE
#define ELF_R_SYM ELF32_R_SYM
#elif defined __aarch64__ || defined __aarch64 /* ARM64 */
#define R_JUMP_SLOT R_AARCH64_JUMP_SLOT
#define Elf_Rel ElfW(Rela)
#define ELF_R_TYPE ELF64_R_TYPE
#define ELF_R_SYM ELF64_R_SYM
#else
#error unsupported OS
#endif

class HookingInfo
{
public:
  void AddFunctionHook(const FunctionHook &hook)
  {
    SCOPED_LOCK(lock);
    funchooks.push_back(hook);

    // add to map to speed-up lookup in GetFunctionHook
    funchook_map[hook.function] = hook;

    AddDynamicFunctionHook_locked(hook);
  }

  void AddLibHook(const rdcstr &name)
  {
    SCOPED_LOCK(lock);
    if(!libhooks.contains(name))
      libhooks.push_back(name);

    AddDynamicLibHook_locked(name);
  }

  void AddDynamicFunctionHook(const FunctionHook &hook)
  {
    SCOPED_LOCK(lock);
    AddDynamicFunctionHook_locked(hook);
  }

  void AddDynamicLibHook(const rdcstr &name)
  {
    SCOPED_LOCK(lock);
    AddDynamicLibHook_locked(name);
  }

  void AddHookCallback(const rdcstr &name, FunctionLoadCallback callback)
  {
    SCOPED_LOCK(lock);
    hookcallbacks[name].push_back(callback);
  }

  rdcarray<FunctionHook> GetFunctionHooks()
  {
    SCOPED_LOCK(lock);
    return funchooks;
  }

  void ClearHooks()
  {
    SCOPED_LOCK(lock);
    libhooks.clear();
    funchooks.clear();
    funchook_map.clear();
  }

  rdcarray<rdcstr> GetLibHooks()
  {
    SCOPED_LOCK(lock);
    return libhooks;
  }

  std::map<rdcstr, rdcarray<FunctionLoadCallback>> GetHookCallbacks()
  {
    SCOPED_LOCK(lock);
    return hookcallbacks;
  }

  FunctionHook GetFunctionHook(const rdcstr &name)
  {
    SCOPED_LOCK(lock);
    return funchook_map[name];
  }

  rdcarray<rdcstr> GetDynamicLibHooks()
  {
    SCOPED_LOCK(lock);
    return dynamic_libhooks;
  }

  FunctionHook GetDynamicFunctionHook(const rdcstr &name)
  {
    SCOPED_LOCK(lock);
    return dynamic_funchook_map[name];
  }

  bool IsLibHook(const rdcstr &path)
  {
    SCOPED_LOCK(lock);
    for(const rdcstr &filename : libhooks)
    {
      if(path.contains(filename))
      {
        HOOK_DEBUG_PRINT("Intercepting and returning ourselves for %s (matches %s)", path.c_str(),
                         filename.c_str());
        return true;
      }
    }

    return false;
  }

  bool IsLibHook(void *handle)
  {
    SCOPED_LOCK(lock);
    for(const rdcstr &lib : libhooks)
    {
      void *libHandle = dlopen(lib.c_str(), RTLD_NOLOAD);
      HOOK_DEBUG_PRINT("%s is %p", lib.c_str(), libHandle);
      if(libHandle == handle)
        return true;
    }

    return false;
  }

  bool IsDynamicLibHook(void *handle)
  {
    SCOPED_LOCK(lock);
    for(const rdcstr &lib : dynamic_libhooks)
    {
      void *libHandle = dlopen(lib.c_str(), RTLD_NOLOAD);
      if(libHandle == handle)
        return true;
    }

    return false;
  }

  void SetDynamicFunctionDispatched(const rdcstr &name)
  {
    SCOPED_LOCK(lock);
    dynamic_dispatched.insert(name);
  }

  bool WasDynamicFunctionDispatched(const rdcstr &name)
  {
    SCOPED_LOCK(lock);
    return dynamic_dispatched.find(name) != dynamic_dispatched.end();
  }

  bool IsHooked(void *handle)
  {
    SCOPED_LOCK(lock);
    bool ret = hooked_handle_already.find(handle) != hooked_handle_already.end();
    return ret;
  }

  bool IsHooked(const rdcstr &soname)
  {
    SCOPED_LOCK(lock);
    if(hooked_soname_already.find(soname) != hooked_soname_already.end())
      return true;

    // above will be absolute path, allow substring matches
    for(const rdcstr &fn : hooked_soname_already)
      if(soname.contains(fn))
        return true;

    return false;
  }

  void SetHooked(void *handle)
  {
    SCOPED_LOCK(lock);
    hooked_handle_already.insert(handle);
  }

  void SetHooked(const rdcstr &soname)
  {
    SCOPED_LOCK(lock);
    hooked_soname_already.insert(soname);
  }

private:
  void AddDynamicFunctionHook_locked(const FunctionHook &hook)
  {
    dynamic_funchook_map[hook.function] = hook;
  }

  void AddDynamicLibHook_locked(const rdcstr &name)
  {
    if(!dynamic_libhooks.contains(name))
      dynamic_libhooks.push_back(name);
  }

  std::set<rdcstr> hooked_soname_already;
  std::set<void *> hooked_handle_already;

  rdcarray<FunctionHook> funchooks;
  std::map<rdcstr, FunctionHook> funchook_map;
  rdcarray<rdcstr> libhooks;

  // These survive ClearHooks(), which only switches successful interceptor-lib hooks away from
  // the PLT fallback. Dynamic symbol lookup must still be able to return those wrappers.
  std::map<rdcstr, FunctionHook> dynamic_funchook_map;
  rdcarray<rdcstr> dynamic_libhooks;
  std::set<rdcstr> dynamic_dispatched;

  std::map<rdcstr, rdcarray<FunctionLoadCallback>> hookcallbacks;

  Threading::CriticalSection lock;
};

HookingInfo &GetHookInfo()
{
  static HookingInfo hookinfo;
  return hookinfo;
}

void *intercept_dlopen(const char *filename, int flag)
{
  if(filename)
  {
    // if this is a library we're hooking, or a request for our own library in any form, return our
    // own library.
    // We need to intercept requests for our own library, because the android loader makes the
    // completely ridiculous decision to load multiple copies of the same library into a process if
    // it's dlopen'd with different paths. This obviously breaks with our hook install.
    if(strstr(filename, RENDERDOC_ANDROID_LIBRARY) || GetHookInfo().IsLibHook(rdcstr(filename)))
    {
      HOOK_DEBUG_PRINT("Intercepting dlopen for %s", filename);
      return dlopen(RENDERDOC_ANDROID_LIBRARY, flag);
    }
  }

  return NULL;
}

// we need this on both paths since interceptor-lib is unable to hook dlopen in libvulkan.so
static int dl_iterate_callback(struct dl_phdr_info *info, size_t size, void *data)
{
  if(info->dlpi_name == NULL)
  {
    HOOK_DEBUG_PRINT("Skipping NULL entry!");
    return 0;
  }
  rdcstr soname = info->dlpi_name;

  if(GetHookInfo().IsHooked(soname))
    return 0;

  HOOK_DEBUG_PRINT("Hooking %s", soname.c_str());
  GetHookInfo().SetHooked(soname);

  for(int ph = 0; ph < info->dlpi_phnum; ph++)
  {
    if(info->dlpi_phdr[ph].p_type != PT_DYNAMIC)
      continue;

    ElfW(Dyn) *dynamic = (ElfW(Dyn) *)(info->dlpi_addr + info->dlpi_phdr[ph].p_vaddr);

    ElfW(Sym) *dynsym = NULL;
    const char *strtab = NULL;
    size_t strtabcount = 0;
    Elf_Rel *pltbase = NULL;
    ElfW(Sword) pltcount = 0;

    while(dynamic->d_tag != DT_NULL)
    {
      if(dynamic->d_tag == DT_SYMTAB)
        dynsym = (ElfW(Sym) *)(info->dlpi_addr + dynamic->d_un.d_ptr);
      else if(dynamic->d_tag == DT_STRTAB)
        strtab = (const char *)(info->dlpi_addr + dynamic->d_un.d_ptr);
      else if(dynamic->d_tag == DT_STRSZ)
        strtabcount = dynamic->d_un.d_val;
      else if(dynamic->d_tag == DT_JMPREL)
        pltbase = (Elf_Rel *)(info->dlpi_addr + dynamic->d_un.d_ptr);
      else if(dynamic->d_tag == DT_PLTRELSZ)
        pltcount = dynamic->d_un.d_val / sizeof(Elf_Rel);

      /*
      if(dynamic->d_tag == DT_NEEDED)
        HOOK_DEBUG_PRINT("NEEDED [%i, %s]", dynamic->d_un.d_val, strtab + dynamic->d_un.d_val);
        */

      dynamic++;
    }

    if(!dynsym || !strtab || !pltbase || pltcount == 0 || strtabcount == 0)
    {
      RDCWARN("Missing required section to hook %s", info->dlpi_name);
      continue;
    }

    void **relro_base = NULL;
    void **relro_end = NULL;
    bool relro_failed = false;

    FILE *f = FileIO::fopen(info->dlpi_name, FileIO::ReadText);

    // read the file on disk to get the .relro section
    if(f)
    {
      ElfW(Ehdr) ehdr;
      size_t read = FileIO::fread(&ehdr, sizeof(ehdr), 1, f);

      if(read == 1 && ehdr.e_ident[0] == ELFMAG0 && ehdr.e_ident[1] == 'E' &&
         ehdr.e_ident[2] == 'L' && ehdr.e_ident[3] == 'F')
      {
        FileIO::fseek64(f, ehdr.e_phoff, SEEK_SET);
        for(ElfW(Half) idx = 0; idx < ehdr.e_phnum; idx++)
        {
          ElfW(Phdr) phdr;
          read = FileIO::fread(&phdr, sizeof(phdr), 1, f);
          if(read != 1)
          {
            RDCWARN("Failed reading section");
            break;
          }

          if(phdr.p_type == PT_GNU_RELRO)
          {
            relro_base = (void **)(info->dlpi_addr + phdr.p_vaddr);
            relro_end = (void **)(info->dlpi_addr + phdr.p_vaddr + phdr.p_memsz);
          }
        }
      }
      else
      {
        RDCWARN("Didn't get valid ELF header");
      }

      FileIO::fclose(f);
    }
    else
    {
      RDCWARN("Couldn't open '%s' to look for relro!", info->dlpi_name);
      relro_failed = true;
    }

    if(relro_base)
      HOOK_DEBUG_PRINT("Got relro %p -> %p", relro_base, relro_end);
    HOOK_DEBUG_PRINT("Got %i PLT entries", pltcount);

    int pagesize = sysconf(_SC_PAGE_SIZE);

    for(ElfW(Sword) i = 0; i < pltcount; i++)
    {
      Elf_Rel *plt = pltbase + i;
      if(ELF_R_TYPE(plt->r_info) != R_JUMP_SLOT)
      {
        HOOK_DEBUG_PRINT("[%i]: Mismatched type %i vs %i", i, ELF_R_TYPE(plt->r_info), R_JUMP_SLOT);
        continue;
      }

      size_t idx = ELF_R_SYM(plt->r_info);
      size_t name = dynsym[idx].st_name;
      if(name + 1 > strtabcount)
      {
        HOOK_DEBUG_PRINT("[%i] name out of boundstoo big section header string table index: %zu", i,
                         name);
        continue;
      }

      const char *importname = strtab + name;
      void **import = (void **)(info->dlpi_addr + plt->r_offset);

      HOOK_DEBUG_PRINT("[%i] %s at %p (ptr to %p)", i, importname, import, *import);

      const FunctionHook repl = GetHookInfo().GetFunctionHook(importname);
      if(repl.hook)
      {
        HOOK_DEBUG_PRINT("replacing %s!", importname);

        uintptr_t pagebase = 0;

        if(relro_failed || (relro_base <= import && import <= relro_end))
        {
          if(relro_failed)
            HOOK_DEBUG_PRINT("Couldn't get relro sections - mapping read/write");
          else
            HOOK_DEBUG_PRINT("In relro range - %p <= %p <= %p", relro_base, import, relro_end);
          pagebase = uintptr_t(import) & ~(pagesize - 1);

          int ret = mprotect((void *)pagebase, pagesize, PROT_READ | PROT_WRITE);
          if(ret != 0)
          {
            RDCERR("Couldn't read/write the page: %d %d", ret, errno);
            return 0;
          }

          HOOK_DEBUG_PRINT("Marked page read/write");
        }
        else
        {
          HOOK_DEBUG_PRINT("Not in relro! - %p vs %p vs %p", relro_base, import, relro_end);
        }

        // note we don't save the orig function here, since we want to apply our library priorities
        // and we don't know what order these headers will be iterated in. See EndHookRegistration
        // for where we iterate and fetch all the function pointers we want.
        *import = repl.hook;

        if(pagebase)
        {
          if(relro_failed)
          {
            HOOK_DEBUG_PRINT(
                "Couldn't find relro sections - being conservative and leaving read-write");
          }
          else
          {
            HOOK_DEBUG_PRINT("Moving back to read-only");
            mprotect((void *)pagebase, pagesize, PROT_READ);
          }
        }

        HOOK_DEBUG_PRINT("[%i*] %s at %p (ptr to %p)", i, importname, import, *import);
      }
    }
  }

  return 0;
}

static void PatchLibraryContaining(void *symbol)
{
  if(symbol == NULL)
    return;

  Dl_info dlInfo = {};
  if(dladdr(symbol, &dlInfo) == 0 || dlInfo.dli_fbase == NULL || dlInfo.dli_fname == NULL)
    return;

  const ElfW(Ehdr) *ehdr = (const ElfW(Ehdr) *)dlInfo.dli_fbase;
  if(ehdr->e_ident[0] != ELFMAG0 || ehdr->e_ident[1] != ELFMAG1 || ehdr->e_ident[2] != ELFMAG2 ||
     ehdr->e_ident[3] != ELFMAG3)
    return;

  struct dl_phdr_info phdrInfo = {};
  phdrInfo.dlpi_addr = (ElfW(Addr))dlInfo.dli_fbase;
  phdrInfo.dlpi_name = dlInfo.dli_fname;
  phdrInfo.dlpi_phdr = (const ElfW(Phdr) *)(phdrInfo.dlpi_addr + (ElfW(Addr))ehdr->e_phoff);
  phdrInfo.dlpi_phnum = ehdr->e_phnum;

  // Android linker namespaces can hide a dlopen'd library from dl_iterate_phdr. A symbol returned
  // by dlsym still gives us enough ELF metadata to patch that library's imports directly.
  dl_iterate_callback(&phdrInfo, sizeof(phdrInfo), NULL);
}

// android has a special dlopen that passes the caller address in.
typedef void *(*pfn__loader_dlopen)(const char *filename, int flags, const void *caller_addr);

typedef void *(*pfnandroid_dlopen_ext)(const char *__filename, int __flags,
                                       const android_dlextinfo *__info);

pfnandroid_dlopen_ext real_android_dlopen_ext = NULL;

pfn__loader_dlopen loader_dlopen = NULL;
uint64_t suppressTLS = 0;

void process_dlopen(const char *filename, int flag)
{
  if(filename && !GetHookInfo().IsHooked(rdcstr(filename)))
  {
    HOOK_DEBUG_PRINT("iterating after %s", filename);
    dl_iterate_phdr(dl_iterate_callback, NULL);
    GetHookInfo().SetHooked(filename);
  }
  else
  {
    HOOK_DEBUG_PRINT("Ignoring");
  }
}

extern "C" __attribute__((visibility("default"))) void *hooked_dlopen(const char *filename, int flag)
{
  // get caller address immediately.
  const void *caller_addr = __builtin_return_address(0);

  HOOK_DEBUG_PRINT("hooked_dlopen for %s | %d", filename, flag);
  void *ret = intercept_dlopen(filename, flag);

  // if we intercepted, return immediately
  if(ret)
    return ret;

  ret = loader_dlopen(filename, flag, caller_addr);
  HOOK_DEBUG_PRINT("Got %p", ret);

  if(filename && ret)
    process_dlopen(filename, flag);

  return ret;
}

extern "C" __attribute__((visibility("default"))) void *hooked_android_dlopen_ext(
    const char *__filename, int __flags, const android_dlextinfo *__info)
{
  HOOK_DEBUG_PRINT("hooked_android_dlopen_ext for %s | %d", __filename, __flags);

  void *ret = intercept_dlopen(__filename, __flags);

  // if we intercepted, return immediately
  if(ret)
    return ret;

  // otherwise return the 'real' result.
  if(real_android_dlopen_ext == NULL)
    ret = real_android_dlopen_ext(__filename, __flags, __info);
  else
    ret = android_dlopen_ext(__filename, __flags, __info);
  HOOK_DEBUG_PRINT("Got %p", ret);

  if(__filename && ret)
    process_dlopen(__filename, __flags);

  return ret;
}

bool hooks_suppressed();

enum class DlsymFallbackReason
{
  NullArgument = 0,
  Suppressed,
  UnknownSymbol,
  NonTargetLibrary,
  Count,
};

static void LogDlsymFallbackOnce(DlsymFallbackReason reason, const char *symbol)
{
  static bool logged[(size_t)DlsymFallbackReason::Count] = {};
  static Threading::CriticalSection lock;
  SCOPED_LOCK(lock);

  if(logged[(size_t)reason])
    return;

  logged[(size_t)reason] = true;

  switch(reason)
  {
    case DlsymFallbackReason::NullArgument:
      RDCDEBUG("Android dlsym dispatch used original symbol because handle or symbol was null");
      break;
    case DlsymFallbackReason::Suppressed:
      RDCDEBUG(
          "Android dlsym dispatch used original symbol because RenderDoc hooking was suppressed");
      break;
    case DlsymFallbackReason::UnknownSymbol:
      RDCDEBUG("Android dlsym dispatch used original symbol because %s has no registered wrapper",
               symbol);
      break;
    case DlsymFallbackReason::NonTargetLibrary:
      RDCDEBUG("Android dlsym dispatch used original %s because its handle is not a target library",
               symbol);
      break;
    case DlsymFallbackReason::Count: break;
  }
}

extern "C" __attribute__((visibility("default"))) void *hooked_dlsym(void *handle, const char *symbol)
{
  if(handle == NULL || symbol == NULL)
  {
    LogDlsymFallbackOnce(DlsymFallbackReason::NullArgument, symbol);
    return dlsym(handle, symbol);
  }

  if(hooks_suppressed())
  {
    LogDlsymFallbackOnce(DlsymFallbackReason::Suppressed, symbol);
    return dlsym(handle, symbol);
  }

  const FunctionHook repl = GetHookInfo().GetDynamicFunctionHook(symbol);

  if(repl.hook == NULL)
  {
    LogDlsymFallbackOnce(DlsymFallbackReason::UnknownSymbol, symbol);
    void *ret = dlsym(handle, symbol);
    PatchLibraryContaining(ret);
    return ret;
  }

  if(!GetHookInfo().IsHooked(handle))
  {
    dl_iterate_phdr(dl_iterate_callback, NULL);
    GetHookInfo().SetHooked(handle);
  }

  HOOK_DEBUG_PRINT("Got dlsym for %s which we want in %p...", symbol, handle);

  if(GetHookInfo().IsDynamicLibHook(handle))
  {
    GetHookInfo().SetDynamicFunctionDispatched(symbol);

    static std::set<rdcstr> loggedSymbols;
    static Threading::CriticalSection loggedSymbolsLock;
    {
      SCOPED_LOCK(loggedSymbolsLock);
      if(loggedSymbols.insert(symbol).second)
        RDCLOG("Android dlsym dispatch replaced %s with RenderDoc wrapper %p", symbol, repl.hook);
    }
    return repl.hook;
  }

  void *ret = dlsym(handle, symbol);
  PatchLibraryContaining(ret);
  LogDlsymFallbackOnce(DlsymFallbackReason::NonTargetLibrary, symbol);
  Dl_info info = {};
  dladdr(ret, &info);
  HOOK_DEBUG_PRINT("real ret is %p in %s", ret, info.dli_fname);
  return ret;
}

static void InstallHooksCommon()
{
  suppressTLS = Threading::AllocateTLSSlot();

  // blacklist hooking certain system libraries or ourselves
  GetHookInfo().SetHooked(RENDERDOC_ANDROID_LIBRARY);
  GetHookInfo().SetHooked("libc.so");
  GetHookInfo().SetHooked("libvndksupport.so");

  real_android_dlopen_ext = &android_dlopen_ext;

  loader_dlopen = (pfn__loader_dlopen)dlsym(RTLD_NEXT, "__loader_dlopen");

  if(loader_dlopen)
  {
    LibraryHooks::RegisterFunctionHook("", FunctionHook("dlopen", NULL, (void *)&hooked_dlopen));
  }
  else
  {
    RDCWARN("Couldn't find __loader_dlopen, falling back to slow path for dlopen hooking");
  }

  // Swappy and other dispatch libraries resolve graphics entry points dynamically. Hook their
  // dlsym import even when __loader_dlopen is available so Present still reaches RenderDoc.
  LibraryHooks::RegisterFunctionHook("", FunctionHook("dlsym", NULL, (void *)&hooked_dlsym));

  LibraryHooks::RegisterFunctionHook(
      "", FunctionHook("android_dlopen_ext", NULL, (void *)&hooked_android_dlopen_ext));
}

#if defined(RENDERDOC_HAVE_INTERCEPTOR_LIB)

void intercept_error(void *, const char *error_msg)
{
  RDCERR("intercept_error: %s", error_msg);
}

#include "interceptor-lib/include/interceptor.h"

void PatchHookedFunctions()
{
  RDCLOG("Applying hooks with interceptor-lib");

// see below - Huawei workaround
#if defined(__LP64__)
  LibraryHooks::RegisterLibraryHook("/system/lib64/libhwgl.so", NULL);
#else
  LibraryHooks::RegisterLibraryHook("/system/lib/libhwgl.so", NULL);
#endif

  rdcarray<rdcstr> libs = GetHookInfo().GetLibHooks();
  rdcarray<FunctionHook> funchooks = GetHookInfo().GetFunctionHooks();

  // we just leak this
  void *intercept = InitializeInterceptor();

  std::set<rdcstr> fallbacklibs;
  std::set<FunctionHook> fallbackhooks;

  for(const rdcstr &lib : libs)
  {
    void *handle = dlopen(lib.c_str(), RTLD_NOW);

    bool huawei = lib.contains("libhwgl.so");

    if(!handle)
    {
      HOOK_DEBUG_PRINT("Didn't get handle for %s", lib.c_str());
      continue;
    }

    HOOK_DEBUG_PRINT("Hooking %s = %p", lib.c_str(), handle);

    std::set<void *> foundfunctions;

    for(const FunctionHook &hook : funchooks)
    {
      void *oldfunc = dlsym(handle, hook.function.c_str());

      // UNTESTED workaround taken directly from GAPID, in installer.cpp. Quoted comment:
      /*
            // Huawei implements all functions in this library with prefix,
            // all GL functions in libGLES*.so are just trampolines to his.
            // However, we do not support trampoline interception for now,
            // so try to intercept the internal implementation instead.
      */
      if(huawei && oldfunc == NULL)
        oldfunc = dlsym(handle, ("hw_" + hook.function).c_str());

      if(GetHookInfo().IsHooked(oldfunc))
        continue;

      if(!oldfunc)
      {
        HOOK_DEBUG_PRINT("%s didn't have %s", lib.c_str(), hook.function.c_str());
        continue;
      }

      HOOK_DEBUG_PRINT("Hooking %s::%s = %p with %p", lib.c_str(), hook.function.c_str(), oldfunc,
                       hook.hook);

      void *trampoline = NULL;

      bool success = InterceptFunction(intercept, oldfunc, hook.hook, &trampoline, &intercept_error);

      if(!hook.orig)
        RDCWARN("No original pointer for hook of '%s' - trampoline will be lost!",
                hook.function.c_str());

      if(hook.orig && *hook.orig == NULL)
        *hook.orig = trampoline;

      if(success)
      {
        HOOK_DEBUG_PRINT("Hooked successfully, trampoline is %p", trampoline);
      }
      else
      {
        RDCERR("Failed to hook %s::%s!", lib.c_str(), hook.function.c_str());
        fallbacklibs.insert(lib);
        fallbackhooks.insert(hook);
      }

      GetHookInfo().SetHooked(oldfunc);
    }
  }

  // we still need to hook android_dlopen_ext with interceptor-lib so that we can intercept the
  // vulkan loader's attempts to load our library and prevent it from loading a second copy (!!)
  // into the process.
  // Unfortunately, interceptor-lib can't hook this function so we need to set up the PLT hooking.
  // This is just a minimal setup to intercept that one function.
  GetHookInfo().ClearHooks();

  for(const rdcstr &l : fallbacklibs)
  {
    RDCLOG("Falling back to PLT hooking for %s", l.c_str());
    GetHookInfo().AddLibHook(l);
  }

  for(const FunctionHook &hook : fallbackhooks)
  {
    RDCLOG("Falling back to PLT hooking for %s", hook.function.c_str());
    GetHookInfo().AddFunctionHook(hook);
  }
}

#else

void PatchHookedFunctions()
{
  RDCLOG("Applying hooks with PLT hooks");
}

#endif

bool LibraryHooks::Detect(const char *identifier)
{
  const bool symbol = (dlsym(RTLD_DEFAULT, identifier) != NULL);
  const bool env = (getenv(identifier) != NULL);

  RDCLOG("Detecting symbol %s by dlsym: %s", identifier, symbol ? "yes" : "no");
  RDCLOG("Detecting symbol %s by getenv: %s", identifier, env ? "yes" : "no");

  return symbol || env;
}

void LibraryHooks::RemoveHooks()
{
  RDCERR("Removing hooks is not possible on this platform");
}

void LibraryHooks::ReplayInitialise()
{
  // nothing to do
}

void LibraryHooks::BeginHookRegistration()
{
  // nothing to do
}

void LibraryHooks::RegisterFunctionHook(const char *libraryName, const FunctionHook &hook)
{
  // we don't use the library name on android
  (void)libraryName;
  HOOK_DEBUG_PRINT("Registering function hook for %s: %p", hook.function.c_str(), hook.hook);
  GetHookInfo().AddFunctionHook(hook);
}

void LibraryHooks::RegisterDynamicLibraryHook(const char *libraryName)
{
  HOOK_DEBUG_PRINT("Registering dynamic library hook for %s", libraryName);
  GetHookInfo().AddDynamicLibHook(libraryName);

  // Make the handle available for exact handle matching without putting this library through
  // interceptor-lib's exported-function patching.
  dlopen(libraryName, RTLD_NOW);
}

void LibraryHooks::RegisterDynamicFunctionHook(const FunctionHook &hook)
{
  HOOK_DEBUG_PRINT("Registering dynamic function hook for %s: %p", hook.function.c_str(), hook.hook);
  GetHookInfo().AddDynamicFunctionHook(hook);

  if(hook.orig && *hook.orig == NULL)
  {
    for(const rdcstr &lib : GetHookInfo().GetDynamicLibHooks())
    {
      void *handle = dlopen(lib.c_str(), RTLD_NOLOAD | RTLD_GLOBAL);
      if(handle)
      {
        *hook.orig = dlsym(handle, hook.function.c_str());
        if(*hook.orig)
          break;
      }
    }
  }
}

bool LibraryHooks::WasDynamicFunctionDispatched(const char *functionName)
{
  return functionName && GetHookInfo().WasDynamicFunctionDispatched(functionName);
}

void LibraryHooks::MarkDynamicFunctionDispatched(const char *functionName)
{
  if(functionName)
    GetHookInfo().SetDynamicFunctionDispatched(functionName);
}

void LibraryHooks::RegisterLibraryHook(const char *name, FunctionLoadCallback cb)
{
  GetHookInfo().AddLibHook(name);

  HOOK_DEBUG_PRINT("Registering library hook for %s %s", name, cb ? "with callback" : "");

  // open the library immediately if we can
  dlopen(name, RTLD_NOW);

  if(cb)
    GetHookInfo().AddHookCallback(name, cb);
}

void LibraryHooks::IgnoreLibrary(const char *libraryName)
{
}

void LibraryHooks::EndHookRegistration()
{
  HOOK_DEBUG_PRINT("EndHookRegistration");

  // ensure we load all libraries we can immediately, so they are immediately hooked and don't get
  // loaded later.
  rdcarray<rdcstr> libs = GetHookInfo().GetLibHooks();
  rdcarray<rdcstr> dynamicLibs = GetHookInfo().GetDynamicLibHooks();
  for(const rdcstr &lib : libs)
  {
    void *handle = dlopen(lib.c_str(), RTLD_GLOBAL);
    HOOK_DEBUG_PRINT("%s: %p", lib.c_str(), handle);
  }

  // try to prevent the library from being unloaded, increment our dlopen refcount (might not work
  // on android, but we'll try!)
  // we use RTLD_NOLOAD to prevent a second copy being loaded if this path doesn't refer to
  // ourselves or otherwise breaks because of android's terrible library handling.
  {
    rdcstr selfLib;
    FileIO::GetLibraryFilename(selfLib);
    if(FileIO::exists(selfLib))
    {
      void *handle = dlopen(selfLib.c_str(), RTLD_NOW | RTLD_NOLOAD | RTLD_LOCAL);
      if(handle)
        RDCLOG("Dummy-loaded %s with dlopen to prevent library unload", selfLib.c_str());
      else
        RDCLOG("Failed to dummy-loaded %s with dlopen", selfLib.c_str());
    }
    else
    {
      RDCLOG("Couldn't dummy-load %s because it doesn't exist", selfLib.c_str());
    }
  }

  if(libs.empty() && dynamicLibs.empty())
  {
    RDCLOG("No library or dynamic dispatch hooks registered, not doing any hooking");
    return;
  }

  if(libs.empty())
    RDCLOG("Only dynamic dispatch hooks registered, installing common loader hooks");

  PatchHookedFunctions();

  // this already hooks dlopen (if possible) and android_dlopen_ext, which is enough
  InstallHooksCommon();

  LibraryHooks::Refresh();

  // iterate our list of libraries and look up the original pointer for any that we don't already
  // have. If we have interceptor-lib this will only be for functions that failed to generate a
  // trampoline and we're PLT hooking - without interceptor-lib this will be all functions, but it
  // will allow us to control the order/priority.
  rdcarray<rdcstr> libraryHooks = GetHookInfo().GetLibHooks();
  rdcarray<FunctionHook> functionHooks = GetHookInfo().GetFunctionHooks();

  RDCLOG("Fetching %zu original function pointers over %zu libraries", functionHooks.size(),
         libraryHooks.size());

  for(auto it = libraryHooks.begin(); it != libraryHooks.end(); ++it)
  {
    void *handle = dlopen(it->c_str(), RTLD_NOLOAD | RTLD_GLOBAL);

    if(handle)
    {
      for(FunctionHook &hook : functionHooks)
      {
        if(hook.orig && *hook.orig == NULL)
          *hook.orig = dlsym(handle, hook.function.c_str());
      }
    }
  }

  RDCLOG("Finished");

  // call the callbacks for any libraries that loaded now. If the library wasn't loaded above then
  // it can't be loaded, since we only hook system libraries.
  std::map<rdcstr, rdcarray<FunctionLoadCallback>> callbacks = GetHookInfo().GetHookCallbacks();
  for(auto it = callbacks.begin(); it != callbacks.end(); ++it)
  {
    void *handle = dlopen(it->first.c_str(), RTLD_GLOBAL);
    if(handle)
    {
      HOOK_DEBUG_PRINT("Calling callbacks for %s", it->first.c_str());
      for(FunctionLoadCallback callback : it->second)
        if(callback)
          callback(handle, it->first.c_str());
    }
  }

  RDCLOG("Called library callbacks - hook registration complete");
}

void LibraryHooks::Refresh()
{
  if(suppressTLS == 0)
  {
    RDCLOG("Not refreshing android hooks with no libraries registered");
    return;
  }

  RDCLOG("Refreshing android hooks...");
  dl_iterate_phdr(dl_iterate_callback, NULL);
  RDCLOG("Refreshed");
}

ScopedSuppressHooking::ScopedSuppressHooking()
{
  if(suppressTLS == 0)
    return;

  uintptr_t old = (uintptr_t)Threading::GetTLSValue(suppressTLS);
  Threading::SetTLSValue(suppressTLS, (void *)(old + 1));
}

ScopedSuppressHooking::~ScopedSuppressHooking()
{
  if(suppressTLS == 0)
    return;

  uintptr_t old = (uintptr_t)Threading::GetTLSValue(suppressTLS);
  Threading::SetTLSValue(suppressTLS, (void *)(old - 1));
}

bool hooks_suppressed()
{
  if(suppressTLS == 0)
    return true;

  return (uintptr_t)Threading::GetTLSValue(suppressTLS) > 0;
}

#if ENABLED(ENABLE_UNIT_TESTS)

#include "catch/catch.hpp"

static void android_dlsym_test_hook()
{
}

TEST_CASE("Android dynamic symbol hook registry", "[android][hooks]")
{
  HookingInfo hooks;
  FunctionHook hook("renderdoc_test_symbol", NULL, (void *)&android_dlsym_test_hook);

  hooks.AddDynamicFunctionHook(hook);
  CHECK(hooks.GetDynamicFunctionHook("renderdoc_test_symbol").hook == hook.hook);
  CHECK(hooks.GetDynamicFunctionHook("renderdoc_unknown_symbol").hook == NULL);

  hooks.AddDynamicLibHook("libc.so");
  void *libc = dlopen("libc.so", RTLD_NOW | RTLD_LOCAL);
  REQUIRE(libc != NULL);
  CHECK(hooks.IsDynamicLibHook(libc));

  // Successful interceptor-lib hooks are removed from the PLT tables, but their dynamic dispatch
  // registrations must survive for dlsym callers.
  hooks.AddFunctionHook(hook);
  hooks.ClearHooks();
  CHECK(hooks.GetFunctionHook("renderdoc_test_symbol").hook == NULL);
  CHECK(hooks.GetDynamicFunctionHook("renderdoc_test_symbol").hook == hook.hook);
  CHECK(hooks.IsDynamicLibHook(libc));

  dlclose(libc);
}

#endif
