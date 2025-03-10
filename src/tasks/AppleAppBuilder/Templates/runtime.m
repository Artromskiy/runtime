// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#import <Foundation/Foundation.h>
#include <mono/utils/mono-publib.h>
#include <mono/utils/mono-logger.h>
#include <mono/metadata/assembly.h>
#include <mono/metadata/appdomain.h>
#include <mono/metadata/class.h>
#include <mono/metadata/mono-debug.h>
#include <mono/metadata/mono-gc.h>
#include <mono/metadata/exception.h>
#include <mono/metadata/object.h>
#include <mono/jit/jit.h>
#include <mono/jit/mono-private-unstable.h>
#include <TargetConditionals.h>
#import <os/log.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <stdio.h>
#include <dlfcn.h>

#import "util.h"

static char *bundle_path;
static bool pinvoke_override_enabled = false;

#define APPLE_RUNTIME_IDENTIFIER "//%APPLE_RUNTIME_IDENTIFIER%"

#define RUNTIMECONFIG_BIN_FILE "runtimeconfig.bin"

const char *
get_bundle_path (void)
{
    if (bundle_path)
        return bundle_path;
    NSBundle* main_bundle = [NSBundle mainBundle];
    NSString* path = [main_bundle bundlePath];

#if TARGET_OS_MACCATALYST
    path = [path stringByAppendingString:@"/Contents/Resources"];
#endif

    bundle_path = strdup ([path UTF8String]);

    return bundle_path;
}

static unsigned char *
load_aot_data (MonoAssembly *assembly, int size, void *user_data, void **out_handle)
{
    *out_handle = NULL;

    char path [1024];
    int res;

    MonoAssemblyName *assembly_name = mono_assembly_get_name (assembly);
    const char *aname = mono_assembly_name_get_name (assembly_name);
    const char *bundle = get_bundle_path ();

    os_log_info (OS_LOG_DEFAULT, "Looking for aot data for assembly '%s'.", aname);
    res = snprintf (path, sizeof (path) - 1, "%s/%s.aotdata", bundle, aname);
    assert (res > 0);

    int fd = open (path, O_RDONLY);
    if (fd < 0) {
        os_log_info (OS_LOG_DEFAULT, "Could not load the aot data for %s from %s: %s\n", aname, path, strerror (errno));
        return NULL;
    }

    void *ptr = mmap (NULL, size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
    if (ptr == MAP_FAILED) {
        os_log_info (OS_LOG_DEFAULT, "Could not map the aot file for %s: %s\n", aname, strerror (errno));
        close (fd);
        return NULL;
    }

    close (fd);
    os_log_info (OS_LOG_DEFAULT, "Loaded aot data for %s.\n", aname);
    *out_handle = ptr;
    return (unsigned char *) ptr;
}

static void
free_aot_data (MonoAssembly *assembly, int size, void *user_data, void *handle)
{
    munmap (handle, size);
}

static const char *assembly_load_prefix = NULL;

static MonoAssembly *
load_assembly_aux (const char *filename, const char *culture, const char *bundle)
{
    char path [1024];
    int res;
    if (culture && strcmp (culture, ""))
        res = snprintf (path, sizeof (path) - 1, "%s/%s/%s", bundle, culture, filename);
    else
        res = snprintf (path, sizeof (path) - 1, "%s/%s", bundle, filename);
    assert (res > 0);

    struct stat buffer;
    if (stat (path, &buffer) == 0) {
        MonoAssembly *assembly = mono_assembly_open (path, NULL);
        assert (assembly);
        return assembly;
    }
    return NULL;
}

static MonoAssembly *
load_assembly (const char *name, const char *culture)
{
    const char *bundle = get_bundle_path ();
    char filename [1024];

    os_log_info (OS_LOG_DEFAULT, "assembly_preload_hook: %{public}s %{public}s %{public}s\n", name, culture, bundle);

    unsigned long len = strlen (name);
    int has_extension = len > 3 && name [len - 4] == '.' && (!strcmp ("exe", name + (len - 3)) || !strcmp ("dll", name + (len - 3)));

    // add extensions if required.
    strlcpy (filename, name, sizeof (filename));
    if (!has_extension) {
        strlcat (filename, ".dll", sizeof (filename));
    }

    if (assembly_load_prefix [0] != '\0') {
        char prefix_bundle [1024];
        int res = snprintf (prefix_bundle, sizeof (prefix_bundle) - 1, "%s/%s", bundle, assembly_load_prefix);
        assert (res > 0);
        MonoAssembly *ret = load_assembly_aux (filename, culture, prefix_bundle);
        if (ret) return ret;
    }
    return load_assembly_aux (filename, culture, bundle);
}

static MonoAssembly*
assembly_preload_hook (MonoAssemblyName *aname, char **assemblies_path, void* user_data)
{
    const char *name = mono_assembly_name_get_name (aname);
    const char *culture = mono_assembly_name_get_culture (aname);
    return load_assembly (name, culture);
}

char *
strdup_printf (const char *msg, ...)
{
    va_list args;
    char *formatted = NULL;
    va_start (args, msg);
    vasprintf (&formatted, msg, args);
    va_end (args);
    return formatted;
}

static MonoObject *
fetch_exception_property (MonoObject *obj, const char *name, bool is_virtual)
{
    MonoMethod *get = NULL;
    MonoMethod *get_virt = NULL;
    MonoObject *exc = NULL;

    get = mono_class_get_method_from_name (mono_get_exception_class (), name, 0);
    if (get) {
        if (is_virtual) {
            get_virt = mono_object_get_virtual_method (obj, get);
            if (get_virt)
                get = get_virt;
        }

        return (MonoObject *) mono_runtime_invoke (get, obj, NULL, &exc);
    } else {
        printf ("Could not find the property System.Exception.%s", name);
    }

    return NULL;
}

static char *
fetch_exception_property_string (MonoObject *obj, const char *name, bool is_virtual)
{
    MonoString *str = (MonoString *) fetch_exception_property (obj, name, is_virtual);
    return str ? mono_string_to_utf8 (str) : NULL;
}

void
unhandled_exception_handler (MonoObject *exc, void *user_data)
{
    NSMutableString *msg = [[NSMutableString alloc] init];

    MonoClass *type = mono_object_get_class (exc);
    char *type_name = strdup_printf ("%s.%s", mono_class_get_namespace (type), mono_class_get_name (type));
    char *trace = fetch_exception_property_string (exc, "get_StackTrace", true);
    char *message = fetch_exception_property_string (exc, "get_Message", true);

    [msg appendString:@"Unhandled managed exceptions:\n"];
    [msg appendFormat: @"%s (%s)\n%s\n", message, type_name, trace ? trace : ""];

    free (trace);
    free (message);
    free (type_name);

    os_log_info (OS_LOG_DEFAULT, "%@", msg);
    os_log_info (OS_LOG_DEFAULT, EXIT_CODE_TAG ": %d", 1);
    exit (1);
}

void
log_callback (const char *log_domain, const char *log_level, const char *message, mono_bool fatal, void *user_data)
{
    os_log_info (OS_LOG_DEFAULT, "(%{public}s %{public}s) %{public}s", log_domain, log_level, message);
    if (fatal) {
        os_log_info (OS_LOG_DEFAULT, EXIT_CODE_TAG ": %d", 1);
        exit (1);
    }
}

static bool is_pinvoke_override_library (const char* libraryName)
{
    const char *libraries [] = {
        "__Internal",
//%PInvokeOverrideLibraries%
    };

    for (int i = 0; i < sizeof(libraries) / sizeof(libraries[0]); i++) {
        if (!strcmp (libraryName, libraries [i]))
            return true;
    }

    return false;
}

void*
handle_pinvoke_override (const char *libraryName, const char *entrypointName)
{
    if (pinvoke_override_enabled && is_pinvoke_override_library (libraryName))
        return dlsym (RTLD_DEFAULT, entrypointName);
    else
        return NULL;
}

void
cleanup_runtime_config (MonovmRuntimeConfigArguments *args, void *user_data)
{
    free (args);
    free (user_data);
}

#if FORCE_INTERPRETER || FORCE_AOT || (!TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST)
void mono_jit_set_aot_mode (MonoAotMode mode);
void register_aot_modules (void);
#endif

void
mono_ios_runtime_init (void)
{
#if INVARIANT_GLOBALIZATION
    setenv ("DOTNET_SYSTEM_GLOBALIZATION_INVARIANT", "1", TRUE);
#endif

#if HYBRID_GLOBALIZATION
    setenv ("DOTNET_SYSTEM_GLOBALIZATION_HYBRID", "1", TRUE);
#endif

#if ENABLE_RUNTIME_LOGGING
    setenv ("MONO_LOG_LEVEL", "debug", TRUE);
    setenv ("MONO_LOG_MASK", "all", TRUE);
#endif

    // build using DiagnosticPorts property in AppleAppBuilder
    // or set DOTNET_DiagnosticPorts env via mlaunch, xharness when undefined.
    // NOTE, using DOTNET_DiagnosticPorts requires app build using AppleAppBuilder and RuntimeComponents=diagnostics_tracing
#ifdef DIAGNOSTIC_PORTS
    setenv ("DOTNET_DiagnosticPorts", DIAGNOSTIC_PORTS, true);
#endif

    char **managed_argv;
    size_t argi = get_managed_args (&managed_argv);

    bool wait_for_debugger = FALSE;

    const char* bundle = get_bundle_path ();
    chdir (bundle);

    char pinvoke_override[1024];
    snprintf(pinvoke_override, sizeof(pinvoke_override) - 1, "%p", &handle_pinvoke_override);

    char icu_dat_path [1024];
    int res;
#if defined(HYBRID_GLOBALIZATION)
    res = snprintf (icu_dat_path, sizeof (icu_dat_path) - 1, "%s/%s", bundle, "icudt_hybrid.dat");
#else
    res = snprintf (icu_dat_path, sizeof (icu_dat_path) - 1, "%s/%s", bundle, "icudt.dat");
#endif
    assert (res > 0);

    // TODO: set TRUSTED_PLATFORM_ASSEMBLIES, APP_PATHS and NATIVE_DLL_SEARCH_DIRECTORIES
    const char *appctx_keys [] = {
        "RUNTIME_IDENTIFIER",
        "APP_CONTEXT_BASE_DIRECTORY",
        "PINVOKE_OVERRIDE",
#if !defined(INVARIANT_GLOBALIZATION)
        "ICU_DAT_FILE_PATH"
#endif
    };
    const char *appctx_values [] = {
        APPLE_RUNTIME_IDENTIFIER,
        bundle,
        pinvoke_override,
#if !defined(INVARIANT_GLOBALIZATION)
        icu_dat_path
#endif
    };

    char *file_name = RUNTIMECONFIG_BIN_FILE;
    unsigned long str_len = strlen (bundle) + strlen (file_name) + 2;
    char *file_path = (char *)malloc (sizeof (char) * str_len);
    int num_char = snprintf (file_path, str_len, "%s/%s", bundle, file_name);
    struct stat buffer;

    assert (num_char > 0 && num_char < str_len);

    if (stat (file_path, &buffer) == 0) {
        MonovmRuntimeConfigArguments *arg = (MonovmRuntimeConfigArguments *)malloc (sizeof (MonovmRuntimeConfigArguments));
        arg->kind = 0;
        arg->runtimeconfig.name.path = file_path;
        monovm_runtimeconfig_initialize (arg, cleanup_runtime_config, file_path);
    } else {
        free (file_path);
    }

    const char* executable = "%EntryPointLibName%";
    if (executable [0] == '\0') {
        executable = getenv ("MONO_APPLE_APP_ENTRY_POINT_LIB_NAME");
    }
    if (executable == NULL) {
        executable = "";
    }

    assembly_load_prefix = getenv ("MONO_APPLE_APP_ASSEMBLY_LOAD_PREFIX");
    if (assembly_load_prefix == NULL) {
        assembly_load_prefix = "";
    }

    monovm_initialize (sizeof (appctx_keys) / sizeof (appctx_keys [0]), appctx_keys, appctx_values);

#if (FORCE_INTERPRETER && !FORCE_AOT)
    // interp w/ JIT fallback. Assumption is that your configuration can JIT
    os_log_info (OS_LOG_DEFAULT, "INTERP Enabled");
    mono_jit_set_aot_mode (MONO_AOT_MODE_INTERP_ONLY);
#elif (!TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST) || FORCE_AOT
    pinvoke_override_enabled = true;
    // register modules
    register_aot_modules ();
#if (FORCE_INTERPRETER && FORCE_AOT)
    os_log_info (OS_LOG_DEFAULT, "AOT INTERP Enabled");
    mono_jit_set_aot_mode (MONO_AOT_MODE_INTERP);
#else
    mono_jit_set_aot_mode (MONO_AOT_MODE_FULL);
    // it's for PlatformDetection.IsMonoAOT on iOS/tvOS
    setenv ("MONO_AOT_MODE", "aot", TRUE);
#endif

#endif

    mono_debug_init (MONO_DEBUG_FORMAT_MONO);
    mono_install_assembly_preload_hook (assembly_preload_hook, NULL);
    mono_install_load_aot_data_hook (load_aot_data, free_aot_data, NULL);
    mono_install_unhandled_exception_hook (unhandled_exception_handler, NULL);
    mono_trace_set_log_handler (log_callback, NULL);
    mono_set_signal_chaining (TRUE);
    mono_set_crash_chaining (TRUE);

    if (wait_for_debugger) {
        char* options[] = { "--debugger-agent=transport=dt_socket,server=y,address=0.0.0.0:55556" };
        mono_jit_parse_options (1, options);
    }

    MonoDomain *domain = mono_jit_init_version ("dotnet.ios", "mobile");
    assert (domain);

    mono_gc_init_finalizer_thread ();

    MonoAssembly *assembly = load_assembly (executable, NULL);
    assert (assembly);
    os_log_info (OS_LOG_DEFAULT, "Executable: %{public}s", executable);

    res = mono_jit_exec (mono_domain_get (), assembly, (int)argi, managed_argv);
    // Print this so apps parsing logs can detect when we exited
    os_log_info (OS_LOG_DEFAULT, EXIT_CODE_TAG ": %d", res);

    mono_jit_cleanup (domain);

    free_managed_args (&managed_argv, argi);

    exit (res);
}
