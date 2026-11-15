"""YouTube JS challenge solving via the app's WebKit engine.

yt-dlp solves YouTube's signature/n challenges by running its official EJS
solver scripts in an external JavaScript runtime (deno, node, ...). iOS apps
can't start those, but the app can run JavaScript in WebKit, so this provider
reuses yt-dlp's own EJS logic and only swaps how the script is executed.

It uses some of yt-dlp's internal modules, so `register()` may fail on a future
yt-dlp. The caller decides what that means: at launch it is only a warning
(other sites keep working); for a fresh update it fails the smoke test and the
update is rolled back.

Imported after every (re)load of yt_dlp so it registers against the live copy.
"""
from __future__ import annotations

from . import bridge


def register() -> None:
    from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
    from yt_dlp.extractor.youtube.jsc._registry import _jsc_providers
    from yt_dlp.extractor.youtube.jsc.provider import (
        JsChallengeProviderError,
        register_preference,
        register_provider,
    )
    from yt_dlp.utils._jsruntime import JsRuntimeInfo

    if 'WebKit' in _jsc_providers.value:
        return

    class WebKitJCP(EJSBaseJCP):
        PROVIDER_VERSION = '1.1.0'
        BUG_REPORT_LOCATION = 'https://github.com/RatterAU/Alembic/issues'
        JS_RUNTIME_NAME = 'webkit'

        @property
        def runtime_info(self):
            return JsRuntimeInfo(name='webkit', path='webkit', version='1.0', version_tuple=(1, 0))

        def is_available(self) -> bool:
            return self._available

        def _run_js_runtime(self, stdin: str, /) -> str:
            self.logger.debug('Running challenge solver in WebKit')
            try:
                return bridge.eval_js(stdin)
            except Exception as e:
                raise JsChallengeProviderError(f'WebKit failed to run the solver: {e}') from e

    register_provider(WebKitJCP)

    @register_preference(WebKitJCP)
    def _preference(provider, requests) -> int:
        return 1000
