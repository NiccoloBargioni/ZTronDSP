"""Tabulated values for the elliptic helpers (WP-408, STG-2).

Oracle: scipy.special.ellipk, ellipkm1, ellipj and ellipkinc (the incomplete integral of the
first kind, which is the inverse of sn and of sc on the real axis), and for the degree
equation scipy.optimize.brentq on its definition, n·K'(m)/K(m) = K'(m1)/K(m1).

    python3 elliptic_functions.py
"""
import math

import _golden

numpy, scipy = _golden.oracle()
from scipy import optimize, special  # noqa: E402

PARAMETERS = (1e-12, 1e-6, 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99, 0.999999)
COMPLEMENTS = (1e-300, 1e-100, 1e-30, 1e-12, 1e-6, 1e-3)   # m = 1 − p, where K diverges like ln(4/√p)


def main():
    cases = []

    # K(m), with the complement known exactly.
    cases.append(_golden.case("complete-integral", {}, {
        "m": _golden.real_vector(PARAMETERS),
        "K": _golden.real_vector([special.ellipk(m) for m in PARAMETERS]),
        "complement": _golden.real_vector(COMPLEMENTS),
        "K_near_one": _golden.real_vector([special.ellipkm1(p) for p in COMPLEMENTS]),
    }))

    # sn, cn, dn at fractions of the quarter period.
    for m in PARAMETERS:
        quarter = float(special.ellipk(m))
        u = [quarter * f for f in (0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0, 1.5, 2.5, -0.3)]
        sn, cn, dn, _ = special.ellipj(numpy.asarray(u), m)
        cases.append(_golden.case(f"jacobi-m{m}", {"m": m}, {
            "u": _golden.real_vector(u),
            "sn": _golden.real_vector(sn), "cn": _golden.real_vector(cn), "dn": _golden.real_vector(dn),
        }))

    # The inverses: sn(u, m) = w  <=>  u = F(asin w | m);  sc(u, 1 − m) = w  <=>  u = F(atan w | 1 − m).
    for m in PARAMETERS:
        w_sn = [0.0, 1e-8, 0.1, 0.5, 0.9, 0.999, 1.0]
        w_sc = [0.0, 1e-8, 0.1, 1.0, 6.5, 100.0]   # beyond this the oracle itself loses digits: atan(w) crowds π/2
        cases.append(_golden.case(f"inverse-m{m}", {"m": m}, {
            "w_sn": _golden.real_vector(w_sn),
            "inverse_sn": _golden.real_vector([special.ellipkinc(math.asin(w), m) for w in w_sn]),
            "w_sc": _golden.real_vector(w_sc),
            "inverse_sc": _golden.real_vector([special.ellipkinc(math.atan(w), 1.0 - m) for w in w_sc]),
        }))

    # The degree equation, solved from its definition: find m with n·K'(m)/K(m) = K'(m1)/K(m1).
    # It is solved twice, once posed in m and once in the complement p = 1 − m, so that each
    # of the two numbers is tabulated to full relative accuracy, however close to 0 or 1 it is.
    for m1 in (1e-10, 1e-6, 1e-4, 1e-2):
        target = float(special.ellipkm1(m1) / special.ellipk(m1))
        orders, solutions, complements = [], [], []
        for order in (1, 2, 3, 5, 8, 12):
            def in_parameter(m):
                return order * special.ellipkm1(m) / special.ellipk(m) - target

            def in_complement(p):
                return order * special.ellipk(p) / special.ellipkm1(p) - target

            tolerances = dict(args=(), xtol=1e-300, rtol=4 * float(numpy.finfo(float).eps), maxiter=500,
                              full_output=False, disp=True)
            orders.append(order)
            solutions.append(optimize.brentq(in_parameter, 1e-300, 1.0 - 1e-16, **tolerances))
            complements.append(optimize.brentq(in_complement, 1e-300, 1.0 - 1e-16, **tolerances))
        cases.append(_golden.case(f"degree-m1-{m1}", {"m1": m1}, {
            "order": _golden.real_vector(orders),
            "m": _golden.real_vector(solutions),
            "complement": _golden.real_vector(complements),
        }))

    _golden.write("ZTronDSPDesignTests", "elliptic_functions", cases)


if __name__ == "__main__":
    main()
