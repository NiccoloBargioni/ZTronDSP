"""MATLAB scripts as the package writes them (§6.14), written a second time, and a structural
check of a script for where GNU Octave is not at hand.

The writer mirrors ZTronDSPCore's MATLABScript line for line: numbers with 17 significant digits
from a double and 9 from a single (MAT-3), `'` doubled inside a string, one statement per line.

`check(text)` reads a script back: every line must be one of the statements the writer makes
(MAT-2: plot, semilogx, loglog, stem, imagesc, subplot, xlabel, ylabel, title, grid, axis,
colorbar, hold), every expression must use only variables the script has defined and the core
functions numel, abs, fft, log10 and max, and the things that are plotted against one another
must be of one size. It evaluates the script's expressions with NumPy: it is a check of
structure, not Octave.

`lint(text)` holds a script to the static check of CI gate 7 (Scripts/lib/matlab_check.py),
which also reads complex vectors and every command form the writer makes; the run under GNU
Octave itself is Scripts/golden.sh --octave (WP-910).
"""
import importlib.util
import math
import os
import re


def number(value):
    value = float(value)
    if value != value:
        return "NaN"
    if value in (float("inf"), float("-inf")):
        return "Inf" if value > 0 else "-Inf"
    return "%.17g" % value


def single(numpy, value):
    value = float(numpy.float32(value))
    if value != value:
        return "NaN"
    if value in (float("inf"), float("-inf")):
        return "Inf" if value > 0 else "-Inf"
    return "%.9g" % value


def quoted(text):
    return "'" + text.replace("'", "''").replace("\n", " ") + "'"


class Script:
    def __init__(self):
        self.lines = []

    def comment(self, text):
        self.lines.append("% " + text.replace("\n", " "))
        return self

    def scalar(self, name, value):
        self.lines.append(f"{name} = {number(value)};")
        return self

    def vector(self, name, values):
        self.lines.append(f"{name} = [{' '.join(number(v) for v in values)}];")
        return self

    def optional(self, name, values):
        """A vector of doubles in which None, a value that is undefined, is written as NaN."""
        self.lines.append(f"{name} = [{' '.join('NaN' if v is None else number(v) for v in values)}];")
        return self

    def complex_vector(self, name, real, imaginary):
        parts = ["%s%s%si" % (number(re_), "-" if math.copysign(1.0, im) < 0 else "+", number(abs(im))) for re_, im in zip(real, imaginary)]
        self.lines.append(f"{name} = [{' '.join(parts)}];")
        return self

    def rows(self, name, rows):
        """A matrix of doubles, row after row."""
        self.lines.append(f"{name} = [{'; '.join(' '.join(number(v) for v in row) for row in rows)}];")
        return self

    def singles(self, numpy, name, values):
        self.lines.append(f"{name} = [{' '.join(single(numpy, v) for v in values)}];")
        return self

    def matrix(self, numpy, name, values, rows, columns):
        parts = [" ".join(single(numpy, v) for v in values[r * columns:(r + 1) * columns]) for r in range(rows)]
        self.lines.append(f"{name} = [{'; '.join(parts)}];")
        return self

    def plot(self, x, y, style=None, command="plot"):
        self.lines.append(f"{command}({x}, {y}, {quoted(style)});" if style is not None else f"{command}({x}, {y});")
        return self

    def imagesc(self, x, y, c):
        self.lines += [f"imagesc({x}, {y}, {c});", "axis xy;"]
        return self

    def subplot(self, rows, columns, index):
        self.lines.append(f"subplot({rows}, {columns}, {index});")
        return self

    def xlabel(self, text):
        self.lines.append(f"xlabel({quoted(text)});")
        return self

    def ylabel(self, text):
        self.lines.append(f"ylabel({quoted(text)});")
        return self

    def title(self, text):
        self.lines.append(f"title({quoted(text)});")
        return self

    def grid(self, on=True):
        self.lines.append("grid on;" if on else "grid off;")
        return self

    def hold(self, on=True):
        self.lines.append("hold on;" if on else "hold off;")
        return self

    def colorbar(self):
        self.lines.append("colorbar;")
        return self

    def axis(self, x0, x1, y0, y1):
        self.lines.append(f"axis([{number(x0)} {number(x1)} {number(y0)} {number(y1)}]);")
        return self

    def axis_word(self, word):
        self.lines.append("axis %s;" % "".join(c for c in word if c.isalpha()))
        return self

    @property
    def text(self):
        return "\n".join(self.lines) + "\n" if self.lines else ""


# --- The structural check ---------------------------------------------------------------------------

_TOKEN = re.compile(r"\s*(?:(\d+\.?\d*(?:[eE][-+]?\d+)?|NaN|Inf)|([A-Za-z_]\w*)|(.))")
_FUNCTIONS = ("numel", "abs", "fft", "log10", "max")
_NUMBER = r"-?(?:\d+\.?\d*(?:[eE][-+]?\d+)?|NaN|Inf)"


class _Parser:
    def __init__(self, numpy, text, variables):
        self.numpy, self.variables = numpy, variables
        self.tokens = []
        position = 0
        while position < len(text):
            match = _TOKEN.match(text, position)
            if not match or match.end() == position:
                break
            position = match.end()
            literal, name, symbol = match.groups()
            if literal is not None:
                self.tokens.append(("number", literal))
            elif name is not None:
                self.tokens.append(("name", name))
            elif symbol is not None and symbol.strip():
                self.tokens.append(("symbol", symbol))
        self.index = 0

    def peek(self):
        return self.tokens[self.index] if self.index < len(self.tokens) else (None, None)

    def take(self, symbol=None):
        kind, value = self.peek()
        if symbol is not None and value != symbol:
            raise ValueError(f"expected {symbol}, found {value}")
        self.index += 1
        return value

    def range(self):
        first = self.additive()
        if self.peek()[1] == ":":
            self.take()
            last = self.additive()
            return self.numpy.arange(float(self.numpy.asarray(first).ravel()[0]), float(self.numpy.asarray(last).ravel()[0]) + 0.5)
        return first

    def additive(self):
        value = self.multiplicative()
        while self.peek()[1] in ("+", "-"):
            value = value + self.multiplicative() if self.take() == "+" else value - self.multiplicative()
        return value

    def multiplicative(self):
        value = self.unary()
        while self.peek()[1] in ("*", "/"):
            value = value * self.unary() if self.take() == "*" else value / self.unary()
        return value

    def unary(self):
        if self.peek()[1] == "-":
            self.take()
            return -self.unary()
        return self.primary()

    def primary(self):
        kind, value = self.peek()
        if kind == "number":
            self.take()
            return self.numpy.float64({"NaN": "nan", "Inf": "inf"}.get(value, value))
        if kind == "name":
            self.take()
            if self.peek()[1] == "(":
                if value not in _FUNCTIONS:
                    raise ValueError(f"{value} is not a function a script may call")
                self.take("(")
                argument = self.numpy.asarray(self.range(), dtype=float)
                self.take(")")
                if value == "numel":
                    return self.numpy.float64(argument.size)
                if value == "abs":
                    return self.numpy.abs(argument)
                if value == "log10":
                    with self.numpy.errstate(divide="ignore"):
                        return self.numpy.log10(argument)
                if value == "max":
                    return self.numpy.float64(argument.max())
                return self.numpy.abs(self.numpy.fft.fft(argument.ravel()))
            if value not in self.variables:
                raise ValueError(f"{value} is used before it is defined")
            return self.variables[value]
        if value == "(":
            self.take("(")
            inner = self.range()
            self.take(")")
            return inner
        if value == "[":
            self.take("[")
            parts = []
            while self.peek()[1] != "]":
                parts.append(self.numpy.atleast_1d(self.numpy.asarray(self.range(), dtype=float)).ravel())
            self.take("]")
            return self.numpy.concatenate(parts) if parts else self.numpy.zeros(0)
        raise ValueError(f"unexpected {value}")


def _evaluate(numpy, text, variables):
    parser = _Parser(numpy, text, variables)
    value = parser.range()
    if parser.index != len(parser.tokens):
        raise ValueError(f"cannot read the end of: {text}")
    return numpy.asarray(value, dtype=float)


def _arguments(text):
    """Splits the arguments of a call at the commas outside brackets and quotes."""
    parts, depth, quote, current = [], 0, False, ""
    for character in text:
        if character == "'":
            quote = not quote
        if not quote and character in "([":
            depth += 1
        if not quote and character in ")]":
            depth -= 1
        if character == "," and depth == 0 and not quote:
            parts.append(current.strip())
            current = ""
        else:
            current += character
    parts.append(current.strip())
    return parts


def check(numpy, text):
    """Raises ValueError for a script that is not what the package writes; returns the number of
    statements and the variables it defines."""
    if text and not text.endswith("\n"):
        raise ValueError("a script ends in a newline")
    variables, statements = {}, 0
    for line in text.split("\n")[:-1] if text else []:
        statements += 1
        if line.startswith("% "):
            continue
        match = re.fullmatch(r"([A-Za-z]\w{0,62}) = (.*);", line)
        if match:
            name, body = match.groups()
            if re.fullmatch(_NUMBER, body):
                variables[name] = numpy.float64({"NaN": "nan", "Inf": "inf", "-Inf": "-inf"}.get(body, body))
                continue
            if not (body.startswith("[") and body.endswith("]")):
                raise ValueError(f"not a scalar, a vector or a matrix: {line[:60]}")
            rows = [row.split() for row in body[1:-1].split(";")] if body[1:-1].strip() else []
            if any(len(row) != len(rows[0]) for row in rows):
                raise ValueError(f"the rows of {name} differ in length")
            for row in rows:
                for element in row:
                    if not re.fullmatch(_NUMBER, element):
                        raise ValueError(f"{name} holds {element}, which is not a number")
            array = numpy.array([[float(e.replace("NaN", "nan").replace("Inf", "inf")) for e in row] for row in rows], dtype=float)
            variables[name] = array.reshape(len(rows), -1) if len(rows) > 1 else array.ravel()
            continue
        if line in ("grid on;", "grid off;", "hold on;", "hold off;", "colorbar;") or re.fullmatch(r"axis [a-z]+;", line):
            continue
        if re.fullmatch(r"subplot\(\d+, \d+, \d+\);", line) or re.fullmatch(r"(xlabel|ylabel|title)\('(?:[^']|'')*'\);", line):
            continue
        if re.fullmatch(rf"axis\(\[{_NUMBER} {_NUMBER} {_NUMBER} {_NUMBER}\]\);", line):
            continue
        match = re.fullmatch(r"(plot|semilogx|loglog|stem)\((.*)\);", line)
        if match:
            arguments = _arguments(match.group(2))
            if len(arguments) not in (2, 3) or (len(arguments) == 3 and not re.fullmatch(r"'[^']*'", arguments[2])):
                raise ValueError(f"not a plot of two things: {line[:60]}")
            x, y = _evaluate(numpy, arguments[0], variables), _evaluate(numpy, arguments[1], variables)
            if x.size != y.size:
                raise ValueError(f"{arguments[0]} has {x.size} values and {arguments[1]} has {y.size}")
            continue
        match = re.fullmatch(r"imagesc\((.*)\);", line)
        if match:
            arguments = _arguments(match.group(1))
            if len(arguments) != 3:
                raise ValueError(f"not an image of three things: {line[:60]}")
            x, y, c = (_evaluate(numpy, a, variables) for a in arguments)
            if c.ndim == 1:
                c = c.reshape(1, -1)
            if c.shape != (y.size, x.size):
                raise ValueError(f"an image of {c.shape} against {y.size} rows and {x.size} columns")
            continue
        raise ValueError(f"not a statement the package writes: {line[:80]}")
    return statements, variables


# --- The static check of CI gate 7 -------------------------------------------------------------------

def lint(text):
    """Raises ValueError with every problem Scripts/lib/matlab_check.py finds in a script."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "Scripts", "lib", "matlab_check.py")
    specification = importlib.util.spec_from_file_location("matlab_check", path)
    checker = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(checker)
    problems, _ = checker.check_text(text)
    if problems:
        raise ValueError("the script fails the static check of gate 7:\n" + "\n".join("line %d: %s" % problem for problem in problems))
