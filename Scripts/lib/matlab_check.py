"""The static check of the MATLAB scripts the package exports (WP-910; MAT-2 of §6.14; CI gate 7).

    matlab_check.py FILE…           check each script; every problem is printed as FILE:LINE: …
    matlab_check.py --model FILE…   print the figure each script draws, in the form in which
                                    Scripts/golden.sh --octave compares it with what Octave drew

It reads the language that MATLABScript writes (Sources/ZTronDSPCore/Export/MATLABScript.swift):
one statement per line, each a comment, an assignment or a command. Scripts/golden.sh --check
holds every committed golden script to it:

  * quotes and brackets are balanced, and every statement ends, on its own line, with a semicolon;
  * every variable is defined before it is used, and the data come before the plots (MAT-2);
  * the rows of a matrix are of equal length, and what stands side by side has as many rows;
  * the only commands are the thirteen of MAT-2 (plot, semilogx, loglog, stem, imagesc, subplot,
    xlabel, ylabel, title, grid, axis, colorbar, hold), each with the arguments the writer gives
    it, and the only functions inside an expression are real, imag, abs, cos, sin, log10, fft,
    linspace and numel, with the constants pi, NaN and Inf;
  * what is drawn can be drawn: x and y of one length, no value at or below zero on a
    logarithmic axis, a subplot inside its grid, a line style MATLAB knows, axis limits that
    increase; and every panel that shows data has both axis labels (MAT-2).

The checker computes the values the script gives (a length such as that of 0:frame-1 depends on
them) without NumPy. An operation it does not model is a problem too, so that a script stays
inside what is checked. The figure it expects (how many lines, stems and images each panel holds,
its scales, grid, hold state, labels and title, and the colorbars) is what the Octave run of
Scripts/golden.sh compares with the figure Octave drew.

Exit status: 0 every script passes, 1 a problem was found, 2 usage error.
"""

import cmath
import math
import os
import re
import sys

COMMANDS = ("plot", "semilogx", "loglog", "stem", "imagesc", "subplot", "xlabel", "ylabel", "title", "grid", "axis",
            "colorbar", "hold")
FUNCTIONS = ("real", "imag", "abs", "cos", "sin", "log10", "fft", "linspace", "numel")
CONSTANTS = {"pi": math.pi, "NaN": float("nan"), "Inf": float("inf")}
AXIS_WORDS = ("auto", "equal", "image", "ij", "normal", "square", "tight", "xy")
LINE_PLOTS = ("plot", "semilogx", "loglog", "stem")
NAME_LIMIT = 63                 # namelengthmax of MATLAB
KEPT = 1_000_000                # values computed per result; a larger result keeps its size only
STYLE_COLOURS = "rgbcmykw"
STYLE_MARKERS = "o+*.xsd^v<>ph"
STYLE_LINES = ("--", "-.", "-", ":")

_TOKEN = re.compile(r"(?P<number>(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?[ij]?)"
                    r"|(?P<name>[A-Za-z][A-Za-z0-9_]*)"
                    r"|(?P<operator>\.\*|\./|\.\^|\.\\|\.'|==|~=|<=|>=|&&|\|\||[-+*/\\^:<>&|~!=(),;\[\]{}])")


class Problem(Exception):
    """What is wrong with one statement."""


class Token:
    __slots__ = ("kind", "text", "column", "space_before")

    def __init__(self, kind, text, column, space_before):
        self.kind, self.text, self.column, self.space_before = kind, text, column, space_before

    def __repr__(self):
        return "%s %r" % (self.kind, self.text)


class Value:
    """A MATLAB value: its size, and its elements in column order when they are known."""
    __slots__ = ("rows", "columns", "data", "text")

    def __init__(self, rows, columns, data=None, text=None):
        self.rows, self.columns, self.data, self.text = rows, columns, data, text

    @property
    def known(self):
        return self.rows is not None

    @property
    def count(self):
        return self.rows * self.columns

    @property
    def is_vector(self):
        return self.rows <= 1 or self.columns <= 1

    def size(self):
        return "%dx%d" % (self.rows, self.columns)


UNKNOWN = Value(None, None)     # what a statement that failed leaves behind: nothing more is said of it
COLON = object()                # the lone `:` of an index


def scalar(number):
    return Value(1, 1, [number])


def text_value(text):
    return Value(1, len(text), None, text)


# --- Reading a line ----------------------------------------------------------------------------------

def tokenize(line):
    """The tokens of one line, without its comment."""
    tokens, position, space = [], 0, False
    while position < len(line):
        character = line[position]
        if character in " \t":
            space, position = True, position + 1
            continue
        if character == "%":
            break
        if character == "'":
            previous = tokens[-1] if tokens else None
            if previous is not None and not space and (previous.kind in ("number", "name") or previous.text in (")", "]", "'", ".'")):
                tokens.append(Token("operator", "'", position, space))
                space, position = False, position + 1
                continue
            end, characters = position + 1, []
            while True:
                if end >= len(line):
                    raise Problem("the quote at column %d is not closed" % (position + 1))
                if line[end] == "'":
                    if line.startswith("''", end):
                        characters.append("'")
                        end += 2
                        continue
                    break
                characters.append(line[end])
                end += 1
            tokens.append(Token("string", "".join(characters), position, space))
            space, position = False, end + 1
            continue
        if character == '"':
            raise Problem("a double-quoted string at column %d: the scripts quote text with '" % (position + 1))
        if line.startswith("...", position):
            raise Problem("the statement continues on the next line (...): every statement stands on one line")
        match = _TOKEN.match(line, position)
        if not match:
            raise Problem("an unexpected character %r at column %d" % (character, position + 1))
        if match.group() in ("{", "}"):
            raise Problem("a cell array ({ }) at column %d: the scripts hold numbers and text only" % (position + 1))
        tokens.append(Token(match.lastgroup, match.group(), position, space))
        space, position = False, match.end()
    return tokens


def is_operator(token, *texts):
    return token is not None and token.kind == "operator" and token.text in texts


def check_brackets(tokens):
    stack = []
    for token in tokens:
        if is_operator(token, "(", "["):
            stack.append(token)
        elif is_operator(token, ")", "]"):
            if not stack:
                raise Problem("'%s' at column %d closes nothing" % (token.text, token.column + 1))
            opening = stack.pop()
            if (opening.text, token.text) not in (("(", ")"), ("[", "]")):
                raise Problem("'%s' at column %d is closed by '%s' at column %d" % (opening.text, opening.column + 1, token.text, token.column + 1))
    if stack:
        raise Problem("'%s' at column %d is not closed" % (stack[-1].text, stack[-1].column + 1))


def statement_tokens(tokens):
    """The tokens of the one statement on a line, without the semicolon that ends it."""
    depth, ends = 0, []
    for index, token in enumerate(tokens):
        if is_operator(token, "(", "["):
            depth += 1
        elif is_operator(token, ")", "]"):
            depth -= 1
        elif depth == 0 and is_operator(token, ";", ","):
            ends.append(index)
    if not ends or ends[-1] != len(tokens) - 1 or not is_operator(tokens[-1], ";"):
        raise Problem("the statement does not end with a semicolon")
    if len(ends) > 1:
        raise Problem("two statements on one line (column %d): each stands on a line of its own" % (tokens[ends[0]].column + 1))
    return tokens[:-1]


# --- Values ------------------------------------------------------------------------------------------

def show(number):
    """A number as the scripts write it."""
    if isinstance(number, complex):
        return "%s%s%si" % (show(number.real), "-" if number.imag < 0 else "+", show(abs(number.imag)))
    if number != number:
        return "NaN"
    if math.isinf(number):
        return "Inf" if number > 0 else "-Inf"
    return "%.17g" % number


def real_part(number):
    return number.real if isinstance(number, complex) else number


def is_complex(number):
    return isinstance(number, complex) and number.imag != 0


def arithmetic(operator, x, y):
    try:
        if operator == "+":
            return x + y
        if operator == "-":
            return x - y
        if operator in ("*", ".*"):
            return x * y
        if operator in ("/", "./"):
            if y == 0 and not isinstance(x, complex) and not isinstance(y, complex):
                if x != x or x == 0:
                    return float("nan")
                return math.copysign(float("inf"), x) * math.copysign(1.0, y)
            return x / y
        return x ** y
    except ZeroDivisionError:
        return float("inf")
    except OverflowError:
        return float("inf")


def elementwise(operator, a, b):
    if not a.known or not b.known:
        return UNKNOWN
    if a.text is not None or b.text is not None:
        raise Problem("text in arithmetic (%s)" % operator)
    if a.count == 1:
        rows, columns = b.rows, b.columns
    elif b.count == 1 or (a.rows, a.columns) == (b.rows, b.columns):
        rows, columns = a.rows, a.columns
    else:
        raise Problem("'%s' of a %s and a %s value: the sizes do not agree" % (operator, a.size(), b.size()))
    count = rows * columns
    if a.data is None or b.data is None or count > KEPT:
        return Value(rows, columns)
    left = a.data * count if a.count == 1 else a.data
    right = b.data * count if b.count == 1 else b.data
    return Value(rows, columns, [arithmetic(operator, x, y) for x, y in zip(left, right)])


def product(a, b):
    if not a.known or not b.known:
        return UNKNOWN
    if a.count == 1 or b.count == 1:
        return elementwise("*", a, b)
    if a.text is not None or b.text is not None:
        raise Problem("text in arithmetic (*)")
    if a.columns != b.rows:
        raise Problem("'*' of a %s and a %s value: the inner sizes do not agree (use .* for element by element)" % (a.size(), b.size()))
    rows, columns = a.rows, b.columns
    if a.data is None or b.data is None or rows * columns * a.columns > KEPT:
        return Value(rows, columns)
    data = []
    for j in range(columns):
        for i in range(rows):
            data.append(sum(a.data[k * a.rows + i] * b.data[j * b.rows + k] for k in range(a.columns)))
    return Value(rows, columns, data)


def binary(operator, a, b):
    if operator == "*":
        return product(a, b)
    if operator == "/":
        if a.known and b.known and b.count != 1:
            raise Problem("a division by a %s value (a matrix division): this checker models a division by a scalar only" % b.size())
        return elementwise("/", a, b)
    if operator == "^":
        if a.known and b.known and (a.count != 1 or b.count != 1):
            raise Problem("'^' of a %s and a %s value (a matrix power): use .^ for element by element" % (a.size(), b.size()))
        return elementwise("^", a, b)
    if operator in ("+", "-", ".*", "./", ".^"):
        return elementwise(operator, a, b)
    raise Problem("the operator '%s' is not modelled by this checker" % operator)


def negate(value):
    if not value.known:
        return UNKNOWN
    if value.text is not None:
        raise Problem("text in arithmetic (unary -)")
    return Value(value.rows, value.columns, None if value.data is None else [-x for x in value.data])


def transpose(value, conjugate):
    if not value.known:
        return UNKNOWN
    if value.text is not None:
        raise Problem("text transposed")
    data = None
    if value.data is not None:
        data = [None] * value.count
        for i in range(value.rows):
            for j in range(value.columns):
                element = value.data[j * value.rows + i]
                data[i * value.columns + j] = element.conjugate() if conjugate and isinstance(element, complex) else element
    return Value(value.columns, value.rows, data)


def number_value(text):
    if text[-1] in "ij":
        return scalar(complex(0, float(text[:-1])))
    return scalar(float(text))


def known_real_scalar(value, what):
    if not value.known:
        return None
    if value.text is not None or value.count != 1:
        raise Problem("%s takes a number, not a %s %s" % (what, value.size(), "text" if value.text is not None else "value"))
    if value.data is None:
        raise Problem("%s: a value this checker cannot compute" % what)
    number = value.data[0]
    if is_complex(number):
        raise Problem("%s takes a real number, not %s" % (what, show(number)))
    return real_part(number)


def make_range(start, step, stop):
    parts = [part for part in (start, step, stop) if part is not None]
    if any(not part.known for part in parts):
        return UNKNOWN
    if any(part.text is None and part.count == 0 for part in parts):
        return Value(1, 0, [])
    first = known_real_scalar(start, "a range")
    increment = 1.0 if step is None else known_real_scalar(step, "a range")
    last = known_real_scalar(stop, "a range")
    if any(x != x for x in (first, increment, last)):
        raise Problem("a range with NaN at an end")
    if increment == 0 or (last - first) / increment < 0:
        return Value(1, 0, [])
    span = (last - first) / increment
    if math.isinf(span) or span > 1e9:
        raise Problem("a range of more than a billion values")
    count = int(math.floor(span + 1e-10)) + 1
    return Value(1, count, [first + k * increment for k in range(count)] if count <= KEPT else None)


def concatenate(rows):
    blocks = []
    for number, row in enumerate(rows, start=1):
        items = [item for item in row if not (item.known and item.rows == 0 and item.columns == 0)]
        if any(not item.known for item in items):
            return UNKNOWN
        if not items:
            continue
        if any(item.text is not None for item in items):
            if not all(item.text is not None for item in items):
                raise Problem("text and numbers side by side in a matrix (row %d)" % number)
            blocks.append(text_value("".join(item.text for item in items)))
            continue
        heights = sorted({item.rows for item in items})
        if len(heights) > 1:
            raise Problem("side by side in row %d of a matrix stand values of %s rows" % (number, " and ".join(str(h) for h in heights)))
        data = None
        if all(item.data is not None for item in items):
            data = [element for item in items for element in item.data]
        blocks.append(Value(heights[0], sum(item.columns for item in items), data))
    if not blocks:
        return Value(0, 0, [])
    if len(blocks) == 1:
        return blocks[0]
    if any(block.text is not None for block in blocks):
        raise Problem("text in the rows of a matrix")
    widths = [block.columns for block in blocks]
    if len(set(widths)) > 1:
        raise Problem("the rows of a matrix differ in length: %s values" % ", ".join(str(w) for w in widths))
    height = sum(block.rows for block in blocks)
    data = None
    if all(block.data is not None for block in blocks):
        data = []
        for j in range(widths[0]):
            for block in blocks:
                data.extend(block.data[j * block.rows:(j + 1) * block.rows])
    return Value(height, widths[0], data)


def elementwise_function(name, value):
    def apply(x):
        try:
            if name == "real":
                return real_part(x)
            if name == "imag":
                return x.imag if isinstance(x, complex) else 0.0
            if name == "abs":
                return abs(x)
            if name in ("cos", "sin"):
                if isinstance(x, complex):
                    return cmath.cos(x) if name == "cos" else cmath.sin(x)
                return math.cos(x) if name == "cos" else math.sin(x)
            # log10
            if isinstance(x, complex):
                return cmath.log10(x) if x != 0 else float("-inf")
            if x != x:
                return x
            if x == 0:
                return float("-inf")
            return math.log10(x) if x > 0 else cmath.log10(x)
        except (ValueError, OverflowError):
            return float("nan")

    if not value.known:
        return UNKNOWN
    if value.text is not None:
        raise Problem("%s of text" % name)
    return Value(value.rows, value.columns, None if value.data is None else [apply(x) for x in value.data])


def call_function(name, arguments):
    if any(argument is COLON for argument in arguments):
        raise Problem("a lone ':' in the arguments of %s: it belongs in an index" % name)
    if name in ("real", "imag", "abs", "cos", "sin", "log10", "fft", "numel") and len(arguments) != 1:
        raise Problem("%s takes one argument, not %d" % (name, len(arguments)))
    if name == "numel":
        value = arguments[0]
        return scalar(float(value.count)) if value.known else UNKNOWN
    if name == "fft":
        value = arguments[0]
        if value.known and value.text is not None:
            raise Problem("fft of text")
        return Value(value.rows, value.columns) if value.known else UNKNOWN
    if name == "linspace":
        if len(arguments) not in (2, 3):
            raise Problem("linspace takes two or three arguments, not %d" % len(arguments))
        if any(not argument.known for argument in arguments):
            return UNKNOWN
        first = known_real_scalar(arguments[0], "linspace")
        last = known_real_scalar(arguments[1], "linspace")
        count = 100 if len(arguments) == 2 else known_real_scalar(arguments[2], "linspace")
        if count != count or count != math.floor(count) or count < 0 or count > 1e8:
            raise Problem("linspace takes a whole number of points, not %s" % show(count))
        count = int(count)
        if count == 0:
            return Value(1, 0, [])
        if count > KEPT:
            return Value(1, count)
        if count == 1:
            return Value(1, 1, [last])
        data = [first + (last - first) * k / (count - 1) for k in range(count)]
        data[-1] = last
        return Value(1, count, data)
    return elementwise_function(name, arguments[0])


def index_values(argument, length, what):
    """The positions an index names (from 0), for a dimension of `length`."""
    if argument is COLON:
        return list(range(length))
    if not argument.known:
        return None
    if argument.text is not None:
        raise Problem("%s: text as an index" % what)
    if argument.data is None:
        raise Problem("%s: an index this checker cannot compute" % what)
    positions = []
    for x in argument.data:
        number = real_part(x)
        if is_complex(x) or number != number or number != math.floor(number) or number < 1:
            raise Problem("%s: the index %s is not a whole number from 1" % (what, show(x)))
        if number > length:
            raise Problem("%s: the index %d is out of bounds (the size is %d)" % (what, int(number), length))
        positions.append(int(number) - 1)
    return positions


def index(name, value, arguments):
    if not value.known:
        return UNKNOWN
    if value.text is not None:
        raise Problem("the text %s is indexed" % name)
    if len(arguments) == 1:
        positions = index_values(arguments[0], value.count, name)
        if positions is None:
            return UNKNOWN
        if arguments[0] is COLON:
            rows, columns = value.count, 1
        elif value.rows == 1:
            rows, columns = 1, len(positions)
        elif value.columns == 1:
            rows, columns = len(positions), 1
        else:
            rows, columns = arguments[0].rows, arguments[0].columns
        data = None if value.data is None else [value.data[p] for p in positions]
        return Value(rows, columns, data)
    if len(arguments) == 2:
        rows = index_values(arguments[0], value.rows, name)
        columns = index_values(arguments[1], value.columns, name)
        if rows is None or columns is None:
            return UNKNOWN
        data = None if value.data is None else [value.data[j * value.rows + i] for j in columns for i in rows]
        return Value(len(rows), len(columns), data)
    raise Problem("%s is indexed in %d dimensions: the scripts hold vectors and matrices" % (name, len(arguments)))


# --- Expressions ---------------------------------------------------------------------------------------

class Parser:
    """A statement's expressions, read and evaluated at once (MATLAB's precedence: the range, then
    + and -, then * and /, then the unary signs, then the powers, then transposes and indexing)."""

    def __init__(self, tokens, checker):
        self.tokens, self.index, self.checker = tokens, 0, checker

    def peek(self, offset=0):
        position = self.index + offset
        return self.tokens[position] if position < len(self.tokens) else None

    def take(self):
        token = self.tokens[self.index]
        self.index += 1
        return token

    @staticmethod
    def where(token):
        return "at the end of the statement" if token is None else "at column %d, '%s'" % (token.column + 1, token.text)

    def expect(self, text):
        token = self.peek()
        if not is_operator(token, text):
            raise Problem("'%s' was expected %s" % (text, self.where(token)))
        return self.take()

    def at_end(self):
        return self.index >= len(self.tokens)

    def expression(self, in_matrix=False):
        first = self.additive(in_matrix)
        if not is_operator(self.peek(), ":"):
            return first
        self.take()
        second = self.additive(in_matrix)
        if is_operator(self.peek(), ":"):
            self.take()
            return make_range(first, second, self.additive(in_matrix))
        return make_range(first, None, second)

    def additive(self, in_matrix):
        value = self.multiplicative(in_matrix)
        while True:
            token = self.peek()
            if not is_operator(token, "+", "-"):
                return value
            following = self.peek(1)
            if in_matrix and token.space_before and following is not None and not following.space_before:
                return value            # [a -b]: the sign starts the next element
            self.take()
            value = binary(token.text, value, self.multiplicative(in_matrix))

    def multiplicative(self, in_matrix):
        value = self.unary(in_matrix)
        while is_operator(self.peek(), "*", "/", ".*", "./", "\\", ".\\"):
            operator = self.take().text
            value = binary(operator, value, self.unary(in_matrix))
        return value

    def unary(self, in_matrix):
        token = self.peek()
        if is_operator(token, "+", "-"):
            self.take()
            operand = self.unary(in_matrix)
            return negate(operand) if token.text == "-" else operand
        if is_operator(token, "~", "!"):
            raise Problem("a logical not %s: the scripts compute numbers only" % self.where(token))
        return self.power(in_matrix)

    def power(self, in_matrix):
        value = self.postfix(in_matrix)
        while is_operator(self.peek(), "^", ".^"):
            operator = self.take().text
            sign = self.peek()
            if is_operator(sign, "+", "-"):
                self.take()
                exponent = self.postfix(in_matrix)
                exponent = negate(exponent) if sign.text == "-" else exponent
            else:
                exponent = self.postfix(in_matrix)
            value = binary(operator, value, exponent)
        return value

    def calls(self, in_matrix):
        token = self.peek()
        return is_operator(token, "(") and not (in_matrix and token.space_before)

    def postfix(self, in_matrix):
        token = self.peek()
        if token is None:
            raise Problem("a value is missing at the end of the statement")
        if token.kind == "name":
            self.take()
            if self.calls(in_matrix):
                self.take()
                value = self.checker.call(token, self.arguments())
            else:
                value = self.checker.name(token)
        elif token.kind == "number":
            self.take()
            value = number_value(token.text)
        elif token.kind == "string":
            self.take()
            value = text_value(token.text)
        elif is_operator(token, "("):
            self.take()
            value = self.expression(False)
            self.expect(")")
        elif is_operator(token, "["):
            self.take()
            value = self.matrix()
        else:
            raise Problem("a value was expected %s" % self.where(token))
        while is_operator(self.peek(), "'", ".'") and not self.peek().space_before:
            value = transpose(value, conjugate=self.take().text == "'")
        if self.calls(in_matrix):
            raise Problem("only a variable can be indexed (%s)" % self.where(self.peek()))
        return value

    def arguments(self):
        values = []
        if is_operator(self.peek(), ")"):
            self.take()
            return values
        while True:
            if is_operator(self.peek(), ":") and is_operator(self.peek(1), ",", ")"):
                self.take()
                values.append(COLON)
            else:
                values.append(self.expression(False))
            token = self.peek()
            if is_operator(token, ","):
                self.take()
                continue
            if is_operator(token, ")"):
                self.take()
                return values
            raise Problem("',' or ')' was expected %s" % self.where(token))

    def matrix(self):
        rows = [[]]
        while True:
            token = self.peek()
            if token is None:
                raise Problem("'[' is not closed")
            if is_operator(token, "]"):
                self.take()
                return concatenate(rows)
            if is_operator(token, ";"):
                self.take()
                rows.append([])
                continue
            if is_operator(token, ","):
                if not rows[-1] or is_operator(self.tokens[self.index - 1], ","):
                    raise Problem("a comma with no element before it %s" % self.where(token))
                self.take()
                continue
            previous = self.tokens[self.index - 1]
            if rows[-1] and not token.space_before and not is_operator(previous, ","):
                raise Problem("the elements of a matrix are separated by a space or a comma %s" % self.where(token))
            rows[-1].append(self.expression(True))


# --- The figure the script draws -----------------------------------------------------------------------

class Panel:
    """One axes of the figure, as Octave holds it after the script."""

    def __init__(self, key):
        self.key = key              # (rows, columns, index) of subplot; None for the axes a plot makes alone
        self.hold = False
        self.colorbar = False
        self.drawn_at = None        # the line of the last command that drew into it
        self.reset()

    def reset(self):
        """What a plot command does to the axes when hold is off: its contents and settings go."""
        self.lines = self.stems = self.images = 0
        self.xscale = self.yscale = "linear"
        self.grid = False
        self.xlabel = self.ylabel = self.title = ""
        self.series = []            # (x, y) of each line and stem, for the logarithmic axes

    def name(self):
        return "the axes" if self.key is None else "subplot(%d, %d, %d)" % self.key

    def signature(self):
        return (self.lines, self.stems, self.images, self.xscale, self.yscale, "on" if self.grid else "off",
                "add" if self.hold else "replace", self.xlabel, self.ylabel, self.title)


PANEL_FIELDS = ("lines", "stems", "images", "xscale", "yscale", "grid", "nextplot", "xlabel", "ylabel", "title")


def check_style(style):
    rest = style
    colours = markers = kinds = 0
    while rest:
        kind = next((k for k in STYLE_LINES if rest.startswith(k)), None)
        if kind:
            kinds += 1
            rest = rest[len(kind):]
        elif rest[0] in STYLE_COLOURS:
            colours += 1
            rest = rest[1:]
        elif rest[0] in STYLE_MARKERS:
            markers += 1
            rest = rest[1:]
        else:
            raise Problem("'%s' is not a line style: '%s' is neither a colour, a marker nor a line" % (style, rest[0]))
    if not style or colours > 1 or markers > 1 or kinds > 1:
        raise Problem("'%s' is not a line style: at most one colour, one marker and one line" % style)


def series_count(command, x, y):
    """How many lines (or stems) a plot of y against x draws, as Octave decides it."""
    if not x.known or not y.known:
        return 1
    for value, what in ((x, "x"), (y, "y")):
        if value.text is not None:
            raise Problem("%s plots text as %s" % (command, what))
    if x.count == 0 and y.count == 0:
        return 0
    if x.is_vector and y.is_vector:
        if x.count != y.count:
            raise Problem("%s: x has %d values and y %d (Octave stops: vector lengths must match)" % (command, x.count, y.count))
        return 1
    if x.is_vector:
        if x.count == y.rows:
            return y.columns
        if x.count == y.columns:
            return y.rows
        raise Problem("%s: x has %d values and y is %s" % (command, x.count, y.size()))
    if y.is_vector:
        if y.count == x.rows:
            return x.columns
        if y.count == x.columns:
            return x.rows
        raise Problem("%s: y has %d values and x is %s" % (command, y.count, x.size()))
    if (x.rows, x.columns) != (y.rows, y.columns):
        raise Problem("%s: x is %s and y is %s" % (command, x.size(), y.size()))
    return x.columns


def check_logarithmic(command, value, axis):
    if not value.known or value.data is None:
        return
    for number in value.data:
        if is_complex(number):
            raise Problem("%s: %s holds the complex value %s (MATLAB and Octave drop the imaginary part, with a warning)" % (command, axis, show(number)))
        number = real_part(number)
        if number == number and number <= 0:
            raise Problem("%s: %s holds %s, on a logarithmic axis (Octave warns and leaves out the values at or below zero)" % (
                command, axis, show(number)))


def check_real(command, value, axis):
    if value.known and value.data is not None:
        for number in value.data:
            if is_complex(number):
                raise Problem("%s: %s holds the complex value %s (MATLAB and Octave drop the imaginary part, with a warning)" % (
                    command, axis, show(number)))


class Checker:
    def __init__(self):
        self.variables = {}
        self.figure = False
        self.panels = []
        self.current = None
        self.plotting_began = None

    # Names and calls inside expressions.
    def name(self, token):
        name = token.text
        if name in self.variables:
            return self.variables[name]
        if name in CONSTANTS:
            return scalar(CONSTANTS[name])
        if name in FUNCTIONS:
            raise Problem("%s is called without its arguments in parentheses (column %d)" % (name, token.column + 1))
        if name in COMMANDS:
            raise Problem("%s draws: it is a statement, not a value (column %d)" % (name, token.column + 1))
        raise Problem("%s is used before it is defined (column %d)" % (name, token.column + 1))

    def call(self, token, arguments):
        name = token.text
        if name in self.variables:
            return index(name, self.variables[name], arguments)
        if name in FUNCTIONS:
            return call_function(name, arguments)
        if name in COMMANDS:
            raise Problem("%s draws: it is a statement, not a value (column %d)" % (name, token.column + 1))
        raise Problem("%s is not a function a script may call (column %d): the only ones are %s (MAT-2: core MATLAB)" % (
            name, token.column + 1, ", ".join(FUNCTIONS)))

    # The figure.
    def axes(self):
        if self.current is None:
            self.figure = True
            self.current = Panel(None)
            self.panels.append(self.current)
        return self.current

    def subplot(self, rows, columns, position):
        self.figure = True
        key = (rows, columns, position)
        for panel in self.panels:
            if panel.key == key:
                self.current = panel
                return
        if any(panel.key is not None and panel.key[:2] != key[:2] for panel in self.panels):
            raise Problem("subplots of two grids in one figure: which axes replaces which is not modelled by this checker")
        self.panels = [panel for panel in self.panels if panel.key is not None]   # the whole-figure axes gives way
        self.current = Panel(key)
        self.panels.append(self.current)

    def draw(self, command, number, x=None, y=None, count=0):
        panel = self.axes()
        if not panel.hold:
            panel.reset()
        before = (panel.xscale, panel.yscale)
        if command in ("semilogx", "loglog"):
            panel.xscale = "log"
        if command == "loglog":
            panel.yscale = "log"
        if command == "imagesc":
            panel.images += 1
        else:
            if count:
                panel.series.append((x, y))
            if command == "stem":
                panel.stems += count
            else:
                panel.lines += count
            for axis, scale, was, position in (("x", panel.xscale, before[0], 0), ("y", panel.yscale, before[1], 1)):
                if scale != "log":
                    continue
                for series in panel.series if was != "log" else panel.series[-1:] if count else []:
                    check_logarithmic(command, series[position], axis)
        panel.drawn_at = number

    def model(self):
        return {"figures": 1 if self.figure else 0, "colorbars": sum(1 for panel in self.panels if panel.colorbar),
                "panels": sorted(panel.signature() for panel in self.panels)}

    # Statements.
    def statement(self, tokens, number):
        if not tokens:
            raise Problem("an empty statement (a semicolon alone)")
        first = tokens[0]
        second = tokens[1] if len(tokens) > 1 else None
        if first.kind == "name" and is_operator(second, "="):
            self.assignment(first, tokens[2:], number)
            return
        depth = 0
        for token in tokens:
            depth += 1 if is_operator(token, "(", "[") else -1 if is_operator(token, ")", "]") else 0
            if depth == 0 and is_operator(token, "="):
                raise Problem("an assignment to part of a variable (column %d): the scripts assign whole variables" % (token.column + 1))
        if first.kind != "name":
            raise Problem("a statement is a comment, an assignment or a command, not %s" % Parser.where(first))
        name = first.text
        if name not in COMMANDS:
            if name in self.variables or name in FUNCTIONS or name in CONSTANTS:
                raise Problem("a statement that only computes %s: it is an assignment or a command" % name)
            raise Problem("%s is not one of the commands of MAT-2 (%s)" % (name, ", ".join(COMMANDS)))
        if self.plotting_began is None:
            self.plotting_began = number
        rest = tokens[1:]
        if not rest:
            arguments = []
        elif is_operator(rest[0], "("):
            parser = Parser(rest, self)
            parser.take()
            arguments = parser.arguments()
            if not parser.at_end():
                raise Problem("the command ends after its arguments; found %s" % Parser.where(parser.peek()))
            if any(argument is COLON for argument in arguments):
                raise Problem("a lone ':' in the arguments of %s" % name)
        else:
            if not rest[0].space_before or any(token.kind != "name" for token in rest):
                raise Problem("%s in command form takes words only (%s)" % (name, Parser.where(rest[0])))
            arguments = [text_value(token.text) for token in rest]
        self.command(name, arguments, number)

    def assignment(self, target, rest, number):
        name = target.text
        problem = None
        if name in COMMANDS or name in FUNCTIONS or name in CONSTANTS:
            problem = Problem("the assignment hides the %s %s" % ("constant" if name in CONSTANTS else "function", name))
        elif len(name) > NAME_LIMIT:
            problem = Problem("the name %s… is longer than %d characters" % (name[:20], NAME_LIMIT))
        elif self.plotting_began is not None:
            problem = Problem("%s is assigned after the plots began (line %d): MAT-2 defines the data, then plots it" % (
                name, self.plotting_began))
        if not rest:
            raise Problem("the assignment to %s has no value" % name)
        parser = Parser(rest, self)
        try:
            value = parser.expression(False)
            if not parser.at_end():
                raise Problem("the value of %s ends %s" % (name, Parser.where(parser.peek())))
        except Problem:
            self.variables[name] = UNKNOWN
            raise
        self.variables[name] = value
        if problem is not None:
            raise problem

    def command(self, name, arguments, number):
        def one_text(what):
            if len(arguments) != 1 or arguments[0].text is None:
                raise Problem("%s takes one text" % what)
            return arguments[0].text

        if name in LINE_PLOTS:
            data = arguments
            if data and data[-1].known and data[-1].text is not None:
                check_style(data[-1].text)
                data = data[:-1]
            if len(data) != 2:
                raise Problem("%s takes x, y and a line style if any; it was given %d values" % (name, len(data)))
            x, y = data
            count = series_count(name, x, y)
            if name in ("plot", "stem"):
                check_real(name, x, "x")
                check_real(name, y, "y")
            if name == "semilogx":
                check_real(name, y, "y")
            self.draw(name, number, x, y, count)
        elif name == "imagesc":
            if len(arguments) != 3:
                raise Problem("imagesc takes x, y and the matrix; it was given %d values" % len(arguments))
            for value, what in zip(arguments, ("x", "y", "the matrix")):
                if value.known and value.text is not None:
                    raise Problem("imagesc: %s is text" % what)
                if value.known and value.count == 0:
                    raise Problem("imagesc: %s is empty" % what)
                check_real(name, value, what)
            self.draw(name, number)
        elif name == "subplot":
            if len(arguments) != 3:
                raise Problem("subplot takes rows, columns and a position")
            values = [known_real_scalar(argument, "subplot") for argument in arguments]
            if any(value is None for value in values):
                return
            if any(value != math.floor(value) or value < 1 for value in values):
                raise Problem("subplot takes whole numbers from 1, not %s" % ", ".join("%g" % v for v in values))
            rows, columns, position = (int(value) for value in values)
            if position > rows * columns:
                raise Problem("subplot(%d, %d, %d): the position is outside the grid of %d" % (rows, columns, position, rows * columns))
            self.subplot(rows, columns, position)
        elif name in ("xlabel", "ylabel", "title"):
            text = one_text(name)
            setattr(self.axes(), name, text)
        elif name in ("grid", "hold"):
            word = one_text(name)
            if word not in ("on", "off"):
                raise Problem("%s takes on or off, not %s" % (name, word))
            if name == "grid":
                self.axes().grid = word == "on"
            else:
                self.axes().hold = word == "on"
        elif name == "axis":
            if len(arguments) != 1:
                raise Problem("axis takes a word or the limits [x0 x1 y0 y1]")
            panel = self.axes()
            argument = arguments[0]
            if not argument.known:
                return
            if argument.text is not None:
                if argument.text not in AXIS_WORDS:
                    raise Problem("axis %s: the words are %s" % (argument.text, ", ".join(AXIS_WORDS)))
                return
            if argument.count != 4:
                raise Problem("axis takes four limits [x0 x1 y0 y1], not a %s value" % argument.size())
            if argument.data is None:
                return
            limits = [real_part(x) for x in argument.data]
            if any(is_complex(x) for x in argument.data) or any(x != x or math.isinf(x) for x in limits):
                raise Problem("axis: the limits are finite real numbers")
            if not (limits[0] < limits[1] and limits[2] < limits[3]):
                raise Problem("axis: each pair of limits increases (%s)" % " ".join("%g" % x for x in limits))
            if (panel.xscale == "log" and limits[0] <= 0) or (panel.yscale == "log" and limits[2] <= 0):
                raise Problem("axis: a limit at or below zero on a logarithmic axis")
        elif name == "colorbar":
            if arguments:
                raise Problem("colorbar takes nothing")
            self.axes().colorbar = True


def check_text(text):
    """(problems, model) of a script: problems as (line, message), the figure it draws as a dict."""
    problems = []
    checker = Checker()
    if not text:
        return [(0, "the script is empty")], checker.model()
    if "\r" in text:
        problems.append((0, "the script holds a carriage return: lines end with a line feed only"))
    if not text.endswith("\n"):
        problems.append((0, "the script does not end with a line feed"))
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped in ("%{", "%}"):
            problems.append((number, "a block comment (%s): every comment is one line that starts with %%" % stripped))
            continue
        if stripped.startswith("%"):
            continue
        try:
            tokens = tokenize(line)
            check_brackets(tokens)
            checker.statement(statement_tokens(tokens), number)
        except Problem as problem:
            problems.append((number, str(problem)))
    for panel in checker.panels:
        if panel.lines + panel.stems + panel.images and not (panel.xlabel and panel.ylabel):
            missing = " and no ".join(label for label, text in (("xlabel", panel.xlabel), ("ylabel", panel.ylabel)) if not text)
            problems.append((panel.drawn_at or 0, "%s shows data and has no %s (MAT-2: axis labels and units)" % (panel.name(), missing)))
    return sorted(problems), checker.model()


def check_file(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as error:
        return [(0, "cannot be read: %s" % error.strerror)], Checker().model()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return [(0, "is not UTF-8")], Checker().model()
    return check_text(text)


def model_lines(model):
    """The figure as lines of text, in the order the Octave report is compared in."""
    lines = ["figures %d" % model["figures"], "colorbars %d" % model["colorbars"]]
    for panel in model["panels"]:
        lines.append("panel " + " ".join("%s=%s" % (field, value if not isinstance(value, str) or field in ("xscale", "yscale", "grid", "nextplot") else repr(value))
                                         for field, value in zip(PANEL_FIELDS, panel)))
    return lines


def main(arguments):
    show_model = False
    paths = []
    for argument in arguments:
        if argument == "--model":
            show_model = True
        elif argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        elif argument.startswith("-"):
            print("matlab-check: unknown argument %s" % argument, file=sys.stderr)
            return 2
        else:
            paths.append(argument)
    if not paths:
        print("matlab-check: name at least one script", file=sys.stderr)
        return 2
    found = 0
    for path in paths:
        problems, model = check_file(path)
        found += len(problems)
        for line, message in problems:
            print("%s:%d: %s" % (path, line, message) if line else "%s: %s" % (path, message))
        if show_model:
            for line in model_lines(model):
                print("%s: %s" % (path, line))
    print("matlab-check: %d script%s, %d problem%s" % (len(paths), "" if len(paths) == 1 else "s", found, "" if found == 1 else "s"))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
