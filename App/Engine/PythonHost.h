#pragma once
#include <stddef.h>

/// Called (on any thread) with each JSON event the engine emits.
typedef void (*alembic_event_callback)(const char *json);
/// Runs JavaScript; must return a malloc'd UTF-8 string with everything it
/// printed via console.log, or NULL with *error set to a malloc'd message.
typedef char *_Nullable (*alembic_js_callback)(const char *_Nonnull code, char *_Nullable *_Nonnull error);

/// Starts Python with the bundled stdlib and engine. Returns NULL on success,
/// or a malloc'd error message.
char *_Nullable alembic_python_start(const char *_Nonnull bundle_path,
                                     alembic_event_callback _Nonnull on_event,
                                     alembic_js_callback _Nonnull run_js);

/// Calls engine.api.handle(request) and returns its malloc'd JSON reply.
/// Blocks for as long as the command takes; never call from the main thread.
char *_Nonnull alembic_python_call(const char *_Nonnull request_json);
