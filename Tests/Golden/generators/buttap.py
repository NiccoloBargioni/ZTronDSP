"""WP-405, and the Butterworth row of Appendix A: the analog low-pass prototype.

Oracle: scipy.signal.buttap, orders 1 to 20 (STG-2: "Butterworth to 20"). Poles are written in
the order SciPy returns them; the prototype has no zeros and unit gain. Tolerance in the test:
poles, zeros and gain within 1e-9 relative.
"""

import _golden

numpy, scipy = _golden.oracle()

from scipy import signal  # noqa: E402

cases = []
for order in range(1, 21):
    zeros, poles, gain = signal.buttap(N=order)
    cases.append(_golden.case(f"order-{order}", {"order": order}, {
        "zeros": _golden.complex_vector(zeros),
        "poles": _golden.complex_vector(poles),
        "gain": _golden.real_vector([gain]),
    }))

_golden.write("ZTronDSPDesignTests", "buttap", cases)
