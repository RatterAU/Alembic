// Embeds CPython (BeeWare's iOS build) and exposes the `_alembic` module that
// the engine uses to reach native services. See Engine/engine/bridge.py.
#import <Foundation/Foundation.h>
#include <Python/Python.h>

#include "PythonHost.h"
#include "ToolRunner.h"

static alembic_event_callback event_cb;
static alembic_js_callback js_cb;
static PyObject *handle_fn;   // engine.api.handle; NULL until the engine has loaded
static int python_running;   // Py_Initialize succeeded (the GIL exists)

// ---- _alembic module --------------------------------------------------------

static PyObject *py_emit(PyObject *self, PyObject *args) {
    const char *json;
    if (!PyArg_ParseTuple(args, "s", &json)) return NULL;
    if (event_cb) event_cb(json);
    Py_RETURN_NONE;
}

static PyObject *py_eval_js(PyObject *self, PyObject *args) {
    const char *code;
    if (!PyArg_ParseTuple(args, "s", &code)) return NULL;
    char *copy = strdup(code);
    char *out = NULL, *err = NULL;
    Py_BEGIN_ALLOW_THREADS
    out = js_cb(copy, &err);
    Py_END_ALLOW_THREADS
    free(copy);
    if (!out) {
        PyErr_SetString(PyExc_RuntimeError, err ? err : "JavaScript failed");
        free(err);
        return NULL;
    }
    PyObject *result = PyUnicode_FromString(out);
    free(out);
    return result;
}

static PyObject *py_run_tool(PyObject *self, PyObject *args) {
    const char *tool;
    PyObject *argv_list;
    int fd_in, fd_out, fd_err;
    long token;
    if (!PyArg_ParseTuple(args, "sO!iiil", &tool, &PyList_Type, &argv_list, &fd_in, &fd_out, &fd_err, &token))
        return NULL;
    int which = strcmp(tool, "ffmpeg") == 0 ? 0 : strcmp(tool, "ffprobe") == 0 ? 1 : -1;
    if (which < 0) {
        PyErr_SetString(PyExc_ValueError, "unknown tool");
        return NULL;
    }
    Py_ssize_t n = PyList_Size(argv_list);
    char **argv = calloc(n + 1, sizeof(char *));
    if (!argv) return PyErr_NoMemory();
    for (Py_ssize_t i = 0; i < n; i++) {
        const char *s = PyUnicode_AsUTF8(PyList_GetItem(argv_list, i));
        if (!s) {
            for (Py_ssize_t j = 0; j < i; j++) free(argv[j]);
            free(argv);
            return NULL;
        }
        argv[i] = strdup(s);
    }
    char err[512] = {0};
    int rc;
    Py_BEGIN_ALLOW_THREADS
    rc = alembic_tool_run(which, (int)n, argv, fd_in, fd_out, fd_err, token, err, sizeof err);
    Py_END_ALLOW_THREADS
    for (Py_ssize_t i = 0; i < n; i++) free(argv[i]);
    free(argv);
    if ((rc == 127 || rc == 126) && err[0]) {
        PyErr_Format(PyExc_OSError, "%s could not run: %s", tool, err);
        return NULL;
    }
    return PyLong_FromLong(rc);
}

static PyObject *py_stop_tool(PyObject *self, PyObject *args) {
    long token;
    if (!PyArg_ParseTuple(args, "l", &token)) return NULL;
    alembic_tool_stop(token);
    Py_RETURN_NONE;
}

static PyMethodDef methods[] = {
    {"emit", py_emit, METH_VARARGS, "Send a JSON event to the app."},
    {"eval_js", py_eval_js, METH_VARARGS, "Run JavaScript in WebKit; returns console output."},
    {"run_tool", py_run_tool, METH_VARARGS, "Run ffmpeg/ffprobe in-process."},
    {"stop_tool", py_stop_tool, METH_VARARGS, "Stop the ffmpeg run with this token."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_alembic", NULL, -1, methods};

static PyObject *PyInit__alembic(void) { return PyModule_Create(&module); }

// ---- startup ----------------------------------------------------------------

static char *fail(const char *what, PyStatus status) {
    NSString *msg = [NSString stringWithFormat:@"%s: %s", what, status.err_msg ?: "unknown error"];
    return strdup(msg.UTF8String);
}

static char *python_error(const char *what) {
    PyObject *type, *value, *tb;
    PyErr_Fetch(&type, &value, &tb);
    PyObject *s = value ? PyObject_Str(value) : NULL;
    const char *detail = s ? PyUnicode_AsUTF8(s) : "unknown";
    NSString *msg = [NSString stringWithFormat:@"%s: %s", what, detail ?: "unknown"];
    Py_XDECREF(s);
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(tb);
    return strdup(msg.UTF8String);
}

char *alembic_python_start(const char *bundle_path, alembic_event_callback on_event, alembic_js_callback run_js) {
    event_cb = on_event;
    js_cb = run_js;
    NSString *bundle = [NSString stringWithUTF8String:bundle_path];
    alembic_tools_configure([bundle stringByAppendingPathComponent:@"Frameworks"].UTF8String);

    setenv("PYTHONUNBUFFERED", "1", 1);
    setenv("NO_COLOR", "1", 1);

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return fail("Python pre-init", status);

    if (PyImport_AppendInittab("_alembic", PyInit__alembic) == -1) return strdup("Could not register _alembic");

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    // The bundle is read-only, so compiled bytecode goes to Caches; every launch
    // after the first skips compiling the stdlib, the engine and yt-dlp.
    config.write_bytecode = 1;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches) {
        NSString *pycache = [caches stringByAppendingPathComponent:@"pycache"];
        status = PyConfig_SetBytesString(&config, &config.pycache_prefix, pycache.UTF8String);
        if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return fail("Python cache", status); }
    }
    config.install_signal_handlers = 0; // the app owns signals
    NSString *home = [bundle stringByAppendingPathComponent:@"python"];
    status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return fail("Python home", status); }
    NSString *exe = NSBundle.mainBundle.executablePath ?: [bundle stringByAppendingPathComponent:@"Alembic"];
    status = PyConfig_SetBytesString(&config, &config.executable, exe.UTF8String);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return fail("Python executable", status); }
    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return fail("Python config", status); }
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return fail("Python init", status);
    python_running = 1;

    // Our packages: the engine itself and pure-Python helpers (mutagen, certifi).
    NSString *setup = [NSString stringWithFormat:
        @"import sys, site\n"
        @"site.addsitedir(%@)\n"
        @"sys.path.insert(0, %@)\n",
        [NSString stringWithFormat:@"r'''%@'''", [bundle stringByAppendingPathComponent:@"app_packages"]],
        [NSString stringWithFormat:@"r'''%@'''", bundle]];
    char *error = NULL;
    if (PyRun_SimpleString(setup.UTF8String) != 0) {
        error = strdup("Could not set up sys.path");
    } else {
        PyObject *api = PyImport_ImportModule("engine.api");
        if (!api) {
            error = python_error("Could not load the engine");
        } else {
            handle_fn = PyObject_GetAttrString(api, "handle");
            Py_DECREF(api);
            if (!handle_fn) error = python_error("Engine has no handle()");
        }
    }
    PyEval_SaveThread(); // release the GIL on every path; each call re-acquires it
    return error;
}

char *alembic_python_call(const char *request_json) {
    if (!python_running || !handle_fn)
        return strdup("{\"ok\":false,\"error\":\"The engine isn't running\"}");
    PyGILState_STATE gil = PyGILState_Ensure();
    char *reply = NULL;
    PyObject *result = PyObject_CallFunction(handle_fn, "s", request_json);
    if (result) {
        const char *s = PyUnicode_AsUTF8(result);
        reply = strdup(s ?: "{\"ok\":false,\"error\":\"bad reply\"}");
        Py_DECREF(result);
    } else {
        char *err = python_error("Engine call failed");
        NSDictionary *obj = @{@"ok": @NO, @"error": [NSString stringWithUTF8String:err] ?: @"Engine call failed"};
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        reply = strdup(json.UTF8String ?: "{\"ok\":false,\"error\":\"Engine call failed\"}");
        free(err);
    }
    PyGILState_Release(gil);
    return reply;
}
