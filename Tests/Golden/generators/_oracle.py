"""Loads the pinned oracles for the golden-vector generators (STG-2).

Call `load()` before importing anything from SciPy.

The SciPy 1.15.3 wheel for CPython 3.10 carries eight Fortran extensions that the dynamic
loader of macOS 27 rejects ("section '__DATA/__thread_bss' has a zero-fill section type, but
offset field is not zero"): three ODE integrators, COBYLA and the four PROPACK solvers. SciPy
imports them eagerly, so without help `import scipy.signal` fails on such a host. No oracle
function a generator uses reaches any of them, so `load()` puts an inert stand-in in the place
of exactly those eight modules, and only when the real one cannot be loaded. A stand-in raises
if anything ever calls into it, and any other load failure stays fatal.
"""

import importlib
import sys
import types

# The only modules that may be replaced. Anything else that fails to load is an error.
UNLOADABLE = (
    "scipy.integrate._dop",
    "scipy.integrate._lsoda",
    "scipy.integrate._vode",
    "scipy.optimize._cobyla",
    "scipy.sparse.linalg._propack._spropack",
    "scipy.sparse.linalg._propack._dpropack",
    "scipy.sparse.linalg._propack._cpropack",
    "scipy.sparse.linalg._propack._zpropack",
)

replaced = []


class _Refuses:
    def __init__(self, name):
        self._name = name

    def __call__(self, *args, **kwargs):
        raise RuntimeError(f"{self._name} belongs to a SciPy extension that could not be loaded on this host")

    def __getattr__(self, name):
        # SciPy reads a few constants off these modules while it is being imported. Reading is
        # harmless; calling is what must fail.
        if name.startswith("__"):
            raise AttributeError(name)
        return _Refuses(f"{self._name}.{name}")


class _StandIn(types.ModuleType):
    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return _Refuses(f"{self.__name__}.{name}")


class _Finder:
    """Serves a stand-in for a listed module when its binary cannot be loaded."""

    def find_spec(self, fullname, path=None, target=None):
        if fullname not in UNLOADABLE:
            return None
        sys.meta_path.remove(self)
        try:
            spec = importlib.util.find_spec(fullname)
            try:
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                return None  # it loads here: let the normal machinery import it
            except ImportError:
                replaced.append(fullname)
                return importlib.machinery.ModuleSpec(fullname, self)
        finally:
            sys.meta_path.insert(0, self)

    def create_module(self, spec):
        return _StandIn(spec.name)

    def exec_module(self, module):
        pass


def load():
    """Installs the stand-ins (once) and returns (numpy, scipy)."""
    import importlib.machinery  # noqa: F401
    import importlib.util  # noqa: F401
    if not any(isinstance(finder, _Finder) for finder in sys.meta_path):
        sys.meta_path.insert(0, _Finder())
    import numpy
    import scipy
    import scipy.signal  # noqa: F401  (forces every eager import now, so a new failure is seen here)
    return numpy, scipy


def versions():
    numpy, scipy = load()
    return {"numpy": numpy.__version__, "scipy": scipy.__version__}
