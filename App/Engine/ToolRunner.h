#pragma once
#include <stddef.h>

/// Directory containing FFmpegTool.framework and FFprobeTool.framework.
void alembic_tools_configure(const char *frameworks_dir);
/// Runs ffmpeg (0) or ffprobe (1) in-process with the given fds as stdin/out/err. Blocks.
/// `token` identifies the run for alembic_tool_stop. Returns 127 if the tool can't load
/// and 126 if its input/output can't be connected (both with `err` filled in).
int alembic_tool_run(int which, int argc, char **argv, int fd_in, int fd_out, int fd_err,
                     long token, char *err, size_t errlen);
/// Stops the ffmpeg run identified by `token` now, or as soon as it starts.
void alembic_tool_stop(long token);
