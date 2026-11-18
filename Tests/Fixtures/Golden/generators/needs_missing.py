"""A generator whose oracle is pinned and not installed: the runner records it as pending."""

import _golden

numpy, scipy = _golden.oracle()

import ztd_oracle_that_is_not_installed  # noqa: E402,F401

_golden.write("ZTronDSPAnalysisTests", "needs_missing", [])
