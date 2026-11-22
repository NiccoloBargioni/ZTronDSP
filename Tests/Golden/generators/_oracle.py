"""Loads the pinned oracles for the golden-vector generators (STG-2).

Call `load()` before importing anything from SciPy, and `load_librosa()` to get librosa: a
generator never writes `import librosa` itself.

The SciPy 1.15.3 wheel for CPython 3.10 carries eight Fortran extensions that the dynamic
loader of macOS 27 rejects ("section '__DATA/__thread_bss' has a zero-fill section type, but
offset field is not zero"): three ODE integrators, COBYLA and the four PROPACK solvers. SciPy
imports them eagerly, so without help `import scipy.signal` fails on such a host. No oracle
function a generator uses reaches any of them, so `load()` puts an inert stand-in in the place
of exactly those eight modules, and only when the real one cannot be loaded. A stand-in raises
if anything ever calls into it, and any other load failure stays fatal.

librosa imports `scipy.ndimage` and `scipy.signal`, so on such a host it can be imported only
after those stand-ins are in place: `load_librosa()` calls `load()` first. When librosa is not
installed, `load_librosa()` raises Python's own ModuleNotFoundError ("No module named
'librosa'"), which the runner (Scripts/lib/golden_runner.py) records as a pending generator,
librosa being pinned in requirements.txt.

The versions a generator records in each vector file (`versions()`) are those of the oracles it
loaded: NumPy and SciPy always, librosa when the generator loaded it. The runner reads every
pinned oracle as a generator would load it (`installed()`) and refuses to run when one differs
from its pin.
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


def load_librosa():
    """Installs the SciPy stand-ins (`load()`), then imports librosa and returns the module.

    Raises ModuleNotFoundError ("No module named 'librosa'") when librosa is not installed: the
    runner then records the generator as pending."""
    load()
    import librosa
    return librosa


def versions():
    """The versions of the oracles this process loaded: NumPy and SciPy, and librosa when it was
    loaded through `load_librosa()`. A vector file records them (_golden.write)."""
    numpy, scipy = load()
    found = {"numpy": numpy.__version__, "scipy": scipy.__version__}
    if "librosa" in sys.modules:
        found["librosa"] = sys.modules["librosa"].__version__
    return found


def installed():
    """The versions of every oracle a generator can load, as it would load them: NumPy and SciPy,
    and librosa, or None for librosa when it is not installed. The runner holds them to the pins."""
    found = versions()
    try:
        found["librosa"] = load_librosa().__version__
    except ModuleNotFoundError as error:
        if error.name != "librosa":
            raise
        found["librosa"] = None
    return found
